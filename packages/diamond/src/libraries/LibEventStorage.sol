// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

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
    }

    struct Layout {
        uint256 eventCount;
        mapping(uint256 eventId => EventData) events;
        mapping(uint256 marketId => uint256 eventId) marketToEvent;
    }

    function layout() internal pure returns (Layout storage l) {
        bytes32 slot = SLOT;
        assembly ("memory-safe") {
            l.slot := slot
        }
    }
}
