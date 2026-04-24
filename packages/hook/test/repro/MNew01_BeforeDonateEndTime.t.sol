// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {ModifyLiquidityParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";

import {IPrediXHook} from "../../src/interfaces/IPrediXHook.sol";

import {MockDiamond} from "../utils/MockDiamond.sol";
import {TestHookHarness} from "../utils/TestHookHarness.sol";

/// @notice Repro for M-NEW-01: `_beforeDonate` must reject donates after a
///         market's `endTime`, matching `_beforeAddLiquidity` / `_beforeSwap`.
///         Without this check, a donator could dump value into an expired
///         market's pool with no matching trading path to extract it — a
///         value sink for LPs / no meaningful recipient.
contract MNew01_BeforeDonateEndTime is Test {
    using PoolIdLibrary for PoolKey;

    TestHookHarness internal hook;
    MockDiamond internal diamond;

    address internal constant POOL_MANAGER = address(0xCAFE);
    address internal admin = makeAddr("admin");
    address internal usdc = address(0x10000);
    address internal yesLow = address(0x10000 - 1);
    address internal noToken = makeAddr("no");

    uint256 internal constant MARKET_ID = 1;
    uint256 internal endTime;

    PoolKey internal poolKey;
    PoolId internal poolId;

    function setUp() public {
        diamond = new MockDiamond();
        hook = new TestHookHarness(IPoolManager(POOL_MANAGER), address(0xC0FFEE));
        hook.initialize(address(diamond), admin, usdc);

        endTime = block.timestamp + 30 days;
        diamond.setMarket(MARKET_ID, yesLow, noToken, endTime, false, false);

        poolKey = PoolKey({
            currency0: Currency.wrap(yesLow),
            currency1: Currency.wrap(usdc),
            fee: 0x800000,
            tickSpacing: 60,
            hooks: hook
        });
        poolId = poolKey.toId();
        hook.registerMarketPool(MARKET_ID, poolKey);
    }

    function test_MNew01_DonateAfterEndTime_Reverts() public {
        vm.warp(endTime);

        vm.prank(POOL_MANAGER);
        vm.expectRevert(IPrediXHook.Hook_MarketExpired.selector);
        hook.beforeDonate(address(this), poolKey, 1e6, 0, "");
    }

    function test_MNew01_DonateBeforeEndTime_Success() public {
        vm.warp(endTime - 1);

        vm.prank(POOL_MANAGER);
        bytes4 sel = hook.beforeDonate(address(this), poolKey, 1e6, 0, "");
        assertEq(sel, hook.beforeDonate.selector, "donate within window must succeed");
    }

    function test_MNew01_DonateConsistencyWithAddLiquidity() public {
        vm.warp(endTime);

        vm.prank(POOL_MANAGER);
        vm.expectRevert(IPrediXHook.Hook_MarketExpired.selector);
        hook.beforeDonate(address(this), poolKey, 1e6, 0, "");

        ModifyLiquidityParams memory params =
            ModifyLiquidityParams({tickLower: -60, tickUpper: 60, liquidityDelta: 1e18, salt: bytes32(0)});

        vm.prank(POOL_MANAGER);
        vm.expectRevert(IPrediXHook.Hook_MarketExpired.selector);
        hook.beforeAddLiquidity(address(this), poolKey, params, "");
    }
}
