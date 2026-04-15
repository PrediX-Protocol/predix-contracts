// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

/// @title IPrediXHookProxy
/// @notice Proxy-side surface of the PrediX hook: timelocked upgrade flow and two-step
///         proxy-admin rotation. The proxy's "admin" is distinct from the hook
///         implementation's runtime `admin` (pause / router setter); naming is
///         disambiguated as `proxyAdmin` to avoid selector collision with `IPrediXHook`.
interface IPrediXHookProxy {
    // ---------------------------------------------------------------------
    // Events
    // ---------------------------------------------------------------------

    /// @notice Emitted when an implementation is activated (constructor or `executeUpgrade`).
    event HookProxy_Upgraded(address indexed implementation);

    /// @notice Emitted when `proposeUpgrade` schedules a future upgrade. `readyAt` is the
    ///         earliest `block.timestamp` at which `executeUpgrade` will succeed.
    event HookProxy_UpgradeProposed(address indexed implementation, uint256 readyAt);

    /// @notice Emitted when `cancelUpgrade` discards a pending upgrade.
    event HookProxy_UpgradeCancelled(address indexed implementation);

    /// @notice Emitted when `setTimelockDuration` updates the duration applied to FUTURE
    ///         proposals (current pending proposal, if any, retains its original `readyAt`).
    event HookProxy_TimelockDurationUpdated(uint256 previous, uint256 current);

    /// @notice Emitted when `changeProxyAdmin` nominates a new admin. The nominee must call
    ///         `acceptProxyAdmin` to complete the transfer.
    event HookProxy_AdminChangeProposed(address indexed previous, address indexed pending);

    /// @notice Emitted when `acceptProxyAdmin` finalises a pending admin transfer or when
    ///         the constructor binds the initial admin.
    event HookProxy_AdminChanged(address indexed previous, address indexed current);

    // ---------------------------------------------------------------------
    // Errors
    // ---------------------------------------------------------------------

    /// @notice Thrown when an admin-gated proxy function is called by anyone other than the
    ///         current proxy admin.
    error HookProxy_OnlyAdmin();

    /// @notice Thrown when `acceptProxyAdmin` is called by anyone other than the pending admin.
    error HookProxy_OnlyPendingAdmin();

    /// @notice Thrown when an address argument is `address(0)`.
    error HookProxy_ZeroAddress();

    /// @notice Thrown when an address argument has no deployed code at constructor time
    ///         or `executeUpgrade` time.
    error HookProxy_NotAContract();

    /// @notice Thrown when `executeUpgrade` or `cancelUpgrade` is called with no pending
    ///         upgrade in flight.
    error HookProxy_NoPendingUpgrade();

    /// @notice Thrown when `executeUpgrade` is called before the timelock elapses.
    error HookProxy_UpgradeNotReady();

    /// @notice Thrown when `setTimelockDuration` is called with a duration below the
    ///         24-hour floor.
    error HookProxy_TimelockTooShort();

    /// @notice Thrown when the atomic `initialize` delegatecall in the constructor reverts.
    ///         The original revert data is bubbled up via assembly when available; this error
    ///         surfaces only when the implementation reverts with empty return data.
    error HookProxy_InitReverted();

    // ---------------------------------------------------------------------
    // Upgrade flow
    // ---------------------------------------------------------------------

    /// @notice Schedule an upgrade. Stores `newImpl` plus a ready-at timestamp equal to
    ///         `block.timestamp + timelockDuration()`. Admin-only.
    function proposeUpgrade(address newImpl) external;

    /// @notice Apply the previously proposed upgrade after the timelock has elapsed.
    ///         Re-validates that the pending implementation still has code. Admin-only.
    function executeUpgrade() external;

    /// @notice Discard the pending upgrade without applying it. Admin-only.
    function cancelUpgrade() external;

    /// @notice Update the timelock duration applied to FUTURE proposals. Admin-only.
    /// @dev Floored at 24 hours.
    function setTimelockDuration(uint256 duration) external;

    // ---------------------------------------------------------------------
    // Admin transfer (two-step)
    // ---------------------------------------------------------------------

    /// @notice Nominate a new proxy admin. The nominee must call `acceptProxyAdmin()`.
    function changeProxyAdmin(address newAdmin) external;

    /// @notice Accept a pending proxy-admin nomination. Caller-restricted to the nominee.
    function acceptProxyAdmin() external;

    // ---------------------------------------------------------------------
    // Views
    // ---------------------------------------------------------------------

    function implementation() external view returns (address);
    function pendingImplementation() external view returns (address);
    function upgradeReadyAt() external view returns (uint256);
    function timelockDuration() external view returns (uint256);
    function proxyAdmin() external view returns (address);
    function pendingProxyAdmin() external view returns (address);
}
