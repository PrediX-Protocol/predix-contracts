// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import {IAccessControlFacet} from "@predix/shared/interfaces/IAccessControlFacet.sol";
import {Roles} from "@predix/shared/constants/Roles.sol";

import {LibAccessControl} from "@predix/diamond/libraries/LibAccessControl.sol";

/// @title AccessControlFacet
/// @notice OpenZeppelin-style role registry implemented against diamond storage.
/// @dev The last holder of `DEFAULT_ADMIN_ROLE` cannot be removed, otherwise
///      the diamond would lose its only path to grant or rotate admins and
///      become permanently un-administrable.
contract AccessControlFacet is IAccessControlFacet {
    /// @inheritdoc IAccessControlFacet
    function grantRole(bytes32 role, address account) external override {
        LibAccessControl.checkRole(LibAccessControl.getRoleAdmin(role));
        LibAccessControl.grantRole(role, account);
    }

    /// @inheritdoc IAccessControlFacet
    function revokeRole(bytes32 role, address account) external override {
        LibAccessControl.checkRole(LibAccessControl.getRoleAdmin(role));
        // Force callers to address a real holder. The legacy OZ silent-no-op
        // hides governance-call misuse from off-chain audits (no RoleRevoked
        // event is emitted, but the call trace still records a successful
        // privileged call).
        if (!LibAccessControl.hasRole(role, account)) {
            revert AccessControl_NotARoleMember(role, account);
        }
        _enforceLastAdminGuard(role, account);
        LibAccessControl.revokeRole(role, account);
    }

    /// @inheritdoc IAccessControlFacet
    function renounceRole(bytes32 role, address callerConfirmation) external override {
        if (callerConfirmation != msg.sender) revert AccessControl_BadConfirmation();
        // Mirror `revokeRole`'s strict policy. Without this check the library
        // would silently no-op (no `RoleRevoked` event) when `msg.sender` does
        // not actually hold `role`, leaving off-chain audits that key on
        // `tx.success` unable to distinguish a real renounce from a misfire.
        if (!LibAccessControl.hasRole(role, msg.sender)) {
            revert AccessControl_NotARoleMember(role, msg.sender);
        }
        _enforceLastAdminGuard(role, msg.sender);
        LibAccessControl.revokeRole(role, msg.sender);
    }

    function _enforceLastAdminGuard(bytes32 role, address account) private view {
        if (!LibAccessControl.hasRole(role, account)) return;
        if (LibAccessControl.memberCount(role) > 1) return;

        if (role == Roles.DEFAULT_ADMIN_ROLE) revert AccessControl_LastDefaultAdmin();

        // Protect any self-administered role (e.g. CUT_EXECUTOR_ROLE).
        // Emptying a self-administered role's holder set is irrecoverable —
        // no other role can grant it back, so the role becomes dead forever.
        if (LibAccessControl.getRoleAdmin(role) == role) {
            revert AccessControl_LastSelfAdministeredHolder(role);
        }
    }

    /// @inheritdoc IAccessControlFacet
    function hasRole(bytes32 role, address account) external view override returns (bool) {
        return LibAccessControl.hasRole(role, account);
    }

    /// @inheritdoc IAccessControlFacet
    function getRoleAdmin(bytes32 role) external view override returns (bytes32) {
        return LibAccessControl.getRoleAdmin(role);
    }
}
