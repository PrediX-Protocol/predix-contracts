// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {IEventFacet} from "@predix/shared/interfaces/IEventFacet.sol";
import {IMarketFacet} from "@predix/shared/interfaces/IMarketFacet.sol";
import {Modules} from "@predix/shared/constants/Modules.sol";
import {Roles} from "@predix/shared/constants/Roles.sol";
import {TransientReentrancyGuard} from "@predix/shared/utils/TransientReentrancyGuard.sol";

import {LibAccessControl} from "@predix/diamond/libraries/LibAccessControl.sol";
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
    /// @notice Minimum number of candidate binary markets per event.
    uint256 internal constant MIN_CANDIDATES = 2;

    /// @notice Maximum number of candidate binary markets per event. Bounds the gas
    ///         cost of `resolveEvent`'s per-child loop and the storage footprint of
    ///         `EventData.marketIds`.
    uint256 internal constant MAX_CANDIDATES = 50;

    // -----------------------------------------------------------------------
    // Lifecycle
    // -----------------------------------------------------------------------

    /// @inheritdoc IEventFacet
    function createEvent(string calldata name, string[] calldata candidateQuestions, uint256 endTime)
        external
        override
        nonReentrant
        returns (uint256 eventId, uint256[] memory marketIds)
    {
        LibPausable.enforceNotPaused(Modules.MARKET);

        if (bytes(name).length == 0) revert Event_EmptyName();
        if (endTime <= block.timestamp) revert Event_InvalidEndTime();

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

        marketIds = new uint256[](n);
        for (uint256 i; i < n; ++i) {
            uint256 marketId = LibMarket.create(candidateQuestions[i], endTime, address(0), eventId);
            marketIds[i] = marketId;
            e.marketIds.push(marketId);
            es.marketToEvent[marketId] = eventId;
        }

        emit EventCreated(eventId, msg.sender, endTime, name, marketIds);
    }

    /// @inheritdoc IEventFacet
    function resolveEvent(uint256 eventId, uint256 winningIndex) external override {
        LibAccessControl.checkRole(Roles.OPERATOR_ROLE);

        LibEventStorage.EventData storage e = _event(eventId);
        if (e.isResolved) revert Event_AlreadyResolved();
        if (e.refundModeActive) revert Event_RefundModeActive();
        if (block.timestamp < e.endTime) revert Event_NotEnded();

        uint256 n = e.marketIds.length;
        if (winningIndex >= n) revert Event_InvalidWinningIndex();

        e.isResolved = true;
        e.winningIndex = winningIndex;
        e.resolvedAt = block.timestamp;

        LibMarketStorage.Layout storage ms = LibMarketStorage.layout();
        for (uint256 i; i < n; ++i) {
            uint256 childId = e.marketIds[i];
            LibMarketStorage.MarketData storage m = ms.markets[childId];
            bool winner = (i == winningIndex);
            m.isResolved = true;
            m.outcome = winner;
            m.resolvedAt = block.timestamp;
            emit IMarketFacet.MarketResolved(childId, winner, msg.sender);
        }

        emit EventResolved(eventId, winningIndex, msg.sender);
    }

    /// @inheritdoc IEventFacet
    function enableEventRefundMode(uint256 eventId) external override {
        LibAccessControl.checkRole(Roles.ADMIN_ROLE);

        LibEventStorage.EventData storage e = _event(eventId);
        if (e.isResolved) revert Event_AlreadyResolved();
        if (e.refundModeActive) revert Event_RefundModeActive();
        if (block.timestamp < e.endTime) revert Event_NotEnded();

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
            refundModeActive: e.refundModeActive
        });
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

    function _event(uint256 eventId) private view returns (LibEventStorage.EventData storage e) {
        e = LibEventStorage.layout().events[eventId];
        if (e.creator == address(0)) revert Event_NotFound();
    }
}
