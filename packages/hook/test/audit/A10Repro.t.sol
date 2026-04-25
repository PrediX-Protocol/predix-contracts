// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";

import {IPrediXHook} from "../../src/interfaces/IPrediXHook.sol";

import {MockDiamond} from "../utils/MockDiamond.sol";
import {TestHookHarness} from "../utils/TestHookHarness.sol";

/// @notice A10 audit repro — `executeDiamondRotation` leaves `_poolBinding`
///         and `_marketToPoolId` populated with stale data from the previous
///         diamond. Because there is no `unregisterPool` / `clearBinding`
///         function, the H1 NatSpec's "ops runbook re-registers markets"
///         instruction is unimplementable: every `registerMarketPool` call
///         post-rotation reverts on the existing binding.
contract A10Repro is Test {
    TestHookHarness internal hook;
    MockDiamond internal oldDiamond;
    MockDiamond internal newDiamond;

    address internal constant POOL_MANAGER = address(0xCAFE);
    address internal admin = makeAddr("admin");
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

        PoolKey memory key = PoolKey({
            currency0: Currency.wrap(yes1),
            currency1: Currency.wrap(usdc),
            fee: 0x800000,
            tickSpacing: int24(60),
            hooks: hook
        });
        hook.registerMarketPool(MARKET_ID, key);
    }

    function test_A10_PostRotationCannotReRegister() public {
        // Rotate from oldDiamond to newDiamond.
        vm.prank(admin);
        hook.proposeDiamond(address(newDiamond));
        vm.warp(block.timestamp + hook.DIAMOND_ROTATION_DELAY() + 1);
        vm.prank(admin);
        hook.executeDiamondRotation();
        assertEq(hook.diamond(), address(newDiamond));

        // Ops wants to "re-register" MARKET_ID under newDiamond. newDiamond
        // has the same market data populated.
        newDiamond.setMarket(MARKET_ID, yes1, noToken, block.timestamp + 30 days, false, false);

        // Same key — fails with PoolAlreadyRegistered (stale _poolBinding).
        PoolKey memory sameKey = PoolKey({
            currency0: Currency.wrap(yes1),
            currency1: Currency.wrap(usdc),
            fee: 0x800000,
            tickSpacing: int24(60),
            hooks: hook
        });
        vm.expectRevert(IPrediXHook.Hook_PoolAlreadyRegistered.selector);
        hook.registerMarketPool(MARKET_ID, sameKey);

        // Try a DIFFERENT pool (different YES) — fails on stale _marketToPoolId.
        address altYes = address(0x10000 - 2);
        newDiamond.setMarket(MARKET_ID, altYes, noToken, block.timestamp + 30 days, false, false);
        PoolKey memory altKey = PoolKey({
            currency0: Currency.wrap(altYes),
            currency1: Currency.wrap(usdc),
            fee: 0x800000,
            tickSpacing: int24(60),
            hooks: hook
        });
        vm.expectRevert(IPrediXHook.Hook_MarketAlreadyHasPool.selector);
        hook.registerMarketPool(MARKET_ID, altKey);

        // No public function exists to clear `_poolBinding[poolId]` or
        // `_marketToPoolId[MARKET_ID]`. Confirmed permanent state lock.
    }
}
