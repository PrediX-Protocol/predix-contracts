// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {IAccessControlFacet} from "@predix/shared/interfaces/IAccessControlFacet.sol";
import {Roles} from "@predix/shared/constants/Roles.sol";

import {DiamondFixture} from "../utils/DiamondFixture.sol";

contract AccessControlTest is DiamondFixture {
    bytes32 internal constant CUSTOM_ROLE = keccak256("test.custom");
    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");

    function test_Init_GrantsAdminAllOperationalRoles() public view {
        assertTrue(accessControl.hasRole(Roles.DEFAULT_ADMIN_ROLE, admin));
        assertTrue(accessControl.hasRole(Roles.ADMIN_ROLE, admin));
        assertTrue(accessControl.hasRole(Roles.OPERATOR_ROLE, admin));
        assertTrue(accessControl.hasRole(Roles.PAUSER_ROLE, admin));
    }

    function test_GetRoleAdmin_OperationalRolesAdminedByDefault() public view {
        assertEq(accessControl.getRoleAdmin(Roles.ADMIN_ROLE), Roles.DEFAULT_ADMIN_ROLE);
        assertEq(accessControl.getRoleAdmin(Roles.OPERATOR_ROLE), Roles.DEFAULT_ADMIN_ROLE);
        assertEq(accessControl.getRoleAdmin(Roles.PAUSER_ROLE), Roles.DEFAULT_ADMIN_ROLE);
    }

    function test_GrantRole_HappyPath() public {
        vm.expectEmit(true, true, true, true);
        emit IAccessControlFacet.RoleGranted(Roles.OPERATOR_ROLE, alice, admin);
        vm.prank(admin);
        accessControl.grantRole(Roles.OPERATOR_ROLE, alice);
        assertTrue(accessControl.hasRole(Roles.OPERATOR_ROLE, alice));
    }

    function test_RevokeRole_HappyPath() public {
        vm.prank(admin);
        accessControl.grantRole(Roles.OPERATOR_ROLE, alice);

        vm.expectEmit(true, true, true, true);
        emit IAccessControlFacet.RoleRevoked(Roles.OPERATOR_ROLE, alice, admin);
        vm.prank(admin);
        accessControl.revokeRole(Roles.OPERATOR_ROLE, alice);
        assertFalse(accessControl.hasRole(Roles.OPERATOR_ROLE, alice));
    }

    function test_Revert_GrantRole_NotAdminOfRole() public {
        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControlFacet.AccessControl_MissingRole.selector, Roles.DEFAULT_ADMIN_ROLE, bob
            )
        );
        vm.prank(bob);
        accessControl.grantRole(Roles.OPERATOR_ROLE, alice);
    }

    function test_Revert_RevokeRole_NotAdminOfRole() public {
        vm.prank(admin);
        accessControl.grantRole(Roles.OPERATOR_ROLE, alice);

        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControlFacet.AccessControl_MissingRole.selector, Roles.DEFAULT_ADMIN_ROLE, bob
            )
        );
        vm.prank(bob);
        accessControl.revokeRole(Roles.OPERATOR_ROLE, alice);
    }

    function test_RenounceRole_HappyPath() public {
        vm.prank(admin);
        accessControl.grantRole(Roles.PAUSER_ROLE, alice);

        vm.prank(alice);
        accessControl.renounceRole(Roles.PAUSER_ROLE, alice);
        assertFalse(accessControl.hasRole(Roles.PAUSER_ROLE, alice));
    }

    function test_Revert_RenounceRole_BadConfirmation() public {
        vm.prank(admin);
        accessControl.grantRole(Roles.PAUSER_ROLE, alice);

        vm.expectRevert(IAccessControlFacet.AccessControl_BadConfirmation.selector);
        vm.prank(alice);
        accessControl.renounceRole(Roles.PAUSER_ROLE, bob);
    }

    function test_Revert_RevokeRole_LastDefaultAdmin() public {
        vm.expectRevert(IAccessControlFacet.AccessControl_LastDefaultAdmin.selector);
        vm.prank(admin);
        accessControl.revokeRole(Roles.DEFAULT_ADMIN_ROLE, admin);
    }

    function test_Revert_RenounceRole_LastDefaultAdmin() public {
        vm.expectRevert(IAccessControlFacet.AccessControl_LastDefaultAdmin.selector);
        vm.prank(admin);
        accessControl.renounceRole(Roles.DEFAULT_ADMIN_ROLE, admin);
    }

    function test_RevokeRole_DefaultAdmin_AfterGrantingSecond() public {
        vm.startPrank(admin);
        accessControl.grantRole(Roles.DEFAULT_ADMIN_ROLE, alice);
        accessControl.revokeRole(Roles.DEFAULT_ADMIN_ROLE, admin);
        vm.stopPrank();
        assertFalse(accessControl.hasRole(Roles.DEFAULT_ADMIN_ROLE, admin));
        assertTrue(accessControl.hasRole(Roles.DEFAULT_ADMIN_ROLE, alice));
    }

    function test_RenounceRole_NonDefaultAdmin_DoesNotTriggerGuard() public {
        vm.prank(admin);
        accessControl.renounceRole(Roles.OPERATOR_ROLE, admin);
        assertFalse(accessControl.hasRole(Roles.OPERATOR_ROLE, admin));
    }

    function test_GrantRole_Idempotent() public {
        vm.startPrank(admin);
        accessControl.grantRole(Roles.OPERATOR_ROLE, alice);
        accessControl.grantRole(Roles.OPERATOR_ROLE, alice);
        vm.stopPrank();
        assertTrue(accessControl.hasRole(Roles.OPERATOR_ROLE, alice));
    }
}
