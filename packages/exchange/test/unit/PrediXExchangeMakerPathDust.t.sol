// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import {IPrediXExchange} from "../../src/IPrediXExchange.sol";

import {ExchangeTestBase} from "../base/ExchangeTestBase.sol";

/// @title PrediXExchangeMakerPathDust
/// @notice Audit M-04 — `MakerPath` now mirrors `TakerPath` for structural dust:
///         when a maker's remaining capacity is so small that
///         `(amount - filled) * price / 1e6 == 0`, the dust order is
///         force-cleaned (queue removed, residual token swept to
///         `feeRecipient`) instead of being skipped in place. The skip-with-i++
///         behaviour stays for Type B dust where the placer's budget is sub-tick
///         at this price but the maker itself is fine.
contract PrediXExchangeMakerPathDustTest is ExchangeTestBase {
    address internal eve = makeAddr("eve");

    /// @dev Set up a 1-share SELL_YES dust order at Alice's name at the given
    ///      tick price. Carol's "good" liquidity at a higher tick sits behind it.
    function _seedDustHeadSellYes(uint256 dustPrice, uint256 dustAmount, uint256 goodPrice) internal {
        _placeSellYes(alice, dustPrice, 2e6);
        _placeBuyYes(eve, dustPrice, 2e6 - dustAmount);
        // Alice's order now has `dustAmount` shares left.
        _placeSellYes(carol, goodPrice, 10e6);
    }

    /// @notice Type A: maker structurally dust. New placer triggers force-clean.
    function test_MakerPath_TypeA_StructuralDust_ForceCleaned() public {
        uint256 dustPrice = 10_000; // $0.01 — 1 share * price / 1e6 floors to 0
        _seedDustHeadSellYes(dustPrice, 1, 20_000);

        uint256 feeRecipientYesBefore = _yesBalance(feeRecipient);

        _giveUsdc(bob, 100e6);
        vm.prank(bob);
        (, uint256 placerFilled) =
            exchange.placeOrder(MARKET_ID, IPrediXExchange.Side.BUY_YES, 30_000, 1e6, bytes32(0));

        assertGt(placerFilled, 0, "placer reached deeper liquidity past dust");
        assertEq(_yesBalance(feeRecipient) - feeRecipientYesBefore, 1, "1-share dust swept to feeRecipient");
    }

    /// @notice Force-cleaning the dust head clears the bitmap bit at that tick
    ///         if no other order is resting there — confirms queue cleanup, not
    ///         just a filled-but-stuck entry.
    function test_MakerPath_TypeA_ForceClean_ClearsBitmapBitWhenLastInQueue() public {
        uint256 dustPrice = 10_000;
        _placeSellYes(alice, dustPrice, 2e6);
        _placeBuyYes(eve, dustPrice, 2e6 - 1);
        _placeSellYes(carol, 20_000, 10e6);

        // Bitmap bit at the dust tick must currently be set.
        uint256 bitmapBefore = exchange.priceBitmap(MARKET_ID, IPrediXExchange.Side.SELL_YES);
        uint8 dustIdx = uint8(dustPrice / 10_000 - 1);
        assertTrue((bitmapBefore & (uint256(1) << dustIdx)) != 0, "dust bit set before");

        _giveUsdc(bob, 100e6);
        vm.prank(bob);
        exchange.placeOrder(MARKET_ID, IPrediXExchange.Side.BUY_YES, 30_000, 1e6, bytes32(0));

        uint256 bitmapAfter = exchange.priceBitmap(MARKET_ID, IPrediXExchange.Side.SELL_YES);
        assertEq(bitmapAfter & (uint256(1) << dustIdx), 0, "dust bit cleared after force-clean");
    }

    /// @notice Type B: the placer's *remaining* budget is sub-tick at this
    ///         price but the maker has plenty of capacity. The placer breaks
    ///         out of the inner loop WITHOUT force-cleaning the maker.
    ///
    ///         MIN_ORDER_AMOUNT prevents passing a sub-tick `amount` directly,
    ///         so engineer Type B via partial consumption: at price 10_000
    ///         (1%), Bob's BUY_YES amount 1_000_099 first matches Alice's
    ///         full 1_000_000 SELL_YES (fillAmt usdcAmt > 0), leaving Bob's
    ///         `newRemaining = 99`. The next maker at the same tick is Dave
    ///         with 1_000_000 SELL_YES capacity — healthy at his own scale.
    ///         fillAmt = min(99, 1_000_000) = 99; usdcAmt = 99*10_000/1e6 = 0.
    ///         M-04 must break, NOT force-clean Dave.
    function test_MakerPath_TypeB_PlacerSubTick_DoesNotForceCleanMaker() public {
        uint256 makerPrice = 10_000; // $0.01

        _placeSellYes(alice, makerPrice, 1_000_000);
        _placeSellYes(dave, makerPrice, 1_000_000);

        uint256 feeRecipientYesBefore = _yesBalance(feeRecipient);
        uint8 priceIdx = uint8(makerPrice / 10_000 - 1);
        uint256 daveCountBefore = exchange.userOrderCount(MARKET_ID, dave);

        // Bob's amount = 1_000_099 — passes MIN_ORDER_AMOUNT, but after
        // consuming Alice's 1_000_000 it leaves 99 shares of sub-tick budget.
        _giveUsdc(bob, 100e6);
        vm.prank(bob);
        exchange.placeOrder(MARKET_ID, IPrediXExchange.Side.BUY_YES, makerPrice, 1_000_099, bytes32(0));

        // Dave survives intact: bitmap bit still set at his tick AND per-user
        // count unchanged (force-clean would have decremented via
        // `_onMakerFullyFilled`).
        uint256 bitmapAfter = exchange.priceBitmap(MARKET_ID, IPrediXExchange.Side.SELL_YES);
        assertTrue((bitmapAfter & (uint256(1) << priceIdx)) != 0, "dave's tick bit preserved on Type B");
        assertEq(exchange.userOrderCount(MARKET_ID, dave), daveCountBefore, "dave's per-user slot preserved");

        // No residual was swept — only Alice's full match moved tokens, and
        // her order completed cleanly (not dust force-clean).
        assertEq(_yesBalance(feeRecipient), feeRecipientYesBefore, "no sweep on Type B");
    }

    /// @notice Subsequent placer at the same tick must NOT see the previously-
    ///         force-cleaned dust order — proves the queue entry was removed,
    ///         not just marked filled.
    function test_MakerPath_TypeA_DustHeadRemoved_NextPlacerFillsCleanly() public {
        uint256 dustPrice = 10_000;
        _seedDustHeadSellYes(dustPrice, 1, 20_000);

        // Trigger the force-clean.
        _giveUsdc(bob, 100e6);
        vm.prank(bob);
        exchange.placeOrder(MARKET_ID, IPrediXExchange.Side.BUY_YES, 30_000, 1e6, bytes32(0));

        // Now a fresh placer at $0.01 hits an empty queue at that tick. They
        // simply rest as a maker at $0.01 with no dust to skip.
        _giveUsdc(dave, 100e6);
        vm.prank(dave);
        (, uint256 daveFilled) =
            exchange.placeOrder(MARKET_ID, IPrediXExchange.Side.BUY_YES, dustPrice, 1e6, bytes32(0));

        assertEq(daveFilled, 0, "no spurious match against cleaned dust");
    }

}
