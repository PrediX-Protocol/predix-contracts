// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

/// @notice Minimal IAccessControlFacet stub: grant/revoke roles in tests.
contract MockAccessControl {
    mapping(bytes32 => mapping(address => bool)) public roles;

    function grant(bytes32 role, address account) external {
        roles[role][account] = true;
    }

    function hasRole(bytes32 role, address account) external view returns (bool) {
        return roles[role][account];
    }
}
