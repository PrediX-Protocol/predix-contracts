// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

/// @title LibEventStorage
/// @notice Diamond storage layout for `EventFacet`. An event is a named group of N
///         binary child markets that share a deadline and whose resolution is mutually
///         exclusive (exactly one winner settled atomically via `resolveEvent`).
/// @dev Layout is append-only. Never reorder, remove, or change types of existing fields.
library LibEventStorage {
    bytes32 internal constant SLOT = keccak256("predix.storage.event.v1");

    struct EventData {
        string name;
        uint256[] marketIds;
        uint256 endTime;
        address creator;
        uint256 resolvedAt;
        uint256 refundEnabledAt;
        uint256 winningIndex;
        bool isResolved;
        bool refundModeActive;
        address oracle; // v1.1 — append-only
        /// @dev Append-only field added for Gap#1. `true` = shared-collateral (linked) event whose
        ///      children share `eventPool[eventId]` as one pooled balance. `false` = legacy per-child
        ///      event. Never reorder.
        bool linked;
        /// @dev Append-only field added for Gap#1. Per-event redemption fee (bps) applied by
        ///      `LinkedEventFacet.redeemLinked`. v1: never written, so it stays `0` (fee-free — owner
        ///      decision 2026-05-31); the `redeemLinked` fee path is retained so v1.1 can introduce a
        ///      non-zero linked fee. `uint16` suffices; a future setter must bound it by
        ///      `MAX_REDEMPTION_FEE_BPS`. Never reorder.
        uint16 redemptionFeeBps;
    }

    struct Layout {
        uint256 eventCount;
        mapping(uint256 eventId => EventData) events;
        mapping(uint256 marketId => uint256 eventId) marketToEvent;
        /// @dev Append-only field added for Gap#1. Shared collateral pool per LINKED event (USDC base
        ///      units). Maintained in lockstep with `LibMarketStorage.totalCollateralLocked` so
        ///      `MarketFacet.rescueSurplus` never mistakes pooled backing for surplus. Mappings are
        ///      hash-slotted, so appending this is always storage-safe.
        mapping(uint256 eventId => uint256) eventPool;
    }

    function layout() internal pure returns (Layout storage l) {
        bytes32 slot = SLOT;
        assembly ("memory-safe") {
            l.slot := slot
        }
    }
}
