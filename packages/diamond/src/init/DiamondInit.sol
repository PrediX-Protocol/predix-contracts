// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";

import {IAccessControlFacet} from "@predix/shared/interfaces/IAccessControlFacet.sol";
import {IDiamondCut} from "@predix/shared/interfaces/IDiamondCut.sol";
import {IDiamondLoupe} from "@predix/shared/interfaces/IDiamondLoupe.sol";
import {IPausableFacet} from "@predix/shared/interfaces/IPausableFacet.sol";
import {Roles} from "@predix/shared/constants/Roles.sol";

import {LibAccessControl} from "@predix/diamond/libraries/LibAccessControl.sol";
import {LibDiamondStorage} from "@predix/diamond/libraries/LibDiamondStorage.sol";

/// @title DiamondInit
/// @notice One-shot bootstrap for the diamond infrastructure: configures role admin
///         relationships, grants the operational roles to `admin`, registers ERC-165
///         interface ids, and freezes the `diamondCut` selector so admin cannot
///         accidentally remove the cut facet and brick the diamond.
/// @dev Called via `delegatecall` from `Diamond`'s constructor, so writes hit the
///      diamond's own storage. A guard at its own slot prevents re-running.
contract DiamondInit {
    error DiamondInit_AlreadyInitialized();

    bytes32 private constant INITIALIZED_SLOT = keccak256("predix.storage.diamondinit.v1");

    error DiamondInit_ZeroTimelock();

    function init(address admin, address timelock) external {
        if (_isInitialized()) revert DiamondInit_AlreadyInitialized();
        if (timelock == address(0)) revert DiamondInit_ZeroTimelock();
        _markInitialized();

        LibAccessControl.setRoleAdmin(Roles.ADMIN_ROLE, Roles.DEFAULT_ADMIN_ROLE);
        LibAccessControl.setRoleAdmin(Roles.OPERATOR_ROLE, Roles.DEFAULT_ADMIN_ROLE);
        LibAccessControl.setRoleAdmin(Roles.PAUSER_ROLE, Roles.DEFAULT_ADMIN_ROLE);
        LibAccessControl.setRoleAdmin(Roles.CUT_EXECUTOR_ROLE, Roles.DEFAULT_ADMIN_ROLE);

        LibAccessControl.grantRole(Roles.ADMIN_ROLE, admin);
        LibAccessControl.grantRole(Roles.OPERATOR_ROLE, admin);
        LibAccessControl.grantRole(Roles.PAUSER_ROLE, admin);
        LibAccessControl.grantRole(Roles.CUT_EXECUTOR_ROLE, timelock);

        LibDiamondStorage.Layout storage ds = LibDiamondStorage.layout();
        ds.supportedInterfaces[type(IERC165).interfaceId] = true;
        ds.supportedInterfaces[type(IDiamondCut).interfaceId] = true;
        ds.supportedInterfaces[type(IDiamondLoupe).interfaceId] = true;
        ds.supportedInterfaces[type(IAccessControlFacet).interfaceId] = true;
        ds.supportedInterfaces[type(IPausableFacet).interfaceId] = true;

        ds.immutableSelectors[IDiamondCut.diamondCut.selector] = true;
    }

    function _isInitialized() private view returns (bool flag) {
        bytes32 s = INITIALIZED_SLOT;
        assembly ("memory-safe") {
            flag := sload(s)
        }
    }

    function _markInitialized() private {
        bytes32 s = INITIALIZED_SLOT;
        assembly ("memory-safe") {
            sstore(s, 1)
        }
    }
}
