// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {IPausableFacet} from "@predix/shared/interfaces/IPausableFacet.sol";
import {Roles} from "@predix/shared/constants/Roles.sol";

import {LibAccessControl} from "@predix/diamond/libraries/LibAccessControl.sol";
import {LibPausableStorage} from "@predix/diamond/libraries/LibPausableStorage.sol";
import {LibPausable} from "@predix/diamond/libraries/LibPausable.sol";

/// @title PausableFacet
/// @notice Two-level pause: a global flag + per-module flags. `PAUSER_ROLE` controls both.
contract PausableFacet is IPausableFacet {
    /// @inheritdoc IPausableFacet
    function pause() external override {
        LibAccessControl.checkRole(Roles.PAUSER_ROLE);
        LibPausableStorage.Layout storage l = LibPausableStorage.layout();
        if (l.globalPaused) revert Pausable_GlobalAlreadyPaused();
        l.globalPaused = true;
        emit GlobalPaused(msg.sender);
    }

    /// @inheritdoc IPausableFacet
    function unpause() external override {
        LibAccessControl.checkRole(Roles.PAUSER_ROLE);
        LibPausableStorage.Layout storage l = LibPausableStorage.layout();
        if (!l.globalPaused) revert Pausable_GlobalNotPaused();
        l.globalPaused = false;
        emit GlobalUnpaused(msg.sender);
    }

    /// @inheritdoc IPausableFacet
    function pauseModule(bytes32 moduleId) external override {
        LibAccessControl.checkRole(Roles.PAUSER_ROLE);
        LibPausableStorage.Layout storage l = LibPausableStorage.layout();
        if (l.modulePaused[moduleId]) revert Pausable_ModuleAlreadyPaused(moduleId);
        l.modulePaused[moduleId] = true;
        emit ModulePaused(moduleId, msg.sender);
    }

    /// @inheritdoc IPausableFacet
    function unpauseModule(bytes32 moduleId) external override {
        LibAccessControl.checkRole(Roles.PAUSER_ROLE);
        LibPausableStorage.Layout storage l = LibPausableStorage.layout();
        if (!l.modulePaused[moduleId]) revert Pausable_ModuleNotPaused(moduleId);
        l.modulePaused[moduleId] = false;
        emit ModuleUnpaused(moduleId, msg.sender);
    }

    /// @inheritdoc IPausableFacet
    function paused() external view override returns (bool) {
        return LibPausable.paused();
    }

    /// @inheritdoc IPausableFacet
    function isModulePaused(bytes32 moduleId) external view override returns (bool) {
        return LibPausable.isModulePaused(moduleId);
    }
}
