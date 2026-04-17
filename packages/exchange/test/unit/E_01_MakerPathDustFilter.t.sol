// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {IPrediXExchange} from "../../src/IPrediXExchange.sol";

import {ExchangeTestBase} from "../base/ExchangeTestBase.sol";

/// @notice Repro for E-01: MakerPath `_matchCompAtTick` must skip matches where
///         `fillAmt * makerPrice` floors to 0. Before the fix, the fill executed
///         and transferred tokens on one leg for 0 USDC consideration — silent
///         wealth transfer between parties.
contract E_01_MakerPathDustFilter is ExchangeTestBase {
    /// @dev Setup: Alice posts SELL_YES at 990_000 (max tick) amount=1_000_001.
    ///      Bob fills 1_000_000. Alice is left with residual = 1 share.
    ///      Then Carol places BUY_YES at the same price, amount=1_000_000.
    ///      Phase A would attempt to match Carol ↔ Alice's residual:
    ///         fillAmt = min(1_000_000, 1) = 1
    ///         usdcAmt = (1 * 990_000) / 1e6 = 0 (flooring)
    ///      Pre-fix: match executed; Alice's 1 YES transferred to Carol for 0 USDC.
    ///      Post-fix: dust filter skips; Carol's order rests untouched on book.
    function test_E_01_dustMatchSkippedPreservingLedger() public {
        uint256 price = 990_000;
        uint256 aliceSize = 1_000_001;
        uint256 bobFillSize = 1_000_000;
        uint256 carolSize = 1_000_000;

        _placeSellYes(alice, price, aliceSize);
        _giveUsdc(bob, (bobFillSize * price) / 1e6);
        vm.prank(bob);
        exchange.placeOrder(MARKET_ID, IPrediXExchange.Side.BUY_YES, price, bobFillSize);

        // Alice has exactly 1 share of residual YES locked in the exchange.
        uint256 exchangeYesBefore = _yesBalance(address(exchange));
        uint256 carolYesBefore = _yesBalance(carol);

        _giveUsdc(carol, (carolSize * price) / 1e6);
        vm.prank(carol);
        (bytes32 carolId, uint256 filled) =
            exchange.placeOrder(MARKET_ID, IPrediXExchange.Side.BUY_YES, price, carolSize);

        // Carol's order filled 0 shares (dust match skipped).
        assertEq(filled, 0, "dust match must be skipped");
        assertEq(_yesBalance(carol), carolYesBefore, "carol must NOT receive free tokens");
        assertEq(_yesBalance(address(exchange)), exchangeYesBefore, "exchange YES balance unchanged");

        // Carol's order sits on the book at full size.
        IPrediXExchange.Order memory carolOrder = exchange.getOrder(carolId);
        assertEq(uint256(carolOrder.filled), 0, "carol.filled stays 0");
        assertEq(uint256(carolOrder.amount), carolSize, "carol.amount preserved on book");
        assertFalse(carolOrder.cancelled, "carol order not cancelled");
    }

    function test_E_01_nonDustMatchStillFills() public {
        // Non-dust sanity: a regular-size match at the same price executes.
        uint256 price = 500_000;
        _placeSellYes(alice, price, 100 * ONE_SHARE);
        _giveUsdc(bob, 50 * ONE_SHARE);

        vm.prank(bob);
        (, uint256 filled) = exchange.placeOrder(MARKET_ID, IPrediXExchange.Side.BUY_YES, price, 100 * ONE_SHARE);

        assertEq(filled, 100 * ONE_SHARE, "normal match must fill fully");
        assertEq(_yesBalance(bob), 100 * ONE_SHARE, "bob receives YES");
    }
}
