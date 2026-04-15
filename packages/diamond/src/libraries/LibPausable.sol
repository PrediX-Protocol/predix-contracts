// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {IPausableFacet} from "@predix/shared/interfaces/IPausableFacet.sol";

import {LibPausableStorage} from "@predix/diamond/libraries/LibPausableStorage.sol";

/// @title LibPausable
/// @notice Internal helpers for the global / per-module pause check.
library LibPausable {
    function paused() internal view returns (bool) {
        return LibPausableStorage.layout().globalPaused;
    }

    /// @return Whether `moduleId` is paused, either by its own flag or the global flag.
    function isModulePaused(bytes32 moduleId) internal view returns (bool) {
        LibPausableStorage.Layout storage l = LibPausableStorage.layout();
        return l.globalPaused || l.modulePaused[moduleId];
    }

    function enforceNotPaused(bytes32 moduleId) internal view {
        if (isModulePaused(moduleId)) revert IPausableFacet.Pausable_EnforcedPause(moduleId);
    }
}
