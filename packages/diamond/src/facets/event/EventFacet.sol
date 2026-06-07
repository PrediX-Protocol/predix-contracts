// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ERC165Checker} from "@openzeppelin/contracts/utils/introspection/ERC165Checker.sol";

import {IEventFacet} from "@predix/shared/interfaces/IEventFacet.sol";
import {IEventOracle} from "@predix/shared/interfaces/IEventOracle.sol";
import {IMarketFacet} from "@predix/shared/interfaces/IMarketFacet.sol";
import {IOutcomeToken} from "@predix/shared/interfaces/IOutcomeToken.sol";
import {EmergencyReason} from "@predix/shared/constants/EmergencyReason.sol";
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
/// @notice Multi-outcome events with shared collateral. `createEvent` groups N mutually-exclusive
///         binary child markets under one `eventId` backed by a single USDC pool
///         (`eventPool[eventId]`): `splitEvent` deposits $1 and mints one YES per outcome,
///         `mergeEvent` is the pre-resolution inverse, and after `resolveEvent` settles exactly one
///         winner `redeemEvent` pays winner-YES + loser-NO claims from the pool. Per-outcome
///         split/merge is handled by the linked-aware `MarketFacet.splitPosition`/`mergePositions`
///         (which route collateral to the pool).
/// @dev Solvency invariant (proved in DESIGN/PLAN §2): with `yᵢ = YES_i.totalSupply`,
///      `nᵢ = NO_i.totalSupply`, and `M = yᵢ − nᵢ` (uniform across i), `eventPool == Σ nᵢ + M`, and
///      the payout if outcome k wins, `y_k + Σ_{j≠k} n_j`, equals `eventPool` for EVERY k. Every
///      state change below preserves this; `totalCollateralLocked` is updated in lockstep so
///      `rescueSurplus` is correct.
///
///      Pre-consolidation events created by the legacy unlinked `createEvent` remain on chain with
///      `linked == false` and per-child collateral; the shared lifecycle (`resolveEvent`,
///      `emergencyResolveEvent`, `enableEventRefundMode`, `sweepUnclaimedEvent`) still serves them,
///      while the pool ops reject them with `Event_NotLinked`.
contract EventFacet is IEventFacet, TransientReentrancyGuard {
    using SafeERC20 for IERC20;

    /// @notice Minimum number of candidate binary markets per event.
    uint256 internal constant MIN_CANDIDATES = 2;

    /// @notice Maximum number of candidate binary markets per event. Bounds the gas cost of the
    ///         `resolveEvent` / `splitEvent` / `mergeEvent` / `redeemEvent` per-child loops and the
    ///         storage footprint of `EventData.marketIds`.
    uint256 internal constant MAX_CANDIDATES = 50;

    /// @notice Grace period after `endTime` before emergency resolution unlocks.
    uint256 internal constant EMERGENCY_DELAY = 7 days;

    /// @notice Window after finalization during which users can claim. After this
    ///         an admin may sweep leftover collateral. Matches MarketFacet.GRACE_PERIOD.
    uint256 internal constant GRACE_PERIOD = 365 days;

    /// @notice Basis-point denominator (100% = 10000). Mirrors `MarketFacet.BPS_DENOMINATOR`.
    uint256 internal constant BPS_DENOMINATOR = 10000;

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
        // The oracle must resolve multi-outcome events: bind only to one that
        // advertises IEventOracle. A binary-only oracle would leave the event
        // unresolvable via resolveEvent (stuck until emergency).
        if (!ERC165Checker.supportsInterface(oracle, type(IEventOracle).interfaceId)) {
            revert Event_OracleNotEventCapable();
        }

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
        e.linked = true;
        // v1: shared-pool events are redemption-fee-free (owner decision 2026-05-31).
        // `redemptionFeeBps` stays 0 (struct default), so `redeemEvent` pays the full claim and
        // IGNORES the global default fee. The general fee path in `redeemEvent` is retained for a
        // configurable fee in v1.1.

        LibMarketStorage.Layout storage ms = LibMarketStorage.layout();
        marketIds = new uint256[](n);
        for (uint256 i; i < n; ++i) {
            uint256 marketId = LibMarket.create(candidateQuestions[i], endTime, address(0), eventId);
            ms.markets[marketId].linkedChild = true;
            marketIds[i] = marketId;
            e.marketIds.push(marketId);
            es.marketToEvent[marketId] = eventId;
        }

        emit EventCreated(eventId, msg.sender, endTime, name, marketIds, oracle);
    }

    /// @inheritdoc IEventFacet
    function splitEvent(uint256 eventId, uint256 amount) external override nonReentrant {
        LibPausable.enforceNotPaused(Modules.MARKET);
        if (amount == 0) revert Event_ZeroAmount();

        LibEventStorage.EventData storage e = _linkedEvent(eventId);
        if (e.isResolved) revert Event_AlreadyResolved();
        if (e.refundModeActive) revert Event_RefundModeActive();
        if (block.timestamp >= e.endTime) revert Event_Ended();

        // Effects (CEI): credit the pool + global lock before the external pull/mint.
        LibEventStorage.layout().eventPool[eventId] += amount;
        LibMarketStorage.layout().totalCollateralLocked += amount;

        LibConfigStorage.layout().collateralToken.safeTransferFrom(msg.sender, address(this), amount);

        LibMarketStorage.Layout storage ms = LibMarketStorage.layout();
        uint256 n = e.marketIds.length;
        for (uint256 i; i < n; ++i) {
            IOutcomeToken(ms.markets[e.marketIds[i]].yesToken).mint(msg.sender, amount);
        }

        emit EventSplit(eventId, msg.sender, amount);
    }

    /// @inheritdoc IEventFacet
    function mergeEvent(uint256 eventId, uint256 amount) external override nonReentrant {
        LibPausable.enforceNotPaused(Modules.MARKET);
        if (amount == 0) revert Event_ZeroAmount();

        LibEventStorage.EventData storage e = _linkedEvent(eventId);
        if (e.isResolved) revert Event_AlreadyResolved();
        if (e.refundModeActive) revert Event_RefundModeActive();

        LibMarketStorage.Layout storage ms = LibMarketStorage.layout();
        uint256 n = e.marketIds.length;
        // Burn one YES of every outcome first — reverts if the caller is short any leg.
        for (uint256 i; i < n; ++i) {
            IOutcomeToken(ms.markets[e.marketIds[i]].yesToken).burn(msg.sender, amount);
        }

        LibEventStorage.layout().eventPool[eventId] -= amount; // underflow-checked
        LibMarketStorage.layout().totalCollateralLocked -= amount;

        LibConfigStorage.layout().collateralToken.safeTransfer(msg.sender, amount);

        emit EventMerged(eventId, msg.sender, amount);
    }

    /// @inheritdoc IEventFacet
    /// @dev Post-resolution redemption deliberately bypasses the MARKET pause guard, mirroring
    ///      `MarketFacet.redeem`: the outcome is final and a paused module must not hold winners' funds.
    function redeemEvent(uint256 eventId) external override nonReentrant returns (uint256 payout) {
        LibEventStorage.EventData storage e = _linkedEvent(eventId);
        if (!e.isResolved) revert Event_NotResolved();
        // Defense-in-depth: shared-pool events cannot enter refund mode in v1 (Event_LinkedNoRefund),
        // so this is unreachable today — kept so redeemEvent can never run against a future refund state.
        if (e.refundModeActive) revert Event_RefundModeActive();

        LibMarketStorage.Layout storage ms = LibMarketStorage.layout();
        uint256 n = e.marketIds.length;
        uint256 winningIndex = e.winningIndex;
        uint256 grossClaim;

        for (uint256 i; i < n; ++i) {
            LibMarketStorage.MarketData storage m = ms.markets[e.marketIds[i]];
            // Winner pays on YES, every loser pays on NO — `payout(k) == eventPool` by the solvency THM.
            IOutcomeToken token = i == winningIndex ? IOutcomeToken(m.yesToken) : IOutcomeToken(m.noToken);
            uint256 bal = token.balanceOf(msg.sender);
            if (bal > 0) {
                token.burn(msg.sender, bal);
                grossClaim += bal;
            }
        }
        if (grossClaim == 0) revert Event_NothingToRedeem();

        uint256 pool = LibEventStorage.layout().eventPool[eventId];
        // Accounting tripwire: must never fire if `eventPool == Σ nᵢ + M` holds.
        if (pool < grossClaim) revert Event_PoolInsolvent();

        // Floor rounding (fee down → payout up) is intentional and matches MarketFacet.redeem; the pool is
        // decremented by the FULL grossClaim so `fee + payout == grossClaim` and the pool still drains to 0.
        uint256 fee = (grossClaim * e.redemptionFeeBps) / BPS_DENOMINATOR;
        payout = grossClaim - fee;

        LibEventStorage.layout().eventPool[eventId] = pool - grossClaim;
        LibMarketStorage.layout().totalCollateralLocked -= grossClaim;

        LibConfigStorage.Layout storage cfg = LibConfigStorage.layout();
        if (fee > 0) {
            cfg.collateralToken.safeTransfer(cfg.feeRecipient, fee);
        }
        if (payout > 0) {
            cfg.collateralToken.safeTransfer(msg.sender, payout);
        }

        emit EventRedeemed(eventId, msg.sender, grossClaim, fee, payout);
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

        // Classify the bypass reason for off-chain monitoring. Defer to the
        // oracle only if it is still in the approved set — matches
        // `enableEventRefundMode`'s gate so a revoked-but-still-answering
        // oracle no longer deadlocks the operator.
        EmergencyReason.Reason reason;
        if (!LibConfigStorage.layout().approvedOracles[e.oracle]) {
            reason = EmergencyReason.Reason.OracleRevoked;
        } else {
            try IEventOracle(e.oracle).isEventResolved(eventId) returns (bool oracleReady) {
                if (oracleReady) revert Event_OracleResolvedUseResolve();
                reason = EmergencyReason.Reason.OracleUnready;
            } catch {
                reason = EmergencyReason.Reason.OracleUnreachable;
            }
        }

        uint256 n = e.marketIds.length;
        if (winningIndex >= n) revert Event_InvalidWinningIndex();

        _resolveChildren(e, winningIndex);
        emit EventEmergencyResolved(eventId, winningIndex, msg.sender, reason);
    }

    /// @inheritdoc IEventFacet
    /// @dev Mirrors `MarketFacet.enableRefundMode` oracle-deference pattern: if
    ///      the oracle is still approved AND has reported, defer to `resolveEvent`.
    ///      Revoked-oracle case passes through (refund is the legitimate escape).
    function enableEventRefundMode(uint256 eventId) external override nonReentrant {
        LibAccessControl.checkRole(Roles.ADMIN_ROLE);

        LibEventStorage.EventData storage e = _event(eventId);
        // Shared-pool events have no v1 refund mode (deferred to v1.1). Exit is resolveEvent /
        // emergencyResolveEvent → redeemEvent. Rejecting here keeps funds from ever entering a
        // refund state that has no withdrawal path.
        if (e.linked) revert Event_LinkedNoRefund();
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

            // Shared-pool children hold no per-child collateral (it lives in eventPool); their sweep is
            // deferred to v1.1. Skip explicitly so the per-child residual math never runs on one.
            if (m.linkedChild) continue;

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
            ms.totalCollateralLocked -= amount;
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
            oracle: e.oracle,
            linked: e.linked
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

    /// @inheritdoc IEventFacet
    function eventPoolOf(uint256 eventId) external view override returns (uint256) {
        return LibEventStorage.layout().eventPool[eventId];
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

    /// @dev Pool ops require a shared-collateral event: pre-consolidation legacy events
    ///      (`linked == false`) keep per-child collateral and must use the per-child paths.
    function _linkedEvent(uint256 eventId) private view returns (LibEventStorage.EventData storage e) {
        e = _event(eventId);
        if (!e.linked) revert Event_NotLinked();
    }
}
