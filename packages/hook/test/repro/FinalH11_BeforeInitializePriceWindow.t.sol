// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";

import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {LPFeeLibrary} from "@uniswap/v4-core/src/libraries/LPFeeLibrary.sol";
import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";

import {IPrediXHook} from "../../src/interfaces/IPrediXHook.sol";
import {FeeTiers} from "../../src/constants/FeeTiers.sol";

import {MockDiamond} from "../utils/MockDiamond.sol";
import {TestHookHarness} from "../utils/TestHookHarness.sol";

/// @dev FINAL-H11 repro: `_beforeInitialize` did not bound `sqrtPriceX96`, so any
///      caller — including a front-runner who beat the legitimate deployer to
///      `registerMarketPool` + `PoolManager.initialize` — could lock the pool at
///      an extreme starting price, arbitraging every subsequent LP's first swap.
///      Post-fix, `_beforeInitialize` reverts with `Hook_InitPriceOutOfWindow`
///      whenever the implied YES price sits outside [0.475, 0.525] of `PRICE_UNIT`.
contract FinalH11Test is Test {
    using PoolIdLibrary for PoolKey;

    TestHookHarness internal hook;
    MockDiamond internal diamond;

    address internal constant POOL_MANAGER = address(0xCAFE);
    address internal admin = makeAddr("admin");
    address internal usdc = address(0x10000);
    address internal yesLow = address(0x10000 - 1);
    address internal yesHigh = address(0x10000 + 1);
    address internal noToken = makeAddr("no");

    PoolKey internal keyYes0;
    PoolKey internal keyYes1;

    function setUp() public {
        diamond = new MockDiamond();
        hook = new TestHookHarness(IPoolManager(POOL_MANAGER), address(0xC0FFEE));
        hook.initialize(address(diamond), admin, usdc);
        diamond.setMarket(1, yesLow, noToken, block.timestamp + 30 days, false, false);
        diamond.setMarket(2, yesHigh, noToken, block.timestamp + 30 days, false, false);

        keyYes0 = PoolKey({
            currency0: Currency.wrap(yesLow),
            currency1: Currency.wrap(usdc),
            fee: LPFeeLibrary.DYNAMIC_FEE_FLAG,
            tickSpacing: 60,
            hooks: IHooks(address(hook))
        });
        keyYes1 = PoolKey({
            currency0: Currency.wrap(usdc),
            currency1: Currency.wrap(yesHigh),
            fee: LPFeeLibrary.DYNAMIC_FEE_FLAG,
            tickSpacing: 60,
            hooks: IHooks(address(hook))
        });

        hook.registerMarketPool(1, keyYes0);
        hook.registerMarketPool(2, keyYes1);
    }

    /// @dev Convert a YES price in pip units to a `sqrtPriceX96` given orientation.
    ///      For YES = currency0, price = yesPrice/PRICE_UNIT.
    ///      For YES = currency1, price = PRICE_UNIT/yesPrice.
    function _sqrtPriceFromYes(uint256 yesPricePips, bool yesIsCurrency0) internal pure returns (uint160) {
        // priceX96 = price * 2^96; sqrtPriceX96 = sqrt(priceX96 * 2^96)
        // Straightforward approach: priceNum/priceDen, compute sqrt iteratively.
        uint256 num;
        uint256 den;
        if (yesIsCurrency0) {
            num = yesPricePips;
            den = FeeTiers.PRICE_UNIT;
        } else {
            num = FeeTiers.PRICE_UNIT;
            den = yesPricePips;
        }
        // priceX192 = num/den in Q192
        uint256 priceX192 = FullMath.mulDiv(num, 1 << 192, den);
        return uint160(_sqrt(priceX192));
    }

    function _sqrt(uint256 x) internal pure returns (uint256 y) {
        if (x == 0) return 0;
        uint256 z = (x + 1) / 2;
        y = x;
        while (z < y) {
            y = z;
            z = (x / z + z) / 2;
        }
    }

    function test_BeforeInitialize_Midpoint_YesIs0_Allowed() public view {
        uint160 sqrtPrice = _sqrtPriceFromYes(500_000, true);
        hook.exposed_beforeInitialize(address(0), keyYes0, sqrtPrice);
    }

    function test_BeforeInitialize_Midpoint_YesIs1_Allowed() public view {
        uint160 sqrtPrice = _sqrtPriceFromYes(500_000, false);
        hook.exposed_beforeInitialize(address(0), keyYes1, sqrtPrice);
    }

    function test_BeforeInitialize_LowEdge_Allowed() public view {
        uint160 sqrtPrice = _sqrtPriceFromYes(480_000, true);
        hook.exposed_beforeInitialize(address(0), keyYes0, sqrtPrice);
    }

    function test_BeforeInitialize_HighEdge_Allowed() public view {
        uint160 sqrtPrice = _sqrtPriceFromYes(520_000, true);
        hook.exposed_beforeInitialize(address(0), keyYes0, sqrtPrice);
    }

    function test_Revert_BeforeInitialize_BelowWindow_YesIs0() public {
        // 10% YES price → far below 47.5%
        uint160 sqrtPrice = _sqrtPriceFromYes(100_000, true);
        vm.expectRevert(IPrediXHook.Hook_InitPriceOutOfWindow.selector);
        hook.exposed_beforeInitialize(address(0), keyYes0, sqrtPrice);
    }

    function test_Revert_BeforeInitialize_AboveWindow_YesIs0() public {
        // 90% YES price
        uint160 sqrtPrice = _sqrtPriceFromYes(900_000, true);
        vm.expectRevert(IPrediXHook.Hook_InitPriceOutOfWindow.selector);
        hook.exposed_beforeInitialize(address(0), keyYes0, sqrtPrice);
    }

    function test_Revert_BeforeInitialize_BelowWindow_YesIs1() public {
        uint160 sqrtPrice = _sqrtPriceFromYes(100_000, false);
        vm.expectRevert(IPrediXHook.Hook_InitPriceOutOfWindow.selector);
        hook.exposed_beforeInitialize(address(0), keyYes1, sqrtPrice);
    }

    function test_Revert_BeforeInitialize_AboveWindow_YesIs1() public {
        uint160 sqrtPrice = _sqrtPriceFromYes(900_000, false);
        vm.expectRevert(IPrediXHook.Hook_InitPriceOutOfWindow.selector);
        hook.exposed_beforeInitialize(address(0), keyYes1, sqrtPrice);
    }

    function test_Revert_BeforeInitialize_ZeroSqrtPrice() public {
        // sqrtPriceX96 = 0 implies yesPrice = 0 (yesIs0) or PRICE_UNIT (yesIs1) — both outside.
        vm.expectRevert(IPrediXHook.Hook_InitPriceOutOfWindow.selector);
        hook.exposed_beforeInitialize(address(0), keyYes0, 0);
    }
}
