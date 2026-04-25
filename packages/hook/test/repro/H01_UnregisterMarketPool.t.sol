// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";

import {IPrediXHook} from "../../src/interfaces/IPrediXHook.sol";

import {MockDiamond} from "../utils/MockDiamond.sol";
import {TestHookHarness} from "../utils/TestHookHarness.sol";

/// @notice H-01 (audit 2026-04-25) regression — per-market timelocked
///         unregister flow lets ops clear stale `_poolBinding` /
///         `_marketToPoolId` post-diamond-rotation. Without this flow, the
///         H1 NatSpec's "ops runbook re-registers markets" instruction was
///         non-functional: every `registerMarketPool` post-rotation reverted.
///
///         Also covers L-04 audit fix — `proposeDiamond` and
///         `executeDiamondRotation` now reject targets without code, mirroring
///         the existing proxy-side `proposeUpgrade` / `executeUpgrade`
///         defence.
contract H01_UnregisterMarketPool is Test {
    TestHookHarness internal hook;
    MockDiamond internal oldDiamond;
    MockDiamond internal newDiamond;

    address internal constant POOL_MANAGER = address(0xCAFE);
    address internal admin = makeAddr("admin");
    address internal rando = makeAddr("rando");
    address internal usdc = address(0x10000);
    address internal yes1 = address(0x10000 - 1);
    address internal noToken = makeAddr("no");

    uint256 internal constant MARKET_ID = 1;

    function setUp() public {
        oldDiamond = new MockDiamond();
        newDiamond = new MockDiamond();
        hook = new TestHookHarness(IPoolManager(POOL_MANAGER), address(0xC0FFEE));
        hook.initialize(address(oldDiamond), admin, usdc);

        oldDiamond.setMarket(MARKET_ID, yes1, noToken, block.timestamp + 30 days, false, false);
        PoolKey memory key = _canonicalKey(yes1);
        hook.registerMarketPool(MARKET_ID, key);
    }

    function _canonicalKey(address yesToken) internal view returns (PoolKey memory) {
        return PoolKey({
            currency0: Currency.wrap(yesToken),
            currency1: Currency.wrap(usdc),
            fee: 0x800000,
            tickSpacing: int24(60),
            hooks: hook
        });
    }

    function _rotateToNewDiamond() internal {
        vm.prank(admin);
        hook.proposeDiamond(address(newDiamond));
        vm.warp(block.timestamp + hook.DIAMOND_ROTATION_DELAY() + 1);
        vm.prank(admin);
        hook.executeDiamondRotation();
    }

    // ---------- Unregister flow ----------

    function test_H01_Propose_EmitsAndStoresReadyAt() public {
        uint256 expectedReadyAt = block.timestamp + hook.MARKET_UNREGISTER_DELAY();

        vm.expectEmit(true, true, true, true, address(hook));
        emit IPrediXHook.Hook_MarketUnregisterProposed(MARKET_ID, expectedReadyAt);

        vm.prank(admin);
        hook.proposeUnregisterMarketPool(MARKET_ID);

        assertEq(hook.pendingUnregisterMarketPool(MARKET_ID), expectedReadyAt, "readyAt persisted");
    }

    function test_H01_Execute_BeforeDelay_Reverts() public {
        vm.prank(admin);
        hook.proposeUnregisterMarketPool(MARKET_ID);

        vm.warp(block.timestamp + hook.MARKET_UNREGISTER_DELAY() - 1);

        vm.prank(admin);
        vm.expectRevert(IPrediXHook.Hook_UnregisterDelayNotElapsed.selector);
        hook.executeUnregisterMarketPool(MARKET_ID);
    }

    function test_H01_Execute_ClearsBindings_AllowsReRegister() public {
        // Step 1: rotate diamond (legitimate upgrade).
        _rotateToNewDiamond();
        assertEq(hook.diamond(), address(newDiamond));

        // Step 2: ops proposes unregister of the stale binding.
        vm.prank(admin);
        hook.proposeUnregisterMarketPool(MARKET_ID);

        // Step 3: 48h passes; ops executes.
        vm.warp(block.timestamp + hook.MARKET_UNREGISTER_DELAY() + 1);
        PoolKey memory oldKey = _canonicalKey(yes1);

        vm.expectEmit(true, true, true, true, address(hook));
        emit IPrediXHook.Hook_MarketUnregistered(MARKET_ID, oldKey.toId());

        vm.prank(admin);
        hook.executeUnregisterMarketPool(MARKET_ID);

        // Bindings cleared.
        assertEq(hook.poolMarketId(oldKey.toId()), 0, "_poolBinding cleared");
        assertEq(hook.pendingUnregisterMarketPool(MARKET_ID), 0, "pending cleared");

        // Step 4: re-register on the new diamond. Must succeed because both
        // `_poolBinding[poolId]` and `_marketToPoolId[MARKET_ID]` are now zero.
        newDiamond.setMarket(MARKET_ID, yes1, noToken, block.timestamp + 30 days, false, false);
        hook.registerMarketPool(MARKET_ID, oldKey);
        assertEq(hook.poolMarketId(oldKey.toId()), MARKET_ID, "re-registered under new diamond");
    }

    function test_H01_Cancel_ClearsPending_AllowsRePropose() public {
        vm.prank(admin);
        hook.proposeUnregisterMarketPool(MARKET_ID);

        vm.expectEmit(true, true, true, true, address(hook));
        emit IPrediXHook.Hook_MarketUnregisterCancelled(MARKET_ID);

        vm.prank(admin);
        hook.cancelUnregisterMarketPool(MARKET_ID);

        assertEq(hook.pendingUnregisterMarketPool(MARKET_ID), 0, "pending cleared on cancel");

        // Re-propose works after cancel.
        vm.prank(admin);
        hook.proposeUnregisterMarketPool(MARKET_ID);
        assertGt(hook.pendingUnregisterMarketPool(MARKET_ID), 0, "fresh proposal recorded");
    }

    function test_H01_Propose_NonExistentMarket_Reverts() public {
        vm.prank(admin);
        vm.expectRevert(IPrediXHook.Hook_MarketNotFound.selector);
        hook.proposeUnregisterMarketPool(uint256(999));
    }

    function test_H01_Execute_NoPending_Reverts() public {
        vm.prank(admin);
        vm.expectRevert(IPrediXHook.Hook_NoPendingUnregister.selector);
        hook.executeUnregisterMarketPool(MARKET_ID);

        vm.prank(admin);
        vm.expectRevert(IPrediXHook.Hook_NoPendingUnregister.selector);
        hook.cancelUnregisterMarketPool(MARKET_ID);
    }

    function test_H01_OnlyAdmin_OnAllMutators() public {
        vm.prank(rando);
        vm.expectRevert(IPrediXHook.Hook_OnlyAdmin.selector);
        hook.proposeUnregisterMarketPool(MARKET_ID);

        vm.prank(rando);
        vm.expectRevert(IPrediXHook.Hook_OnlyAdmin.selector);
        hook.executeUnregisterMarketPool(MARKET_ID);

        vm.prank(rando);
        vm.expectRevert(IPrediXHook.Hook_OnlyAdmin.selector);
        hook.cancelUnregisterMarketPool(MARKET_ID);
    }

    // ---------- L-04 code-length checks on diamond rotation ----------

    function test_L04_ProposeDiamond_EOATarget_Reverts() public {
        // makeAddr returns an EOA-shaped address with no code.
        address eoaTarget = makeAddr("eoaDiamond");
        assertEq(eoaTarget.code.length, 0);

        vm.prank(admin);
        vm.expectRevert(IPrediXHook.Hook_DiamondNotAContract.selector);
        hook.proposeDiamond(eoaTarget);
    }

    function test_L04_ExecuteDiamondRotation_ReChecksCode() public {
        // Propose a contract; later wipe its code via vm.etch to simulate a
        // selfdestructed-or-equivalent target. Execute must re-validate.
        address target = address(new MockDiamond());

        vm.prank(admin);
        hook.proposeDiamond(target);

        vm.warp(block.timestamp + hook.DIAMOND_ROTATION_DELAY() + 1);

        // Wipe the target's code. (Selfdestruct is deprecated in Cancun, but
        // the principle — code can disappear between propose and execute —
        // remains; this test locks the defensive re-check.)
        vm.etch(target, "");

        vm.prank(admin);
        vm.expectRevert(IPrediXHook.Hook_DiamondNotAContract.selector);
        hook.executeDiamondRotation();
    }
}
