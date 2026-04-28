// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

/// @title IAccessControlFacet
/// @notice Diamond-storage-backed AccessControl facet, modelled on OpenZeppelin's AccessControl.
/// @dev Each role has an admin role; the admin role of `DEFAULT_ADMIN_ROLE` is itself.
///      All state lives in the AccessControl diamond storage slot, never in a base contract.
interface IAccessControlFacet {
    event RoleGranted(bytes32 indexed role, address indexed account, address indexed sender);
    event RoleRevoked(bytes32 indexed role, address indexed account, address indexed sender);
    event RoleAdminChanged(bytes32 indexed role, bytes32 indexed previousAdminRole, bytes32 indexed newAdminRole);

    error AccessControl_MissingRole(bytes32 role, address account);
    error AccessControl_BadConfirmation();
    error AccessControl_LastDefaultAdmin();
    /// @notice Reverts when revoke/renounce would empty a self-administered role.
    ///         Self-administered roles (`getRoleAdmin(role) == role`) cannot be
    ///         re-granted from outside — emptying the holder set bricks the role
    ///         permanently.
    error AccessControl_LastSelfAdministeredHolder(bytes32 role);

    /// @notice Whether `account` holds `role`.
    function hasRole(bytes32 role, address account) external view returns (bool);

    /// @notice Returns the admin role that controls `role`.
    function getRoleAdmin(bytes32 role) external view returns (bytes32);

    /// @notice Grant `role` to `account`. Caller must hold `getRoleAdmin(role)`.
    function grantRole(bytes32 role, address account) external;

    /// @notice Revoke `role` from `account`. Caller must hold `getRoleAdmin(role)`.
    function revokeRole(bytes32 role, address account) external;

    /// @notice Renounce `role` for the caller. `callerConfirmation` must equal `msg.sender`
    ///         to prevent accidental renunciation via wrong-account proxy calls.
    function renounceRole(bytes32 role, address callerConfirmation) external;
}
