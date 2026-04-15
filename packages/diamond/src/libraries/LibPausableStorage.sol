// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

/// @title LibPausableStorage
/// @notice Diamond storage layout for the Pausable facet (global flag + per-module flags).
library LibPausableStorage {
    bytes32 internal constant SLOT = keccak256("predix.storage.pausable.v1");

    struct Layout {
        bool globalPaused;
        mapping(bytes32 => bool) modulePaused;
    }

    function layout() internal pure returns (Layout storage l) {
        bytes32 slot = SLOT;
        assembly ("memory-safe") {
            l.slot := slot
        }
    }
}
