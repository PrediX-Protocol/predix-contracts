// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";

import {IPrediXHook} from "../../src/interfaces/IPrediXHook.sol";
import {PrediXHookV2} from "../../src/hooks/PrediXHookV2.sol";

import {MockDiamond} from "../utils/MockDiamond.sol";
import {TestHookHarness} from "../utils/TestHookHarness.sol";

/// @notice Fix-lock for AUDIT-M-03 (Pass 2.1):
///         Hook admin rotation now carries a 48h timelock matching the rest
///         of the hook's governance flows. `setAdmin` proposes; `acceptAdmin`
///         requires `block.timestamp >= proposedAt + ADMIN_ROTATION_DELAY`;
///         `cancelAdminRotation` lets legitimate admin recover before the
///         delay elapses.
contract Audit_M03_AdminRotationNoTimelock is Test {
    TestHookHarness internal hook;
    MockDiamond internal diamond;

    address internal legitAdmin = makeAddr("legitAdmin");
    address internal compromisedAttacker = makeAddr("attacker");
    address internal usdc = address(0x10000);

    function setUp() public {
        diamond = new MockDiamond();
        hook = new TestHookHarness(IPoolManager(address(0xCAFE)), address(0xC0FFEE));
        hook.initialize(address(diamond), legitAdmin, usdc);
    }

    /// @dev FIX-LOCK: instant rotation now blocked by `Hook_AdminDelayNotElapsed`.
    function test_Revert_AcceptAdmin_BeforeDelay() public {
        vm.prank(legitAdmin);
        hook.setAdmin(compromisedAttacker);

        vm.prank(compromisedAttacker);
        vm.expectRevert(IPrediXHook.Hook_AdminDelayNotElapsed.selector);
        hook.acceptAdmin();

        // Admin unchanged.
        assertEq(hook.admin(), legitAdmin);
    }

    /// @dev FIX-LOCK: rotation completes only after 48h.
    function test_AcceptAdmin_AfterDelay_Succeeds() public {
        vm.prank(legitAdmin);
        hook.setAdmin(compromisedAttacker);

        vm.warp(block.timestamp + 48 hours + 1);
        vm.prank(compromisedAttacker);
        hook.acceptAdmin();

        assertEq(hook.admin(), compromisedAttacker);
    }

    /// @dev FIX-LOCK: legitimate admin can cancel a malicious nomination
    ///      during the 48h window.
    function test_CancelAdminRotation_RecoversInWindow() public {
        vm.prank(legitAdmin);
        hook.setAdmin(compromisedAttacker);

        // Within 48h window, admin notices and cancels.
        vm.warp(block.timestamp + 24 hours);
        vm.prank(legitAdmin);
        hook.cancelAdminRotation();

        // Even after delay elapses, attacker can no longer accept.
        vm.warp(block.timestamp + 48 hours);
        vm.prank(compromisedAttacker);
        vm.expectRevert(IPrediXHook.Hook_OnlyPendingAdmin.selector);
        hook.acceptAdmin();

        assertEq(hook.admin(), legitAdmin);
    }

    /// @dev FIX-LOCK: AlreadyPending guard (M-01 universal) prevents
    ///      compromised admin from silently overwriting a legitimate
    ///      pending nomination.
    function test_Revert_SetAdmin_WhilePending_RejectsOverwrite() public {
        address legitNew = makeAddr("legitNew");
        vm.prank(legitAdmin);
        hook.setAdmin(legitNew);

        // Compromised admin tries to redirect rotation.
        vm.prank(legitAdmin); // simulate compromised key still legitAdmin
        vm.expectRevert(IPrediXHook.Hook_AlreadyPendingAdmin.selector);
        hook.setAdmin(compromisedAttacker);
    }

    /// @dev FIX-LOCK: cancelAdminRotation reverts when no pending change.
    function test_Revert_CancelAdminRotation_NoPending() public {
        vm.prank(legitAdmin);
        vm.expectRevert(IPrediXHook.Hook_NoPendingAdminChange.selector);
        hook.cancelAdminRotation();
    }

    /// @dev FIX-LOCK: pendingAdminRotation view reports correct state.
    function test_PendingAdminRotation_View() public {
        (address p, uint256 r) = hook.pendingAdminRotation();
        assertEq(p, address(0));
        assertEq(r, 0);

        uint256 t0 = block.timestamp;
        vm.prank(legitAdmin);
        hook.setAdmin(compromisedAttacker);

        (p, r) = hook.pendingAdminRotation();
        assertEq(p, compromisedAttacker);
        assertEq(r, t0 + hook.ADMIN_ROTATION_DELAY());
    }

    /// @dev Sanity: ADMIN_ROTATION_DELAY mirrors the other governance delays.
    function test_AdminRotationDelay_MirrorsOtherFlows() public view {
        assertEq(hook.ADMIN_ROTATION_DELAY(), 48 hours);
        assertEq(hook.DIAMOND_ROTATION_DELAY(), 48 hours);
        assertEq(hook.TRUSTED_ROUTER_DELAY(), 48 hours);
        assertEq(hook.MARKET_UNREGISTER_DELAY(), 48 hours);
    }
}
