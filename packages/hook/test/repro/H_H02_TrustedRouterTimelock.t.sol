// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";

import {IPrediXHook} from "../../src/interfaces/IPrediXHook.sol";

import {MockDiamond} from "../utils/MockDiamond.sol";
import {TestHookHarness} from "../utils/TestHookHarness.sol";

/// @notice Repro for H-H02: post-bootstrap, `setTrustedRouter` is locked
///         and trust changes must route through `proposeTrustedRouter` →
///         48h delay → `executeTrustedRouter`.
contract H_H02_TrustedRouterTimelock is Test {
    TestHookHarness internal hook;
    MockDiamond internal diamond;

    address internal constant POOL_MANAGER = address(0xCAFE);
    address internal admin = makeAddr("admin");
    address internal routerA = makeAddr("routerA");
    address internal routerB = makeAddr("routerB");
    address internal usdc = address(0x10000);

    function setUp() public {
        diamond = new MockDiamond();
        hook = new TestHookHarness(IPoolManager(POOL_MANAGER));
        hook.initialize(address(diamond), admin, usdc);
    }

    // --- Bootstrap window ---

    function test_H_H02_bootstrapDefaultsFalse() public view {
        assertFalse(hook.bootstrapped());
    }

    function test_H_H02_setTrustedRouterWorksDuringBootstrap() public {
        vm.prank(admin);
        hook.setTrustedRouter(routerA, true);
        assertTrue(hook.isTrustedRouter(routerA));
    }

    function test_H_H02_completeBootstrapLocksSetter() public {
        vm.prank(admin);
        hook.setTrustedRouter(routerA, true);
        vm.prank(admin);
        hook.completeBootstrap();

        assertTrue(hook.bootstrapped());

        vm.prank(admin);
        vm.expectRevert(IPrediXHook.Hook_BootstrapComplete.selector);
        hook.setTrustedRouter(routerB, true);
    }

    function test_Revert_H_H02_completeBootstrapIsOneShot() public {
        vm.prank(admin);
        hook.completeBootstrap();
        vm.prank(admin);
        vm.expectRevert(IPrediXHook.Hook_BootstrapComplete.selector);
        hook.completeBootstrap();
    }

    // --- Propose / execute flow ---

    function test_Revert_H_H02_proposeBeforeBootstrapReverts() public {
        vm.prank(admin);
        vm.expectRevert(IPrediXHook.Hook_BootstrapNotComplete.selector);
        hook.proposeTrustedRouter(routerA, true);
    }

    function test_H_H02_proposeStoresPendingState() public {
        vm.prank(admin);
        hook.completeBootstrap();
        vm.prank(admin);
        hook.proposeTrustedRouter(routerA, true);

        (bool trusted, uint256 readyAt) = hook.pendingTrustedRouter(routerA);
        assertTrue(trusted, "pending trusted state");
        assertEq(readyAt, block.timestamp + hook.TRUSTED_ROUTER_DELAY(), "readyAt = now + 48h");
    }

    function test_Revert_H_H02_executeBeforeDelayReverts() public {
        vm.prank(admin);
        hook.completeBootstrap();
        vm.prank(admin);
        hook.proposeTrustedRouter(routerA, true);

        vm.expectRevert(IPrediXHook.Hook_TrustedRouterDelayNotElapsed.selector);
        hook.executeTrustedRouter(routerA);

        // Still not after 47h59m59s.
        vm.warp(block.timestamp + 48 hours - 1);
        vm.expectRevert(IPrediXHook.Hook_TrustedRouterDelayNotElapsed.selector);
        hook.executeTrustedRouter(routerA);
    }

    function test_H_H02_executeAfterDelayApplies() public {
        vm.prank(admin);
        hook.completeBootstrap();
        vm.prank(admin);
        hook.proposeTrustedRouter(routerA, true);

        vm.warp(block.timestamp + 48 hours + 1);
        hook.executeTrustedRouter(routerA);

        assertTrue(hook.isTrustedRouter(routerA));
        // Pending cleared.
        (, uint256 readyAt) = hook.pendingTrustedRouter(routerA);
        assertEq(readyAt, 0);
    }

    function test_H_H02_cancelClearsPending() public {
        vm.prank(admin);
        hook.completeBootstrap();
        vm.prank(admin);
        hook.proposeTrustedRouter(routerA, true);

        vm.prank(admin);
        hook.cancelTrustedRouter(routerA);

        (, uint256 readyAt) = hook.pendingTrustedRouter(routerA);
        assertEq(readyAt, 0, "pending cleared");

        // After cancel, executing reverts.
        vm.warp(block.timestamp + 48 hours + 1);
        vm.expectRevert(IPrediXHook.Hook_NoPendingRouterChange.selector);
        hook.executeTrustedRouter(routerA);
    }

    function test_Revert_H_H02_executeWithoutProposalReverts() public {
        vm.prank(admin);
        hook.completeBootstrap();
        vm.expectRevert(IPrediXHook.Hook_NoPendingRouterChange.selector);
        hook.executeTrustedRouter(routerA);
    }

    function test_Revert_H_H02_cancelWithoutProposalReverts() public {
        vm.prank(admin);
        hook.completeBootstrap();
        vm.prank(admin);
        vm.expectRevert(IPrediXHook.Hook_NoPendingRouterChange.selector);
        hook.cancelTrustedRouter(routerA);
    }

    function test_H_H02_proposalCanFlipBothDirections() public {
        // Grant during bootstrap.
        vm.prank(admin);
        hook.setTrustedRouter(routerA, true);
        vm.prank(admin);
        hook.completeBootstrap();
        assertTrue(hook.isTrustedRouter(routerA));

        // Remove via delayed path.
        vm.prank(admin);
        hook.proposeTrustedRouter(routerA, false);
        vm.warp(block.timestamp + 48 hours + 1);
        hook.executeTrustedRouter(routerA);
        assertFalse(hook.isTrustedRouter(routerA));
    }
}
