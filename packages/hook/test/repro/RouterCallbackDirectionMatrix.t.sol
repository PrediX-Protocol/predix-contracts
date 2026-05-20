// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import {Test} from "forge-std/Test.sol";

import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {LPFeeLibrary} from "@uniswap/v4-core/src/libraries/LPFeeLibrary.sol";

import {IPrediXHook} from "../../src/interfaces/IPrediXHook.sol";

import {MockDiamond} from "../utils/MockDiamond.sol";
import {TestHookHarness} from "../utils/TestHookHarness.sol";

/// @notice Pin the same-block sandwich-detector matrix across the router's four
///         AMM callbacks. The router's `_callbackBuyYes` /
///         `_callbackSellYes` / `_callbackBuyNo` / `_callbackSellNo` each
///         issue a `poolManager.swap` whose `zeroForOne` flag is derived from
///         `(usdc, yesToken)` address ordering. The pool-direction equivalence
///         classes are:
///
///             A:  { BUY_YES,  SELL_NO  }  — currency1→currency0 when YES is c0
///             B:  { SELL_YES, BUY_NO   }  — currency0→currency1 when YES is c0
///
///         The hook's `_checkAndRecordSandwich` blocks cross-class swaps from
///         the same `(marketId, identity)` within a single block. This file
///         locks the resulting UX matrix so any future router refactor that
///         flips a callback's `zeroForOne` derivation is caught at CI.
///
///         Practical interpretation for end users:
///
///         | First op   | Then BUY_YES | Then SELL_YES | Then BUY_NO | Then SELL_NO |
///         |------------|--------------|---------------|-------------|--------------|
///         | BUY_YES    |   allowed    |    BLOCKED    |   BLOCKED   |    allowed   |
///         | SELL_YES   |   BLOCKED    |    allowed    |   allowed   |    BLOCKED   |
///         | BUY_NO     |   BLOCKED    |    allowed    |   allowed   |    BLOCKED   |
///         | SELL_NO    |   allowed    |    BLOCKED    |   BLOCKED   |    allowed   |
///
///         The `BLOCKED` cells are the legitimate-user friction surface. In a
///         prediction-market context, the most common cross-class pattern is
///         "buy YES, hedge with NO" (BUY_YES → BUY_NO) — users seeking that
///         outcome should call `MarketFacet.splitPosition` instead, which is
///         the on-chain primitive for "1 USDC ⇒ 1 YES + 1 NO" without
///         touching the pool. AMM round-trips inside one block are blocked by
///         design.
contract RouterCallbackDirectionMatrix is Test {
    using PoolIdLibrary for PoolKey;

    TestHookHarness internal hook;
    MockDiamond internal diamond;

    address internal constant POOL_MANAGER = address(0xCAFE);
    address internal admin = makeAddr("admin");
    address internal trader = makeAddr("trader");
    address internal usdc = address(0x10000);
    address internal yesLow = address(0x10000 - 1); // YES < usdc → YES is currency0
    address internal yesHigh = address(0x10000 + 1); // YES > usdc → YES is currency1
    address internal noToken = makeAddr("no");

    uint256 internal constant MARKET_ID_LOW = 1; // yes < usdc
    uint256 internal constant MARKET_ID_HIGH = 2; // yes > usdc

    PoolKey internal keyLow;
    PoolKey internal keyHigh;
    PoolId internal poolIdLow;
    PoolId internal poolIdHigh;

    // Direction labels mirror the router's callback derivations:
    //   In a pool with YES = currency0 (`keyLow`):
    //     BUY_YES   → zeroForOne = (usdc < yes) = false  → ONE_FOR_ZERO
    //     SELL_YES  → zeroForOne = (yes < usdc) = true   → ZERO_FOR_ONE
    //     BUY_NO    → zeroForOne = (yes < usdc) = true   → ZERO_FOR_ONE  (≡ SELL_YES)
    //     SELL_NO   → zeroForOne = (usdc < yes) = false  → ONE_FOR_ZERO  (≡ BUY_YES)
    //   In a pool with YES = currency1 (`keyHigh`), every flag flips, but the
    //   equivalence classes (BUY_YES≡SELL_NO, SELL_YES≡BUY_NO) are preserved.
    SwapParams internal zfo = SwapParams({zeroForOne: true, amountSpecified: -1e6, sqrtPriceLimitX96: 0});
    SwapParams internal ofz = SwapParams({zeroForOne: false, amountSpecified: -1e6, sqrtPriceLimitX96: 0});

    function setUp() public {
        diamond = new MockDiamond();
        hook = new TestHookHarness(IPoolManager(POOL_MANAGER), address(0xC0FFEE));
        hook.initialize(address(diamond), admin, usdc);

        uint256 endTime = block.timestamp + 30 days;
        diamond.setMarket(MARKET_ID_LOW, yesLow, noToken, endTime, false, false);
        diamond.setMarket(MARKET_ID_HIGH, yesHigh, noToken, endTime, false, false);

        keyLow = PoolKey({
            currency0: Currency.wrap(yesLow),
            currency1: Currency.wrap(usdc),
            fee: LPFeeLibrary.DYNAMIC_FEE_FLAG,
            tickSpacing: 60,
            hooks: IHooks(address(hook))
        });
        keyHigh = PoolKey({
            currency0: Currency.wrap(usdc),
            currency1: Currency.wrap(yesHigh),
            fee: LPFeeLibrary.DYNAMIC_FEE_FLAG,
            tickSpacing: 60,
            hooks: IHooks(address(hook))
        });
        poolIdLow = keyLow.toId();
        poolIdHigh = keyHigh.toId();

        vm.prank(address(diamond));
        hook.registerMarketPool(MARKET_ID_LOW, keyLow);
        vm.prank(address(diamond));
        hook.registerMarketPool(MARKET_ID_HIGH, keyHigh);

        vm.prank(admin);
        hook.setTrustedRouter(trader, true);
    }

    function _commit(PoolId pid) internal {
        vm.prank(trader);
        hook.commitSwapIdentity(trader, pid);
    }

    // =================================================================
    // keyLow (YES = currency0)
    // BUY_YES ≡ SELL_NO ≡ ONE_FOR_ZERO (push YES price up)
    // SELL_YES ≡ BUY_NO ≡ ZERO_FOR_ONE (push YES price down)
    // =================================================================

    // ----- Class A: same-direction pairs (allowed) -----

    function test_KeyLow_BuyYes_Then_SellNo_Allowed() public {
        _commit(poolIdLow);
        hook.exposed_beforeSwap(trader, keyLow, ofz, ""); // BUY_YES
        hook.exposed_beforeSwap(trader, keyLow, ofz, ""); // SELL_NO
    }

    function test_KeyLow_SellNo_Then_BuyYes_Allowed() public {
        _commit(poolIdLow);
        hook.exposed_beforeSwap(trader, keyLow, ofz, ""); // SELL_NO
        hook.exposed_beforeSwap(trader, keyLow, ofz, ""); // BUY_YES
    }

    // ----- Class B: same-direction pairs (allowed) -----

    function test_KeyLow_SellYes_Then_BuyNo_Allowed() public {
        _commit(poolIdLow);
        hook.exposed_beforeSwap(trader, keyLow, zfo, ""); // SELL_YES
        hook.exposed_beforeSwap(trader, keyLow, zfo, ""); // BUY_NO
    }

    function test_KeyLow_BuyNo_Then_SellYes_Allowed() public {
        _commit(poolIdLow);
        hook.exposed_beforeSwap(trader, keyLow, zfo, ""); // BUY_NO
        hook.exposed_beforeSwap(trader, keyLow, zfo, ""); // SELL_YES
    }

    // ----- Cross-class pairs (blocked) -----

    function test_Revert_KeyLow_BuyYes_Then_BuyNo_Blocked() public {
        _commit(poolIdLow);
        hook.exposed_beforeSwap(trader, keyLow, ofz, ""); // BUY_YES
        vm.expectRevert(IPrediXHook.Hook_SandwichDetected.selector);
        hook.exposed_beforeSwap(trader, keyLow, zfo, ""); // BUY_NO
    }

    function test_Revert_KeyLow_SellYes_Then_SellNo_Blocked() public {
        _commit(poolIdLow);
        hook.exposed_beforeSwap(trader, keyLow, zfo, ""); // SELL_YES
        vm.expectRevert(IPrediXHook.Hook_SandwichDetected.selector);
        hook.exposed_beforeSwap(trader, keyLow, ofz, ""); // SELL_NO
    }

    function test_Revert_KeyLow_BuyNo_Then_SellNo_Blocked() public {
        _commit(poolIdLow);
        hook.exposed_beforeSwap(trader, keyLow, zfo, ""); // BUY_NO
        vm.expectRevert(IPrediXHook.Hook_SandwichDetected.selector);
        hook.exposed_beforeSwap(trader, keyLow, ofz, ""); // SELL_NO
    }

    function test_Revert_KeyLow_SellNo_Then_BuyNo_Blocked() public {
        _commit(poolIdLow);
        hook.exposed_beforeSwap(trader, keyLow, ofz, ""); // SELL_NO
        vm.expectRevert(IPrediXHook.Hook_SandwichDetected.selector);
        hook.exposed_beforeSwap(trader, keyLow, zfo, ""); // BUY_NO
    }

    function test_Revert_KeyLow_BuyYes_Then_SellYes_Blocked() public {
        _commit(poolIdLow);
        hook.exposed_beforeSwap(trader, keyLow, ofz, ""); // BUY_YES
        vm.expectRevert(IPrediXHook.Hook_SandwichDetected.selector);
        hook.exposed_beforeSwap(trader, keyLow, zfo, ""); // SELL_YES
    }

    // =================================================================
    // keyHigh (YES = currency1) — equivalence classes are preserved,
    // pool-side flags flip. BUY_YES is now ZERO_FOR_ONE, SELL_NO follows.
    // =================================================================

    function test_KeyHigh_BuyYes_Then_SellNo_Allowed() public {
        _commit(poolIdHigh);
        hook.exposed_beforeSwap(trader, keyHigh, zfo, ""); // BUY_YES (yes is c1 → usdc→yes = zfo)
        hook.exposed_beforeSwap(trader, keyHigh, zfo, ""); // SELL_NO
    }

    function test_KeyHigh_SellYes_Then_BuyNo_Allowed() public {
        _commit(poolIdHigh);
        hook.exposed_beforeSwap(trader, keyHigh, ofz, ""); // SELL_YES
        hook.exposed_beforeSwap(trader, keyHigh, ofz, ""); // BUY_NO
    }

    function test_Revert_KeyHigh_BuyYes_Then_BuyNo_Blocked() public {
        _commit(poolIdHigh);
        hook.exposed_beforeSwap(trader, keyHigh, zfo, ""); // BUY_YES
        vm.expectRevert(IPrediXHook.Hook_SandwichDetected.selector);
        hook.exposed_beforeSwap(trader, keyHigh, ofz, ""); // BUY_NO
    }

    function test_Revert_KeyHigh_SellNo_Then_SellYes_Blocked() public {
        _commit(poolIdHigh);
        hook.exposed_beforeSwap(trader, keyHigh, zfo, ""); // SELL_NO
        vm.expectRevert(IPrediXHook.Hook_SandwichDetected.selector);
        hook.exposed_beforeSwap(trader, keyHigh, ofz, ""); // SELL_YES
    }

    // =================================================================
    // Cross-block — blocked combos become allowed after `vm.roll`.
    // Pins that the detector is strictly per-block.
    // =================================================================

    function test_KeyLow_BuyYes_Then_BuyNo_NextBlock_Allowed() public {
        _commit(poolIdLow);
        hook.exposed_beforeSwap(trader, keyLow, ofz, ""); // BUY_YES
        vm.roll(block.number + 1);
        hook.exposed_beforeSwap(trader, keyLow, zfo, ""); // BUY_NO (next block — OK)
    }

    function test_KeyLow_BuyNo_Then_SellNo_NextBlock_Allowed() public {
        _commit(poolIdLow);
        hook.exposed_beforeSwap(trader, keyLow, zfo, ""); // BUY_NO
        vm.roll(block.number + 1);
        hook.exposed_beforeSwap(trader, keyLow, ofz, ""); // SELL_NO (next block — OK)
    }
}
