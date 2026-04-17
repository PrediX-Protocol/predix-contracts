// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {SwapParams, ModifyLiquidityParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";

import {IPrediXHook} from "../../src/interfaces/IPrediXHook.sol";

import {MockDiamond} from "../utils/MockDiamond.sol";
import {TestHookHarness} from "../utils/TestHookHarness.sol";

/// @notice Repro for H-H01: when the diamond enables refund mode on a market,
///         the hook must block swaps, add-liquidity, and donates. LPs still
///         need to `removeLiquidity` so that path stays open.
contract H_H01_HookRefundModeGuard is Test {
    using PoolIdLibrary for PoolKey;

    TestHookHarness internal hook;
    MockDiamond internal diamond;

    address internal constant POOL_MANAGER = address(0xCAFE);
    address internal admin = makeAddr("admin");
    address internal router = makeAddr("router");
    address internal usdc = address(0x10000);
    address internal yesLow = address(0x10000 - 1);
    address internal noToken = makeAddr("no");

    uint256 internal constant MARKET_ID = 1;
    uint256 internal endTime;

    PoolKey internal poolKey;
    PoolId internal poolId;

    function setUp() public {
        diamond = new MockDiamond();
        hook = new TestHookHarness(IPoolManager(POOL_MANAGER));
        hook.initialize(address(diamond), admin, usdc);

        endTime = block.timestamp + 30 days;
        diamond.setMarket(MARKET_ID, yesLow, noToken, endTime, false, false);

        poolKey = PoolKey({
            currency0: Currency.wrap(yesLow),
            currency1: Currency.wrap(usdc),
            fee: 0x800000, // dynamic-fee flag
            tickSpacing: 60,
            hooks: hook
        });
        poolId = poolKey.toId();
        hook.registerMarketPool(MARKET_ID, poolKey);

        vm.prank(admin);
        hook.setTrustedRouter(router, true);
    }

    function test_Revert_H_H01_swapRevertsInRefundMode() public {
        diamond.setMarket(MARKET_ID, yesLow, noToken, endTime, false, true); // refundModeActive=true

        vm.prank(router);
        hook.commitSwapIdentity(address(this), poolId);

        SwapParams memory params = SwapParams({zeroForOne: true, amountSpecified: -1e6, sqrtPriceLimitX96: 0});

        vm.prank(POOL_MANAGER);
        vm.expectRevert(IPrediXHook.Hook_MarketInRefundMode.selector);
        hook.beforeSwap(router, poolKey, params, "");
    }

    function test_Revert_H_H01_addLiquidityRevertsInRefundMode() public {
        diamond.setMarket(MARKET_ID, yesLow, noToken, endTime, false, true);

        ModifyLiquidityParams memory params =
            ModifyLiquidityParams({tickLower: -60, tickUpper: 60, liquidityDelta: 1e18, salt: bytes32(0)});

        vm.prank(POOL_MANAGER);
        vm.expectRevert(IPrediXHook.Hook_MarketInRefundMode.selector);
        hook.beforeAddLiquidity(address(this), poolKey, params, "");
    }

    function test_Revert_H_H01_donateRevertsInRefundMode() public {
        diamond.setMarket(MARKET_ID, yesLow, noToken, endTime, false, true);

        vm.prank(POOL_MANAGER);
        vm.expectRevert(IPrediXHook.Hook_MarketInRefundMode.selector);
        hook.beforeDonate(address(this), poolKey, 1e6, 0, "");
    }

    function test_H_H01_removeLiquidityStillAllowedInRefundMode() public {
        // Exit must remain open for LPs regardless of market state.
        diamond.setMarket(MARKET_ID, yesLow, noToken, endTime, false, true);

        ModifyLiquidityParams memory params =
            ModifyLiquidityParams({tickLower: -60, tickUpper: 60, liquidityDelta: -1e18, salt: bytes32(0)});

        vm.prank(POOL_MANAGER);
        bytes4 sel = hook.beforeRemoveLiquidity(address(this), poolKey, params, "");
        assertEq(sel, hook.beforeRemoveLiquidity.selector, "removeLiquidity must succeed");
    }

    function test_H_H01_activeMarketStillPermitsSwap() public {
        // Sanity: when refundModeActive = false, swap path unaffected.
        vm.prank(router);
        hook.commitSwapIdentity(address(this), poolId);

        SwapParams memory params = SwapParams({zeroForOne: true, amountSpecified: -1e6, sqrtPriceLimitX96: 0});

        vm.prank(POOL_MANAGER);
        (bytes4 sel,,) = hook.beforeSwap(router, poolKey, params, "");
        assertEq(sel, hook.beforeSwap.selector, "active market swap must succeed");
    }
}
