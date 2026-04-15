// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

/// @title LibAccessControlStorage
/// @notice Diamond storage layout for the AccessControl facet.
library LibAccessControlStorage {
    bytes32 internal constant SLOT = keccak256("predix.storage.access.v1");

    struct RoleData {
        mapping(address => bool) members;
        bytes32 adminRole;
    }

    struct Layout {
        mapping(bytes32 => RoleData) roles;
        // append-only: added in v1.1 to support last-admin lockout protection.
        mapping(bytes32 => uint256) memberCount;
    }

    function layout() internal pure returns (Layout storage l) {
        bytes32 slot = SLOT;
        assembly ("memory-safe") {
            l.slot := slot
        }
    }
}
