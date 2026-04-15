// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {IPrediXExchange} from "../../src/IPrediXExchange.sol";

import {ExchangeTestBase} from "../base/ExchangeTestBase.sol";

/// @title PrediXExchangeDustTest
/// @notice Option 4 dust-filter regression tests. Each test constructs a
///         structural dust case and asserts the execute helper self-skips
///         BEFORE any state mutation, preserving the strict
///         `balance == Σ depositLocked` invariant.
///
///         Test 1 reproduces the exact shrunk sequence Foundry captured when
///         the strict invariant failed (3-wei under-collateralization). The
///         remaining tests use sub-tick `amountIn` to force `fillAmt` so
///         small that the per-fill USDC leg floors to zero.
contract PrediXExchangeDustTest is ExchangeTestBase {
    // ============ 1. SELL comp dust (shrunk-sequence replay) ============

    /// @notice Reproduces call 16 of the shrunk invariant failure:
    ///         - Maker A: 1_000_000 BUY_YES @ $0.40 (fully consumed iter 1)
    ///         - Maker B: 44_303_837 BUY_YES @ $0.21 (dust trap for iter 2)
    ///         - Taker: SELL_YES, amountIn = 1_000_003, limit = $0.03
    ///         Iter 2 fillAmt=3 with usdcAmt=0 must be SKIPPED (not executed).
    function test_DustFilter_SellComplementary_SkipsZeroUsdcFill() public {
        _placeBuyYes(alice, 400_000, 1_000_000);
        bytes32 carolId = _placeBuyYes(carol, 210_000, 44_303_837);

        _giveYesNo(bob, 1_000_003);
        // Bob holds 1_000_003 YES (from split) + 1_000_003 NO; before the fill,
        // Exchange holds 0 YES since both makers are on BUY sides (USDC-locked).
        assertEq(_yesBalance(address(exchange)), 0, "precondition: no YES in exchange");

        vm.prank(bob);
        (uint256 filled, uint256 cost) = exchange.fillMarketOrder(
            MARKET_ID, IPrediXExchange.Side.SELL_YES, 30_000, 1_000_003, bob, bob, 0, _deadline()
        );

        // Only iter-1 executed; iter-2 dust fill was skipped.
        assertEq(cost, 1_000_000, "cost == iter-1 fillAmt");
        assertEq(filled, 400_000, "filled == iter-1 usdcAmt");

        // Bob refunded his unused 3 YES.
        assertEq(_yesBalance(bob), 3, "bob refund 3 YES");

        // Alice's order fully consumed; she holds 1_000_000 YES now.
        assertEq(_yesBalance(alice), 1_000_000, "alice received YES from iter 1");

        // Maker carol's order COMPLETELY untouched — not even filled += 3.
        IPrediXExchange.Order memory carolOrd = exchange.getOrder(carolId);
        assertEq(carolOrd.filled, 0, "carol.filled == 0 (not iter-2 executed)");
        uint256 expectedCarolLock = (uint256(44_303_837) * 210_000) / 1_000_000;
        assertEq(uint256(carolOrd.depositLocked), expectedCarolLock, "carol deposit untouched");

        // Exchange holds 0 YES after (pulled 1_000_003, transferred 1_000_000 to alice,
        // refunded 3 to bob, carol skipped entirely). Strict solvency holds.
        assertEq(_yesBalance(address(exchange)), 0, "exchange YES drained to 0");
    }

    // ============ 2. BUY comp dust (sub-tick budget) ============

    /// @notice Taker BUY_YES with 1 wei USDC budget vs a SELL_YES maker @ $0.30.
    ///         `takerCap = 1 * 1e6 / 300_000 = 3 shares`, `fillAmt=3`,
    ///         `usdcAmt = (3 * 300_000) / 1e6 = 0` → filter skips.
    function test_DustFilter_BuyComplementary_SkipsZeroUsdcFill() public {
        bytes32 makerId = _placeSellYes(alice, 300_000, 100 * ONE_SHARE);

        usdc.mint(bob, 1);
        vm.prank(bob);
        usdc.approve(address(exchange), type(uint256).max);

        vm.prank(bob);
        (uint256 filled, uint256 cost) =
            exchange.fillMarketOrder(MARKET_ID, IPrediXExchange.Side.BUY_YES, 990_000, 1, bob, bob, 0, _deadline());

        assertEq(filled, 0, "no shares filled");
        assertEq(cost, 0, "no cost");
        assertEq(_usdcBalance(bob), 1, "full refund");

        IPrediXExchange.Order memory ord = exchange.getOrder(makerId);
        assertEq(ord.filled, 0, "maker untouched");
        assertEq(ord.depositLocked, 100 * ONE_SHARE, "maker deposit untouched");
    }

    // ============ 3. Synthetic MINT dust ============

    /// @notice Taker BUY_YES with 1 wei USDC budget vs a BUY_NO maker @ $0.40.
    ///         Synthetic effective price = $0.60. `takerCap = 1 * 1e6 / 600_000 = 1`,
    ///         `fillAmt = 1`, `makerUsdc = (1 * 400_000) / 1e6 = 0` → filter skips.
    function test_DustFilter_SyntheticMint_SkipsZeroMakerUsdc() public {
        bytes32 makerId = _placeBuyNo(alice, 400_000, 100 * ONE_SHARE);
        uint256 initialMakerLock = (100 * ONE_SHARE * 400_000) / 1e6;

        usdc.mint(bob, 1);
        vm.prank(bob);
        usdc.approve(address(exchange), type(uint256).max);

        vm.prank(bob);
        (uint256 filled, uint256 cost) =
            exchange.fillMarketOrder(MARKET_ID, IPrediXExchange.Side.BUY_YES, 990_000, 1, bob, bob, 0, _deadline());

        assertEq(filled, 0, "no shares");
        assertEq(cost, 0, "no cost");
        assertEq(_usdcBalance(bob), 1, "full refund");

        // Maker untouched (no split, no NO to maker).
        IPrediXExchange.Order memory ord = exchange.getOrder(makerId);
        assertEq(ord.filled, 0, "maker.filled unchanged");
        assertEq(ord.depositLocked, initialMakerLock, "maker lock unchanged");
        assertEq(_noBalance(alice), 0, "alice NO not minted");
    }

    // ============ 4. Synthetic MERGE dust ============

    /// @notice Taker SELL_YES with 1 wei YES vs a SELL_NO maker @ $0.40.
    ///         `fillAmt = 1`, `makerUsdcShare = (1 * 400_000) / 1e6 = 0`
    ///         → filter skips before `mergePositions` is called.
    function test_DustFilter_SyntheticMerge_SkipsZeroMakerShare() public {
        bytes32 makerId = _placeSellNo(alice, 400_000, 100 * ONE_SHARE);

        // Give bob exactly 1 wei of YES.
        usdc.mint(bob, 1);
        vm.startPrank(bob);
        usdc.approve(address(diamond), 1);
        diamond.splitPosition(MARKET_ID, 1);
        IERC20(yesToken).approve(address(exchange), type(uint256).max);
        vm.stopPrank();

        uint256 bobYesBefore = _yesBalance(bob);

        vm.prank(bob);
        (uint256 filled, uint256 cost) =
            exchange.fillMarketOrder(MARKET_ID, IPrediXExchange.Side.SELL_YES, 10_000, 1, bob, bob, 0, _deadline());

        assertEq(filled, 0, "no USDC out");
        assertEq(cost, 0, "no YES in");
        assertEq(_yesBalance(bob), bobYesBefore, "bob YES refunded");

        // Maker untouched — no merge executed.
        IPrediXExchange.Order memory ord = exchange.getOrder(makerId);
        assertEq(ord.filled, 0, "maker.filled unchanged");
        assertEq(ord.depositLocked, 100 * ONE_SHARE, "maker lock unchanged");
    }

    // ============ 5. MakerPath MINT — well-aligned fills still work ============

    /// @notice Positive control: with MIN_ORDER_AMOUNT / PRICE_TICK alignment
    ///         the MakerPath `makerUsdc + takerUsdc >= fillAmt` filter is a
    ///         no-op and phase-B MINT matching proceeds normally. This test
    ///         guards against an over-tightened filter falsely skipping
    ///         legitimate fills.
    function test_DustFilter_MakerPath_WellAlignedMintStillFills() public {
        _placeBuyNo(alice, 400_000, 100 * ONE_SHARE);

        _giveUsdc(bob, 65 * ONE_SHARE);
        vm.prank(bob);
        (bytes32 bobId, uint256 bobFilled) =
            exchange.placeOrder(MARKET_ID, IPrediXExchange.Side.BUY_YES, 650_000, 100 * ONE_SHARE);

        // Standard MINT surplus path still works ($5 → feeRecipient).
        assertEq(bobFilled, 100 * ONE_SHARE, "bob fully filled");
        assertEq(_yesBalance(bob), 100 * ONE_SHARE, "bob YES");
        assertEq(_noBalance(alice), 100 * ONE_SHARE, "alice NO");
        assertEq(_usdcBalance(feeRecipient), 5 * ONE_SHARE, "MINT surplus collected");

        IPrediXExchange.Order memory ord = exchange.getOrder(bobId);
        assertEq(ord.filled, 100 * ONE_SHARE);
    }
}
