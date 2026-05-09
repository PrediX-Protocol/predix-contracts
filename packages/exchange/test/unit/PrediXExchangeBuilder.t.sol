// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {IPrediXExchange} from "../../src/IPrediXExchange.sol";
import {ExchangeTestBase} from "../base/ExchangeTestBase.sol";

contract PrediXExchangeBuilder is ExchangeTestBase {
    bytes32 constant BUILDER_A = keccak256("builder-app-a");
    bytes32 constant BUILDER_B = keccak256("builder-app-b");

    function test_placeOrder_WithBuilder() public {
        _giveUsdc(alice, 50 * ONE_SHARE);
        vm.prank(alice);

        vm.expectEmit(false, true, true, true);
        emit IPrediXExchange.OrderPlaced(
            bytes32(0), MARKET_ID, alice, IPrediXExchange.Side.BUY_YES, 500_000, 100 * ONE_SHARE, BUILDER_A
        );

        exchange.placeOrder(MARKET_ID, IPrediXExchange.Side.BUY_YES, 500_000, 100 * ONE_SHARE, BUILDER_A);
    }

    function test_placeOrder_NoBuilder() public {
        _giveUsdc(alice, 50 * ONE_SHARE);
        vm.prank(alice);

        vm.expectEmit(false, true, true, true);
        emit IPrediXExchange.OrderPlaced(
            bytes32(0), MARKET_ID, alice, IPrediXExchange.Side.BUY_YES, 500_000, 100 * ONE_SHARE, bytes32(0)
        );

        (bytes32 orderId,) =
            exchange.placeOrder(MARKET_ID, IPrediXExchange.Side.BUY_YES, 500_000, 100 * ONE_SHARE, bytes32(0));

        // Verify builder stored as zero
        (,,,,,,,,, bytes32 storedBuilder) = exchange.orders(orderId);
        assertEq(storedBuilder, bytes32(0), "no builder");
    }

    function test_fillMarketOrder_BuilderTracking() public {
        // Maker places with BUILDER_A
        _giveUsdc(alice, 50 * ONE_SHARE);
        vm.prank(alice);
        (bytes32 makerId,) =
            exchange.placeOrder(MARKET_ID, IPrediXExchange.Side.BUY_YES, 500_000, 100 * ONE_SHARE, BUILDER_A);

        // Taker fills — sell YES at maker's price, with BUILDER_B
        _giveYesNo(bob, 10 * ONE_SHARE);
        vm.prank(bob);

        vm.expectEmit(true, true, true, true);
        emit IPrediXExchange.OrderMatched(
            makerId,
            bytes32(0),
            MARKET_ID,
            IPrediXExchange.MatchType.COMPLEMENTARY,
            10 * ONE_SHARE,
            500_000,
            BUILDER_A,
            BUILDER_B
        );

        exchange.fillMarketOrder(
            MARKET_ID,
            IPrediXExchange.Side.SELL_YES,
            100_000,
            10 * ONE_SHARE,
            bob,
            bob,
            0,
            _deadline(),
            BUILDER_B
        );
    }
}
