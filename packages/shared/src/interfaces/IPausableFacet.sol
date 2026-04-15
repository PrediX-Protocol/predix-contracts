// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

/// @title IPausableFacet
/// @notice Two-level pause: a global flag that freezes everything, and per-module flags
///         that allow surgical isolation of one subsystem.
interface IPausableFacet {
    event GlobalPaused(address account);
    event GlobalUnpaused(address account);
    event ModulePaused(bytes32 indexed moduleId, address account);
    event ModuleUnpaused(bytes32 indexed moduleId, address account);

    error Pausable_GlobalAlreadyPaused();
    error Pausable_GlobalNotPaused();
    error Pausable_ModuleAlreadyPaused(bytes32 moduleId);
    error Pausable_ModuleNotPaused(bytes32 moduleId);
    error Pausable_EnforcedPause(bytes32 moduleId);

    /// @notice Whether the entire diamond is paused.
    function paused() external view returns (bool);

    /// @notice Whether `moduleId` (or the global flag) is currently paused.
    function isModulePaused(bytes32 moduleId) external view returns (bool);

    /// @notice Set the global pause flag. Restricted to `PAUSER_ROLE`.
    function pause() external;

    /// @notice Clear the global pause flag. Restricted to `PAUSER_ROLE`.
    function unpause() external;

    /// @notice Pause a single module without freezing the whole diamond.
    function pauseModule(bytes32 moduleId) external;

    /// @notice Unpause a single module.
    function unpauseModule(bytes32 moduleId) external;
}
