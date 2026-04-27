// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {IAccessControlFacet} from "@predix/shared/interfaces/IAccessControlFacet.sol";
import {IDiamondCut} from "@predix/shared/interfaces/IDiamondCut.sol";
import {Roles} from "@predix/shared/constants/Roles.sol";

import {DiamondFixture} from "../utils/DiamondFixture.sol";

/// @notice Fix-lock for AUDIT-L-05 (Pass 2.1, was L-06 in Pass 1):
///         `_enforceLastAdminGuard` extended to cover self-administered roles
///         (e.g. `CUT_EXECUTOR_ROLE`). The last holder of a self-administered
///         role can no longer revoke/renounce because emptying the holder set
///         is irrecoverable — no other role can grant the role back.
///
///         Test names retained as `test_Revert_*` to lock the fix; the prior
///         `test_BUG_*` repros (which passed when the bug existed) have been
///         inverted to assert revert with `AccessControl_LastSelfAdministeredHolder`.
contract Audit_L06_CutExecutorSelfRevoke is DiamondFixture {
    /// @dev FIX-LOCK: timelock is the only CUT_EXECUTOR. Self-revoke must
    ///      revert with `AccessControl_LastSelfAdministeredHolder` to prevent
    ///      the brick.
    function test_Revert_LastTimelockSelfRevoke_RejectsBrick() public {
        assertTrue(accessControl.hasRole(Roles.CUT_EXECUTOR_ROLE, timelock));

        vm.prank(timelock);
        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControlFacet.AccessControl_LastSelfAdministeredHolder.selector, Roles.CUT_EXECUTOR_ROLE
            )
        );
        accessControl.revokeRole(Roles.CUT_EXECUTOR_ROLE, timelock);

        // Sanity: timelock still holds, diamondCut still callable.
        assertTrue(accessControl.hasRole(Roles.CUT_EXECUTOR_ROLE, timelock));
        IDiamondCut.FacetCut[] memory cuts = new IDiamondCut.FacetCut[](0);
        vm.prank(timelock);
        diamondCut.diamondCut(cuts, address(0), "");
    }

    /// @dev FIX-LOCK: renounceRole path also blocked.
    function test_Revert_LastTimelockRenounce_RejectsBrick() public {
        vm.prank(timelock);
        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControlFacet.AccessControl_LastSelfAdministeredHolder.selector, Roles.CUT_EXECUTOR_ROLE
            )
        );
        accessControl.renounceRole(Roles.CUT_EXECUTOR_ROLE, timelock);

        assertTrue(accessControl.hasRole(Roles.CUT_EXECUTOR_ROLE, timelock));
    }

    /// @dev Sanity: with TWO executors, revoking one does NOT brick. Justifies
    ///      the recommended fix (allow self-revoke only when memberCount > 1).
    function test_Sanity_RevokeOneExecutor_StillFunctional() public {
        address secondExec = makeAddr("secondExec");
        vm.prank(timelock);
        accessControl.grantRole(Roles.CUT_EXECUTOR_ROLE, secondExec);

        vm.prank(timelock);
        accessControl.revokeRole(Roles.CUT_EXECUTOR_ROLE, timelock);

        // Diamond cut still callable via the second executor.
        IDiamondCut.FacetCut[] memory cuts = new IDiamondCut.FacetCut[](0);
        vm.prank(secondExec);
        diamondCut.diamondCut(cuts, address(0), "");
    }

    /// @dev Sanity: DEFAULT_ADMIN_ROLE has the last-holder guard (proves
    ///      the protection pattern exists, just not extended to CUT_EXECUTOR).
    function test_Sanity_DefaultAdminLastHolderProtected() public {
        vm.prank(admin);
        vm.expectRevert(IAccessControlFacet.AccessControl_LastDefaultAdmin.selector);
        accessControl.revokeRole(Roles.DEFAULT_ADMIN_ROLE, admin);
    }

    /// @dev FIX-LOCK: with two executors, revoking one MUST succeed (only
    ///      blocks when emptying the holder set).
    function test_TwoExecutors_RevokeOne_Succeeds() public {
        address secondExec = makeAddr("secondExec");
        vm.prank(timelock);
        accessControl.grantRole(Roles.CUT_EXECUTOR_ROLE, secondExec);

        // Revoking ONE of two is allowed.
        vm.prank(timelock);
        accessControl.revokeRole(Roles.CUT_EXECUTOR_ROLE, timelock);

        assertFalse(accessControl.hasRole(Roles.CUT_EXECUTOR_ROLE, timelock));
        assertTrue(accessControl.hasRole(Roles.CUT_EXECUTOR_ROLE, secondExec));
    }
}
