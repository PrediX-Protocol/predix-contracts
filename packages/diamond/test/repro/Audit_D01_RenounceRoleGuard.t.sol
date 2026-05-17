// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import {IAccessControlFacet} from "@predix/shared/interfaces/IAccessControlFacet.sol";
import {Roles} from "@predix/shared/constants/Roles.sol";

import {DiamondFixture} from "../utils/DiamondFixture.sol";

/// @title Audit_D01_RenounceRoleGuard
/// @notice Audit D-NEW-01 (pass-2): pass-1 N-11 added a strict `NotARoleMember`
///         revert to `revokeRole` so off-chain governance audits could no longer
///         be misled by silent no-ops. The same guard was missing from
///         `renounceRole`; this test pins the symmetric behavior so a
///         renounce against a role the caller does not hold reverts loudly
///         instead of succeeding without an event.
contract Audit_D01_RenounceRoleGuard is DiamondFixture {
    address internal alice = makeAddr("D01_alice");
    address internal bob = makeAddr("D01_bob");

    /// @notice Caller who actually holds the role can still renounce — happy
    ///         path must not regress.
    function test_D01_RenounceRole_HolderStillSucceeds() public {
        vm.prank(admin);
        accessControl.grantRole(Roles.OPERATOR_ROLE, alice);
        assertTrue(accessControl.hasRole(Roles.OPERATOR_ROLE, alice));

        vm.expectEmit(true, true, true, true);
        emit IAccessControlFacet.RoleRevoked(Roles.OPERATOR_ROLE, alice, alice);
        vm.prank(alice);
        accessControl.renounceRole(Roles.OPERATOR_ROLE, alice);

        assertFalse(accessControl.hasRole(Roles.OPERATOR_ROLE, alice));
    }

    /// @notice Caller who does NOT hold the role reverts with
    ///         `AccessControl_NotARoleMember`. Previously this was a silent
    ///         no-op via the library's early return.
    function test_Revert_D01_RenounceRole_NotAMember() public {
        // bob holds nothing.
        assertFalse(accessControl.hasRole(Roles.OPERATOR_ROLE, bob));

        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControlFacet.AccessControl_NotARoleMember.selector, Roles.OPERATOR_ROLE, bob
            )
        );
        vm.prank(bob);
        accessControl.renounceRole(Roles.OPERATOR_ROLE, bob);
    }

    /// @notice `callerConfirmation` mismatch still wins over the membership
    ///         check (the confirmation guard is the first line of defence).
    function test_Revert_D01_RenounceRole_BadConfirmationStillTakesPrecedence() public {
        vm.expectRevert(IAccessControlFacet.AccessControl_BadConfirmation.selector);
        vm.prank(alice);
        accessControl.renounceRole(Roles.OPERATOR_ROLE, bob);
    }
}
