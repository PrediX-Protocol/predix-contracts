// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";

import {IPrediXHook} from "../../src/interfaces/IPrediXHook.sol";

import {MockDiamond} from "../utils/MockDiamond.sol";
import {TestHookHarness} from "../utils/TestHookHarness.sol";

/// @dev FINAL-H09 repro: `setAdmin` was single-step, so a compromised admin key
///      could immediately lock out the legitimate admin and pause the hook or
///      rebind the diamond. Post-fix, `setAdmin` only PROPOSES; the new admin must
///      call `acceptAdmin()` to complete the rotation.
contract FinalH09Test is Test {
    TestHookHarness internal hook;
    MockDiamond internal diamond;

    address internal admin = makeAddr("admin");
    address internal newAdmin = makeAddr("newAdmin");
    address internal stranger = makeAddr("stranger");
    address internal usdc = address(0x10000);

    function setUp() public {
        diamond = new MockDiamond();
        hook = new TestHookHarness(IPoolManager(address(0xCAFE)), address(0xC0FFEE));
        hook.initialize(address(diamond), admin, usdc);
    }

    function test_SetAdmin_OnlyProposes_AdminUnchangedUntilAccept() public {
        vm.prank(admin);
        hook.setAdmin(newAdmin);
        // Admin MUST NOT have rotated yet.
        assertEq(hook.admin(), admin);
    }

    function test_SetAdmin_EmitsChangeProposed() public {
        vm.expectEmit(true, true, false, false);
        emit IPrediXHook.Hook_AdminChangeProposed(admin, newAdmin);
        vm.prank(admin);
        hook.setAdmin(newAdmin);
    }

    function test_AcceptAdmin_HappyPath_RotatesAdmin() public {
        vm.prank(admin);
        hook.setAdmin(newAdmin);
        vm.prank(newAdmin);
        hook.acceptAdmin();
        assertEq(hook.admin(), newAdmin);
        // Old admin is no longer authorised.
        vm.prank(admin);
        vm.expectRevert(IPrediXHook.Hook_OnlyAdmin.selector);
        hook.setPaused(true);
    }

    function test_Revert_AcceptAdmin_NotPending() public {
        vm.prank(admin);
        hook.setAdmin(newAdmin);
        vm.prank(stranger);
        vm.expectRevert(IPrediXHook.Hook_OnlyPendingAdmin.selector);
        hook.acceptAdmin();
    }

    function test_Revert_AcceptAdmin_NothingPending() public {
        vm.expectRevert(IPrediXHook.Hook_OnlyPendingAdmin.selector);
        hook.acceptAdmin();
    }

    function test_AcceptAdmin_ClearsPending_PreventsReplay() public {
        vm.prank(admin);
        hook.setAdmin(newAdmin);
        vm.prank(newAdmin);
        hook.acceptAdmin();
        // Second acceptance attempt must fail — pending slot cleared.
        vm.prank(newAdmin);
        vm.expectRevert(IPrediXHook.Hook_OnlyPendingAdmin.selector);
        hook.acceptAdmin();
    }
}
