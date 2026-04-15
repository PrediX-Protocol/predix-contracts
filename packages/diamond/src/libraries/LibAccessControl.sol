// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {IAccessControlFacet} from "@predix/shared/interfaces/IAccessControlFacet.sol";

import {LibAccessControlStorage} from "@predix/diamond/libraries/LibAccessControlStorage.sol";

/// @title LibAccessControl
/// @notice Internal helpers for role checks and mutations against AccessControl storage.
/// @dev Other facets call `checkRole` at the top of any role-protected function.
library LibAccessControl {
    function hasRole(bytes32 role, address account) internal view returns (bool) {
        return LibAccessControlStorage.layout().roles[role].members[account];
    }

    function getRoleAdmin(bytes32 role) internal view returns (bytes32) {
        return LibAccessControlStorage.layout().roles[role].adminRole;
    }

    function checkRole(bytes32 role) internal view {
        if (!hasRole(role, msg.sender)) {
            revert IAccessControlFacet.AccessControl_MissingRole(role, msg.sender);
        }
    }

    function setRoleAdmin(bytes32 role, bytes32 adminRole) internal {
        bytes32 previous = LibAccessControlStorage.layout().roles[role].adminRole;
        LibAccessControlStorage.layout().roles[role].adminRole = adminRole;
        emit IAccessControlFacet.RoleAdminChanged(role, previous, adminRole);
    }

    /// @return changed True iff `account` did not already hold `role`.
    function grantRole(bytes32 role, address account) internal returns (bool changed) {
        LibAccessControlStorage.Layout storage l = LibAccessControlStorage.layout();
        LibAccessControlStorage.RoleData storage data = l.roles[role];
        if (data.members[account]) return false;
        data.members[account] = true;
        l.memberCount[role] += 1;
        emit IAccessControlFacet.RoleGranted(role, account, msg.sender);
        return true;
    }

    /// @return changed True iff `account` did hold `role`.
    function revokeRole(bytes32 role, address account) internal returns (bool changed) {
        LibAccessControlStorage.Layout storage l = LibAccessControlStorage.layout();
        LibAccessControlStorage.RoleData storage data = l.roles[role];
        if (!data.members[account]) return false;
        data.members[account] = false;
        l.memberCount[role] -= 1;
        emit IAccessControlFacet.RoleRevoked(role, account, msg.sender);
        return true;
    }

    /// @notice Number of accounts currently holding `role`.
    function memberCount(bytes32 role) internal view returns (uint256) {
        return LibAccessControlStorage.layout().memberCount[role];
    }
}
