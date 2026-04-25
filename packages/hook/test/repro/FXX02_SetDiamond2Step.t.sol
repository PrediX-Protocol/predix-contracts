// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";

import {IPrediXHook} from "../../src/interfaces/IPrediXHook.sol";

import {MockDiamond} from "../utils/MockDiamond.sol";
import {TestHookHarness} from "../utils/TestHookHarness.sol";

/// @notice Repro for F-X-02: `setDiamond` single-step is replaced by a
///         48h propose/execute flow. Pre-fix, a compromised admin could
///         redirect all market queries to a malicious diamond in one
///         transaction; the delay lets off-chain watchers react.
///
///         Also locks in the intentional stale-binding behaviour: the
///         rotation does NOT clear `_poolBinding` / `_marketToPoolId` so
///         ops must manually re-register markets under the new diamond.
contract FXX02_SetDiamond2Step is Test {
    using PoolIdLibrary for PoolKey;

    TestHookHarness internal hook;
    MockDiamond internal oldDiamond;

    address internal constant POOL_MANAGER = address(0xCAFE);
    address internal admin = makeAddr("admin");
    address internal rando = makeAddr("rando");
    address internal usdc = address(0x10000);

    function setUp() public {
        oldDiamond = new MockDiamond();
        hook = new TestHookHarness(IPoolManager(POOL_MANAGER), address(0xC0FFEE));
        hook.initialize(address(oldDiamond), admin, usdc);
    }

    function test_FXX02_ProposeDiamond_EmitsEvent() public {
        address newDiamond = address(new MockDiamond());
        uint256 expectedReadyAt = block.timestamp + hook.DIAMOND_ROTATION_DELAY();

        vm.expectEmit(true, true, true, true, address(hook));
        emit IPrediXHook.Hook_DiamondRotationProposed(newDiamond, expectedReadyAt);

        vm.prank(admin);
        hook.proposeDiamond(newDiamond);

        (address pending, uint256 readyAt) = hook.pendingDiamond();
        assertEq(pending, newDiamond, "pending diamond recorded");
        assertEq(readyAt, expectedReadyAt, "readyAt = now + 48h");
        // Diamond has NOT rotated yet.
        assertEq(hook.diamond(), address(oldDiamond), "diamond unchanged pre-execute");
    }

    function test_FXX02_ExecuteDiamondRotation_BeforeDelay_Reverts() public {
        address newDiamond = address(new MockDiamond());
        vm.prank(admin);
        hook.proposeDiamond(newDiamond);

        // 1 second before delay elapses.
        vm.warp(block.timestamp + hook.DIAMOND_ROTATION_DELAY() - 1);

        vm.prank(admin);
        vm.expectRevert(IPrediXHook.Hook_DiamondDelayNotElapsed.selector);
        hook.executeDiamondRotation();
    }

    function test_FXX02_ExecuteDiamondRotation_AfterDelay_Success() public {
        address newDiamond = address(new MockDiamond());
        vm.prank(admin);
        hook.proposeDiamond(newDiamond);

        vm.warp(block.timestamp + hook.DIAMOND_ROTATION_DELAY() + 1);

        vm.expectEmit(true, true, true, true, address(hook));
        emit IPrediXHook.Hook_DiamondUpdated(address(oldDiamond), newDiamond);

        vm.prank(admin);
        hook.executeDiamondRotation();

        assertEq(hook.diamond(), newDiamond, "diamond rotated");
        (address pending, uint256 readyAt) = hook.pendingDiamond();
        assertEq(pending, address(0), "pending cleared");
        assertEq(readyAt, 0, "readyAt cleared");
    }

    function test_FXX02_CancelDiamondRotation_ClearsState() public {
        address newDiamond = address(new MockDiamond());
        vm.prank(admin);
        hook.proposeDiamond(newDiamond);

        vm.expectEmit(true, true, true, true, address(hook));
        emit IPrediXHook.Hook_DiamondRotationCancelled(newDiamond);

        vm.prank(admin);
        hook.cancelDiamondRotation();

        (address pending, uint256 readyAt) = hook.pendingDiamond();
        assertEq(pending, address(0), "pending cleared");
        assertEq(readyAt, 0, "readyAt cleared");

        // Re-propose after cancel — fresh timer anchored to now.
        address anotherDiamond = address(new MockDiamond());
        vm.warp(block.timestamp + 1 hours);
        vm.prank(admin);
        hook.proposeDiamond(anotherDiamond);
        (, uint256 readyAtAfter) = hook.pendingDiamond();
        assertEq(readyAtAfter, block.timestamp + hook.DIAMOND_ROTATION_DELAY(), "timer resets on new propose");
    }

    function test_FXX02_OnlyAdmin_CanPropose() public {
        address newDiamond = address(new MockDiamond());
        vm.prank(rando);
        vm.expectRevert(IPrediXHook.Hook_OnlyAdmin.selector);
        hook.proposeDiamond(newDiamond);

        // execute + cancel are also admin-gated — F-X-02 makes execute admin-
        // only (different from executeTrustedRouter which is permissionless)
        // because diamond rotation is even more sensitive than trust rotation.
        vm.prank(rando);
        vm.expectRevert(IPrediXHook.Hook_OnlyAdmin.selector);
        hook.executeDiamondRotation();

        vm.prank(rando);
        vm.expectRevert(IPrediXHook.Hook_OnlyAdmin.selector);
        hook.cancelDiamondRotation();
    }

    function test_FXX02_ZeroAddress_Reverts() public {
        vm.prank(admin);
        vm.expectRevert(IPrediXHook.Hook_ZeroAddress.selector);
        hook.proposeDiamond(address(0));
    }

    function test_FXX02_NoPendingDiamond_ExecuteReverts() public {
        vm.prank(admin);
        vm.expectRevert(IPrediXHook.Hook_NoPendingDiamondChange.selector);
        hook.executeDiamondRotation();

        vm.prank(admin);
        vm.expectRevert(IPrediXHook.Hook_NoPendingDiamondChange.selector);
        hook.cancelDiamondRotation();
    }

    function test_FXX02_PostRotation_BindingsCleared_ViaUnregisterFlow() public {
        // H-01 audit fix locked in: stale `_poolBinding` / `_marketToPoolId`
        // are NOT cleared by `executeDiamondRotation` itself. The supported
        // recovery is the `proposeUnregisterMarketPool` →
        // `executeUnregisterMarketPool` 48h timelock flow (covered end-to-end
        // by `H01_UnregisterMarketPool.test_H01_Execute_ClearsBindings_AllowsReRegister`).
        //
        // This test only asserts the immediate-post-rotation state — bindings
        // still present, ready to be cleared via the unregister flow if the
        // new diamond is incompatible with the old marketId map.
        uint256 marketId = 1;
        address yesLow = address(0x10000 - 1);
        address noToken = makeAddr("no");
        oldDiamond.setMarket(marketId, yesLow, noToken, block.timestamp + 30 days, false, false);

        PoolKey memory poolKey = PoolKey({
            currency0: Currency.wrap(yesLow),
            currency1: Currency.wrap(usdc),
            fee: 0x800000,
            tickSpacing: 60,
            hooks: hook
        });
        PoolId poolId = poolKey.toId();
        hook.registerMarketPool(marketId, poolKey);

        address newDiamond = address(new MockDiamond());
        vm.prank(admin);
        hook.proposeDiamond(newDiamond);
        vm.warp(block.timestamp + hook.DIAMOND_ROTATION_DELAY() + 1);
        vm.prank(admin);
        hook.executeDiamondRotation();

        // Immediate post-rotation: binding still in place. Recovery requires
        // the unregister flow.
        assertEq(hook.poolMarketId(poolId), marketId, "binding present immediately after rotation");
    }
}
