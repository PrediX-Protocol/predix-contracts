// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";

import {IPrediXHook} from "../../src/interfaces/IPrediXHook.sol";

import {MockDiamond} from "../utils/MockDiamond.sol";
import {TestHookHarness} from "../utils/TestHookHarness.sol";

/// @notice Repro for FIN-03: `proposeTrustedRouter` must not silently reset
///         the 48h delay timer when called twice for the same router. Without
///         the guard, an admin could repeatedly re-propose and effectively
///         postpone the timelock indefinitely, defeating the purpose of the
///         delay. Admin must `cancelTrustedRouter` first to re-propose.
contract Fin03_ProposeRouterNoReset is Test {
    TestHookHarness internal hook;
    MockDiamond internal diamond;

    address internal constant POOL_MANAGER = address(0xCAFE);
    address internal admin = makeAddr("admin");
    address internal routerA = makeAddr("routerA");
    address internal usdc = address(0x10000);

    function setUp() public {
        diamond = new MockDiamond();
        hook = new TestHookHarness(IPoolManager(POOL_MANAGER), address(0xC0FFEE));
        hook.initialize(address(diamond), admin, usdc);

        vm.prank(admin);
        hook.completeBootstrap();
    }

    function test_Fin03_ReproposeWhilePending_Reverts() public {
        vm.prank(admin);
        hook.proposeTrustedRouter(routerA, true);

        // 24h into the 48h window — re-propose must revert, not silently reset.
        vm.warp(block.timestamp + 24 hours);

        vm.prank(admin);
        vm.expectRevert(IPrediXHook.Hook_AlreadyPendingRouter.selector);
        hook.proposeTrustedRouter(routerA, true);

        // Sanity: the original proposal's timer is intact (readyAt unchanged).
        (, uint256 readyAt) = hook.pendingTrustedRouter(routerA);
        assertEq(
            readyAt,
            block.timestamp - 24 hours + hook.TRUSTED_ROUTER_DELAY(),
            "original readyAt must survive attempted re-propose"
        );
    }

    function test_Fin03_CancelThenRepropose_Success() public {
        vm.prank(admin);
        hook.proposeTrustedRouter(routerA, true);

        vm.prank(admin);
        hook.cancelTrustedRouter(routerA);

        // After cancel, pending slot is cleared — a fresh proposal is accepted.
        uint256 reproposeAt = block.timestamp + 1 hours;
        vm.warp(reproposeAt);

        vm.prank(admin);
        hook.proposeTrustedRouter(routerA, false);

        (bool trusted, uint256 readyAt) = hook.pendingTrustedRouter(routerA);
        assertFalse(trusted, "re-proposed trusted flag must reflect new call");
        assertEq(readyAt, reproposeAt + hook.TRUSTED_ROUTER_DELAY(), "readyAt anchored to re-propose");
    }

    function test_Fin03_ExecuteFirstThenPropose_Success() public {
        vm.prank(admin);
        hook.proposeTrustedRouter(routerA, true);

        vm.warp(block.timestamp + 48 hours + 1);
        hook.executeTrustedRouter(routerA);
        assertTrue(hook.isTrustedRouter(routerA), "execute applied first proposal");

        // Pending is cleared by execute → second proposal for the same router
        // is accepted without needing a cancel.
        vm.prank(admin);
        hook.proposeTrustedRouter(routerA, false);

        (bool trusted, uint256 readyAt) = hook.pendingTrustedRouter(routerA);
        assertFalse(trusted, "second proposal recorded");
        assertEq(readyAt, block.timestamp + hook.TRUSTED_ROUTER_DELAY(), "second readyAt correct");
    }
}
