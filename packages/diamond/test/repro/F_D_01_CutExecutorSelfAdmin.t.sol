// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {IAccessControlFacet} from "@predix/shared/interfaces/IAccessControlFacet.sol";
import {IDiamondCut} from "@predix/shared/interfaces/IDiamondCut.sol";
import {Roles} from "@predix/shared/constants/Roles.sol";

import {DiamondFixture} from "../utils/DiamondFixture.sol";

/// @notice Repro for F-D-01 / NEW-01: `CUT_EXECUTOR_ROLE` is self-administered.
///         `DEFAULT_ADMIN_ROLE` must NOT be able to self-grant `CUT_EXECUTOR_ROLE`
///         and bypass the 48h timelock.
contract F_D_01_CutExecutorSelfAdmin is DiamondFixture {
    function test_F_D_01_cutExecutorRoleAdminIsSelf() public view {
        bytes32 roleAdmin = accessControl.getRoleAdmin(Roles.CUT_EXECUTOR_ROLE);
        assertEq(roleAdmin, Roles.CUT_EXECUTOR_ROLE, "CUT_EXECUTOR_ROLE must self-administer");
    }

    function test_Revert_F_D_01_adminCannotSelfGrantCutExecutor() public {
        // `admin` holds DEFAULT_ADMIN_ROLE + ADMIN/OPERATOR/PAUSER (from fixture).
        // Must NOT be able to grant CUT_EXECUTOR to itself.
        vm.prank(admin);
        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControlFacet.AccessControl_MissingRole.selector, Roles.CUT_EXECUTOR_ROLE, admin
            )
        );
        accessControl.grantRole(Roles.CUT_EXECUTOR_ROLE, admin);
    }

    function test_Revert_F_D_01_adminCannotGrantCutExecutorToThirdParty() public {
        address attacker = makeAddr("attacker");
        vm.prank(admin);
        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControlFacet.AccessControl_MissingRole.selector, Roles.CUT_EXECUTOR_ROLE, admin
            )
        );
        accessControl.grantRole(Roles.CUT_EXECUTOR_ROLE, attacker);
    }

    function test_F_D_01_timelockCanGrantCutExecutor() public {
        // Only current CUT_EXECUTOR (timelock, post-deploy) can grant the role.
        address newCutter = makeAddr("newCutter");
        vm.prank(timelock);
        accessControl.grantRole(Roles.CUT_EXECUTOR_ROLE, newCutter);
        assertTrue(accessControl.hasRole(Roles.CUT_EXECUTOR_ROLE, newCutter));
    }

    function test_Revert_F_D_01_twoTxBypassBlocked() public {
        // Full 2-tx bypass scenario from audit: admin self-grants, then cuts.
        // Must fail on the grant step.
        vm.startPrank(admin);
        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControlFacet.AccessControl_MissingRole.selector, Roles.CUT_EXECUTOR_ROLE, admin
            )
        );
        accessControl.grantRole(Roles.CUT_EXECUTOR_ROLE, admin);
        vm.stopPrank();

        // Sanity: admin still cannot diamondCut (since grant reverted, admin has no CUT_EXECUTOR)
        IDiamondCut.FacetCut[] memory cuts = new IDiamondCut.FacetCut[](0);
        vm.prank(admin);
        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControlFacet.AccessControl_MissingRole.selector, Roles.CUT_EXECUTOR_ROLE, admin
            )
        );
        diamondCut.diamondCut(cuts, address(0), "");
    }
}
