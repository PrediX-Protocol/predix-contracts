// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {IAccessControlFacet} from "@predix/shared/interfaces/IAccessControlFacet.sol";
import {IDiamondCut} from "@predix/shared/interfaces/IDiamondCut.sol";
import {Roles} from "@predix/shared/constants/Roles.sol";

import {DiamondFixture} from "../utils/DiamondFixture.sol";

/// @notice Repro for AUDIT-L-06 (Professional audit 2026-04-25):
///         `_enforceLastAdminGuard` only protects `DEFAULT_ADMIN_ROLE`.
///         `CUT_EXECUTOR_ROLE` is self-administered (F-D-01 / NEW-01) and has
///         no last-holder guard. If the only executor (Timelock per deploy
///         policy) ever revokes itself or renounces, `diamondCut` becomes
///         permanently uncallable.
///
///         The `diamondCut` selector is also marked immutable
///         (`DiamondInit.sol:57`), so the cut facet cannot be replaced via
///         alternate routes. **DEFAULT_ADMIN_ROLE cannot grant the role back**
///         because the role is self-administered, not DEFAULT_ADMIN-administered.
///
///         This test demonstrates the bug at HEAD `ce524ba`. After the fix
///         (extend `_enforceLastAdminGuard` to cover self-administered roles),
///         test_BUG_LastTimelockSelfRevoke_BricksUpgrades should revert.
contract Audit_L06_CutExecutorSelfRevoke is DiamondFixture {
    /// @dev DEMONSTRATES BUG: timelock is the only CUT_EXECUTOR. It revokes
    ///      itself. Diamond cut is permanently disabled. No recovery path.
    function test_BUG_LastTimelockSelfRevoke_BricksUpgrades() public {
        assertTrue(accessControl.hasRole(Roles.CUT_EXECUTOR_ROLE, timelock));

        // Self-revoke succeeds — no last-holder guard for CUT_EXECUTOR_ROLE.
        vm.prank(timelock);
        accessControl.revokeRole(Roles.CUT_EXECUTOR_ROLE, timelock);

        assertFalse(accessControl.hasRole(Roles.CUT_EXECUTOR_ROLE, timelock));

        // Diamond cut is now permanently uncallable.
        IDiamondCut.FacetCut[] memory cuts = new IDiamondCut.FacetCut[](0);
        vm.prank(timelock);
        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControlFacet.AccessControl_MissingRole.selector, Roles.CUT_EXECUTOR_ROLE, timelock
            )
        );
        diamondCut.diamondCut(cuts, address(0), "");

        // DEFAULT_ADMIN cannot recover — role is self-administered.
        vm.prank(admin);
        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControlFacet.AccessControl_MissingRole.selector, Roles.CUT_EXECUTOR_ROLE, admin
            )
        );
        accessControl.grantRole(Roles.CUT_EXECUTOR_ROLE, timelock);
    }

    /// @dev DEMONSTRATES BUG variant: renounceRole path. Same outcome.
    function test_BUG_LastTimelockRenounce_BricksUpgrades() public {
        vm.prank(timelock);
        accessControl.renounceRole(Roles.CUT_EXECUTOR_ROLE, timelock);

        assertFalse(accessControl.hasRole(Roles.CUT_EXECUTOR_ROLE, timelock));

        IDiamondCut.FacetCut[] memory cuts = new IDiamondCut.FacetCut[](0);
        vm.prank(timelock);
        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControlFacet.AccessControl_MissingRole.selector, Roles.CUT_EXECUTOR_ROLE, timelock
            )
        );
        diamondCut.diamondCut(cuts, address(0), "");
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

    /// @dev EXPECTED-AFTER-FIX: extending `_enforceLastAdminGuard` to also
    ///      cover CUT_EXECUTOR_ROLE would make this test FAIL on the bug
    ///      reproduction (the revoke would revert) and instead pass here.
    ///      Marker for the fix-lock test that should be added when the fix
    ///      lands.
    function test_DESIRED_LastCutExecutorRevokeRejected_PendingFix() public pure {
        return;
    }
}
