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

    /// @notice Emitted by `executeTimelockDuration` when a previously-proposed
    ///         duration is applied. Current pending upgrade proposals, if any,
    ///         retain their original `readyAt`.
    event HookProxy_TimelockDurationUpdated(uint256 previous, uint256 current);

    /// @notice Emitted by `proposeTimelockDuration`. The
    ///         duration becomes effective only after `executeTimelockDuration`
    ///         is called at or after `readyAt`. `readyAt` is anchored to the
    ///         CURRENT timelock duration, not the minimum — the timelock
    ///         self-gates its own change.
    event HookProxy_TimelockDurationProposed(uint256 duration, uint256 readyAt);

    /// @notice Emitted by `cancelTimelockDuration` when admin discards a
    ///         pending duration change before `executeTimelockDuration` is
    ///         called.
    event HookProxy_TimelockDurationCancelled(uint256 duration);

    /// @notice Emitted when `changeProxyAdmin` nominates a new admin. The nominee must call
    ///         `acceptProxyAdmin` to complete the transfer.
    event HookProxy_AdminChangeProposed(address indexed previous, address indexed pending);

    /// @notice Emitted when `acceptProxyAdmin` finalises a pending admin transfer or when
    ///         the constructor binds the initial admin.
    event HookProxy_AdminChanged(address indexed previous, address indexed current);

    /// @notice Emitted when `cancelProxyAdminChange` discards a pending admin
    ///         nomination before the nominee accepts.
    event HookProxy_AdminChangeCancelled(address indexed cancelled);

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

    /// @notice Thrown when `proposeTimelockDuration` is called with a duration
    ///         below the 48-hour floor.
    error HookProxy_TimelockTooShort();

    /// @notice Thrown when `proposeTimelockDuration` is called with a duration
    ///         above the 30-day ceiling. Combined with the monotonic guard
    ///         this prevents an admin from bricking
    ///         the upgrade governance by raising the timelock to a value that
    ///         overflows `block.timestamp + duration`.
    error HookProxy_TimelockTooLong();

    /// @notice Thrown when `proposeUpgrade` is called while a previous proposal
    ///         is still pending. Admin must `cancelUpgrade` first.
    error HookProxy_AlreadyPendingUpgrade();

    /// @notice Thrown when `proposeTimelockDuration` is called while a previous
    ///         duration change is still pending. Admin must
    ///         `cancelTimelockDuration` first.
    error HookProxy_AlreadyPendingTimelockChange();

    /// @notice Thrown when `proposeTimelockDuration` is called with a
    ///         value less than or equal to the current timelock. The timelock
    ///         is monotonic increasing — admin may only raise the delay. An
    ///         equal-value proposal is also rejected so every proposal
    ///         represents an explicit intent change.
    error HookProxy_TimelockCannotDecrease();

    /// @notice Thrown when `executeTimelockDuration` or
    ///         `cancelTimelockDuration` is called with no pending proposal.
    error HookProxy_NoPendingTimelockChange();

    /// @notice Thrown when `executeTimelockDuration` is called before the delay
    ///         derived from the current timelock has elapsed.
    error HookProxy_TimelockDelayNotElapsed();

    /// @notice Thrown when `acceptProxyAdmin` is called before the 48h
    ///         `ADMIN_ROTATION_DELAY` has elapsed since `changeProxyAdmin`.
    ///         Mirrors the timelock pattern across governance flows so a
    ///         compromised admin cannot instant-rotate to a fresh attacker key.
    error HookProxy_AdminDelayNotElapsed();

    /// @notice Thrown when `changeProxyAdmin` is called while a previous admin
    ///         nomination is still pending.
    error HookProxy_AlreadyPendingAdmin();

    /// @notice Thrown when `cancelProxyAdminChange` is called with no pending
    ///         admin nomination.
    error HookProxy_NoPendingAdminChange();

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

    /// @notice Propose a new timelock duration. Applies
    ///         after `executeTimelockDuration` is called, which is itself
    ///         gated by the CURRENT timelock. Floored at 48 hours. Monotonic
    ///         increasing: `duration` must be strictly greater than
    ///         the current value. Admin-only.
    function proposeTimelockDuration(uint256 duration) external;

    /// @notice Finalize a pending timelock duration change after the self-gated
    ///         delay has elapsed. Admin-only.
    function executeTimelockDuration() external;

    /// @notice Discard the pending timelock duration change without applying
    ///         it. Admin-only.
    function cancelTimelockDuration() external;

    // ---------------------------------------------------------------------
    // Admin transfer (two-step)
    // ---------------------------------------------------------------------

    /// @notice Nominate a new proxy admin. The nominee must call
    ///         `acceptProxyAdmin()` AT OR AFTER `pendingProxyAdminReadyAt()` —
    ///         the 48h timelock prevents a compromised admin from
    ///         instant-rotating to a fresh attacker key.
    function changeProxyAdmin(address newAdmin) external;

    /// @notice Accept a pending proxy-admin nomination after the 48h
    ///         timelock has elapsed. Caller-restricted to the nominee.
    function acceptProxyAdmin() external;

    /// @notice Cancel a pending admin nomination before the nominee accepts.
    ///         Admin-only — gives legitimate admin a recovery window if the
    ///         nominee is suspect.
    function cancelProxyAdminChange() external;

    // ---------------------------------------------------------------------
    // Views
    // ---------------------------------------------------------------------

    function implementation() external view returns (address);
    function pendingImplementation() external view returns (address);
    function upgradeReadyAt() external view returns (uint256);
    function timelockDuration() external view returns (uint256);
    /// @notice Pending timelock duration change, or (0, 0) if none.
    function pendingTimelockDuration() external view returns (uint256 duration, uint256 readyAt);
    function proxyAdmin() external view returns (address);
    function pendingProxyAdmin() external view returns (address);

    /// @notice Timestamp at which `acceptProxyAdmin` becomes callable. Returns
    ///         0 when no admin change is pending.
    function pendingProxyAdminReadyAt() external view returns (uint256);
}
