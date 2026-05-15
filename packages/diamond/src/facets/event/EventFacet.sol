// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {IEventFacet} from "@predix/shared/interfaces/IEventFacet.sol";
import {IEventOracle} from "@predix/shared/interfaces/IEventOracle.sol";
import {IMarketFacet} from "@predix/shared/interfaces/IMarketFacet.sol";
import {IOutcomeToken} from "@predix/shared/interfaces/IOutcomeToken.sol";
import {Modules} from "@predix/shared/constants/Modules.sol";
import {Roles} from "@predix/shared/constants/Roles.sol";
import {TransientReentrancyGuard} from "@predix/shared/utils/TransientReentrancyGuard.sol";

import {LibAccessControl} from "@predix/diamond/libraries/LibAccessControl.sol";
import {LibConfigStorage} from "@predix/diamond/libraries/LibConfigStorage.sol";
import {LibEventStorage} from "@predix/diamond/libraries/LibEventStorage.sol";
import {LibMarket} from "@predix/diamond/libraries/LibMarket.sol";
import {LibMarketStorage} from "@predix/diamond/libraries/LibMarketStorage.sol";
import {LibPausable} from "@predix/diamond/libraries/LibPausable.sol";

/// @title EventFacet
/// @notice Coordinator for multi-outcome events. Groups N binary child markets under
///         a single `eventId`, shares their deadline, and settles them atomically via
///         `resolveEvent` (exactly one winner, N-1 losers). Each child is a standard
///         binary market created through the shared `LibMarket` primitive, so it
///         trades, splits, merges, redeems and refunds exactly like any standalone
///         market. Direct individual resolution of a child is blocked by
///         `MarketFacet` — the mutual-exclusion guarantee is on-chain.
contract EventFacet is IEventFacet, TransientReentrancyGuard {
    using SafeERC20 for IERC20;

    /// @notice Minimum number of candidate binary markets per event.
    uint256 internal constant MIN_CANDIDATES = 2;

    /// @notice Maximum number of candidate binary markets per event. Bounds the gas
    ///         cost of `resolveEvent`'s per-child loop and the storage footprint of
    ///         `EventData.marketIds`.
    uint256 internal constant MAX_CANDIDATES = 50;

    /// @notice Grace period after `endTime` before emergency resolution unlocks.
    uint256 internal constant EMERGENCY_DELAY = 7 days;

    /// @notice Window after finalization during which users can claim. After this
    ///         an admin may sweep leftover collateral. Matches MarketFacet.GRACE_PERIOD.
    uint256 internal constant GRACE_PERIOD = 365 days;

    // -----------------------------------------------------------------------
    // Lifecycle
    // -----------------------------------------------------------------------

    /// @inheritdoc IEventFacet
    function createEvent(string calldata name, string[] calldata candidateQuestions, uint256 endTime, address oracle)
        external
        override
        nonReentrant
        returns (uint256 eventId, uint256[] memory marketIds)
    {
        LibPausable.enforceNotPaused(Modules.MARKET);
        if (!LibAccessControl.hasRole(Roles.CREATOR_ROLE, msg.sender)) revert Event_NotCreator();

        if (bytes(name).length == 0) revert Event_EmptyName();
        if (endTime <= block.timestamp) revert Event_InvalidEndTime();
        if (oracle == address(0)) revert Event_ZeroOracle();
        if (!LibConfigStorage.layout().approvedOracles[oracle]) revert Event_OracleNotApproved();

        uint256 n = candidateQuestions.length;
        if (n < MIN_CANDIDATES) revert Event_TooFewCandidates();
        if (n > MAX_CANDIDATES) revert Event_TooManyCandidates();
        for (uint256 i; i < n; ++i) {
            if (bytes(candidateQuestions[i]).length == 0) revert IMarketFacet.Market_EmptyQuestion();
        }

        LibEventStorage.Layout storage es = LibEventStorage.layout();
        eventId = ++es.eventCount;
        LibEventStorage.EventData storage e = es.events[eventId];
        e.name = name;
        e.endTime = endTime;
        e.creator = msg.sender;
        e.oracle = oracle;

        marketIds = new uint256[](n);
        for (uint256 i; i < n; ++i) {
            uint256 marketId = LibMarket.create(candidateQuestions[i], endTime, address(0), eventId);
            marketIds[i] = marketId;
            e.marketIds.push(marketId);
            es.marketToEvent[marketId] = eventId;
        }

        emit EventCreated(eventId, msg.sender, endTime, name, marketIds, oracle);
    }

    /// @inheritdoc IEventFacet
    function resolveEvent(uint256 eventId) external override nonReentrant {
        LibPausable.enforceNotPaused(Modules.MARKET);

        LibEventStorage.EventData storage e = _event(eventId);
        if (e.isResolved) revert Event_AlreadyResolved();
        if (e.refundModeActive) revert Event_RefundModeActive();
        if (block.timestamp < e.endTime) revert Event_NotEnded();
        if (!LibConfigStorage.layout().approvedOracles[e.oracle]) revert Event_OracleNotApproved();

        IEventOracle oracle = IEventOracle(e.oracle);
        if (!oracle.isEventResolved(eventId)) revert Event_OracleNotResolved();
        uint256 winningIndex = oracle.eventOutcome(eventId);

        uint256 n = e.marketIds.length;
        if (winningIndex >= n) revert Event_InvalidWinningIndex();

        _resolveChildren(e, winningIndex);
        emit EventResolved(eventId, winningIndex, msg.sender);
    }

    /// @inheritdoc IEventFacet
    /// @dev Deliberately bypasses the MARKET pause guard so emergency recovery
    ///      is always actionable — mirrors `MarketFacet.emergencyResolve`.
    function emergencyResolveEvent(uint256 eventId, uint256 winningIndex) external override nonReentrant {
        LibAccessControl.checkRole(Roles.OPERATOR_ROLE);

        LibEventStorage.EventData storage e = _event(eventId);
        if (e.isResolved) revert Event_AlreadyResolved();
        if (e.refundModeActive) revert Event_RefundModeActive();
        if (block.timestamp < e.endTime + EMERGENCY_DELAY) revert Event_TooEarlyForEmergency();

        try IEventOracle(e.oracle).isEventResolved(eventId) returns (bool oracleReady) {
            if (oracleReady) revert Event_OracleResolvedUseResolve();
        } catch {}

        uint256 n = e.marketIds.length;
        if (winningIndex >= n) revert Event_InvalidWinningIndex();

        _resolveChildren(e, winningIndex);
        emit EventEmergencyResolved(eventId, winningIndex, msg.sender);
    }

    /// @inheritdoc IEventFacet
    /// @dev Mirrors `MarketFacet.enableRefundMode` oracle-deference pattern: if
    ///      the oracle is still approved AND has reported, defer to `resolveEvent`.
    ///      Revoked-oracle case passes through (refund is the legitimate escape).
    function enableEventRefundMode(uint256 eventId) external override {
        LibAccessControl.checkRole(Roles.ADMIN_ROLE);

        LibEventStorage.EventData storage e = _event(eventId);
        if (e.isResolved) revert Event_AlreadyResolved();
        if (e.refundModeActive) revert Event_RefundModeActive();
        if (block.timestamp < e.endTime) revert Event_NotEnded();

        if (LibConfigStorage.layout().approvedOracles[e.oracle]) {
            try IEventOracle(e.oracle).isEventResolved(eventId) returns (bool oracleReady) {
                if (oracleReady) revert Event_OracleResolvedUseResolve();
            } catch {}
        }

        e.refundModeActive = true;
        e.refundEnabledAt = block.timestamp;

        LibMarketStorage.Layout storage ms = LibMarketStorage.layout();
        uint256 n = e.marketIds.length;
        for (uint256 i; i < n; ++i) {
            uint256 childId = e.marketIds[i];
            LibMarketStorage.MarketData storage m = ms.markets[childId];
            m.refundModeActive = true;
            m.refundEnabledAt = block.timestamp;
            emit IMarketFacet.RefundModeEnabled(childId, msg.sender);
        }

        emit EventRefundModeEnabled(eventId, msg.sender);
    }

    /// @inheritdoc IEventFacet
    /// @dev Bypasses pause guard — mirrors MarketFacet.sweepUnclaimed. Loops
    ///      through all children and sweeps each one's residual to feeRecipient.
    function sweepUnclaimedEvent(uint256 eventId) external override nonReentrant returns (uint256 total) {
        LibAccessControl.checkRole(Roles.ADMIN_ROLE);

        LibEventStorage.EventData storage e = _event(eventId);
        LibMarketStorage.Layout storage ms = LibMarketStorage.layout();
        LibConfigStorage.Layout storage cfg = LibConfigStorage.layout();

        uint256 n = e.marketIds.length;
        for (uint256 i; i < n; ++i) {
            uint256 childId = e.marketIds[i];
            LibMarketStorage.MarketData storage m = ms.markets[childId];

            uint256 finalAt = m.isResolved ? m.resolvedAt : (m.refundModeActive ? m.refundEnabledAt : 0);
            if (finalAt == 0) continue;
            if (block.timestamp < finalAt + GRACE_PERIOD) continue;

            uint256 outstanding;
            if (m.isResolved) {
                address winningToken = m.outcome ? m.yesToken : m.noToken;
                outstanding = IOutcomeToken(winningToken).totalSupply();
            } else {
                outstanding = IOutcomeToken(m.yesToken).totalSupply();
            }
            if (m.totalCollateral <= outstanding) continue;

            uint256 amount = m.totalCollateral - outstanding;
            m.totalCollateral -= amount;
            total += amount;
            emit EventChildSwept(eventId, childId, amount);
        }

        if (total > 0) {
            cfg.collateralToken.safeTransfer(cfg.feeRecipient, total);
        }
    }

    // -----------------------------------------------------------------------
    // Views
    // -----------------------------------------------------------------------

    /// @inheritdoc IEventFacet
    function getEvent(uint256 eventId) external view override returns (EventView memory) {
        LibEventStorage.EventData storage e = _event(eventId);
        return EventView({
            name: e.name,
            marketIds: e.marketIds,
            endTime: e.endTime,
            creator: e.creator,
            resolvedAt: e.resolvedAt,
            refundEnabledAt: e.refundEnabledAt,
            winningIndex: e.winningIndex,
            isResolved: e.isResolved,
            refundModeActive: e.refundModeActive,
            oracle: e.oracle
        });
    }

    /// @inheritdoc IEventFacet
    function getEventStatus(uint256 eventId)
        external
        view
        override
        returns (uint256 endTime, uint256 candidateCount, bool isResolved, bool refundModeActive)
    {
        LibEventStorage.EventData storage e = _event(eventId);
        return (e.endTime, e.marketIds.length, e.isResolved, e.refundModeActive);
    }

    /// @inheritdoc IEventFacet
    function eventOfMarket(uint256 marketId) external view override returns (uint256) {
        return LibEventStorage.layout().marketToEvent[marketId];
    }

    /// @inheritdoc IEventFacet
    function eventCount() external view override returns (uint256) {
        return LibEventStorage.layout().eventCount;
    }

    // -----------------------------------------------------------------------
    // Internal helpers
    // -----------------------------------------------------------------------

    function _resolveChildren(LibEventStorage.EventData storage e, uint256 winningIndex) private {
        e.isResolved = true;
        e.winningIndex = winningIndex;
        e.resolvedAt = block.timestamp;

        LibMarketStorage.Layout storage ms = LibMarketStorage.layout();
        uint256 n = e.marketIds.length;
        for (uint256 i; i < n; ++i) {
            uint256 childId = e.marketIds[i];
            LibMarketStorage.MarketData storage m = ms.markets[childId];
            bool winner = (i == winningIndex);
            m.isResolved = true;
            m.outcome = winner;
            m.resolvedAt = block.timestamp;
            emit IMarketFacet.MarketResolved(childId, winner, msg.sender);
        }
    }

    function _event(uint256 eventId) private view returns (LibEventStorage.EventData storage e) {
        e = LibEventStorage.layout().events[eventId];
        if (e.creator == address(0)) revert Event_NotFound();
    }
}
