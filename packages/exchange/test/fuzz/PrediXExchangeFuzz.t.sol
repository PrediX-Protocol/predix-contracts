// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {IPrediXExchange} from "../../src/IPrediXExchange.sol";

import {ExchangeTestBase} from "../base/ExchangeTestBase.sol";

/// @title PrediXExchangeFuzzTest
/// @notice Stateless fuzz tests over `fillMarketOrder` and `placeOrder`. Verifies
///         the spec invariants `cost ≤ amountIn`, "refund == amountIn - cost",
///         and "preview == fill" hold for arbitrary input bounds.
contract PrediXExchangeFuzzTest is ExchangeTestBase {
    function testFuzz_fillMarketOrder_refundExact(uint256 amountIn, uint256 sellPrice, uint256 sellSize) public {
        amountIn = bound(amountIn, 1e6, 10_000e6);
        sellPrice = bound(sellPrice, 1, 98) * 10_000; // tick-aligned in [10_000, 980_000]
        sellSize = bound(sellSize, 1e6, 1_000e6);

        _placeSellYes(alice, sellPrice, sellSize);
        _giveUsdc(bob, amountIn);

        uint256 before = _usdcBalance(bob);
        vm.prank(bob);
        (uint256 filled, uint256 cost) = exchange.fillMarketOrder(
            MARKET_ID, IPrediXExchange.Side.BUY_YES, 990_000, amountIn, bob, bob, 0, _deadline()
        );

        assertLe(cost, amountIn, "cost <= amountIn");
        assertEq(before - _usdcBalance(bob), cost, "refund exact");
        if (filled > 0) {
            assertGt(cost, 0, "non-zero fill implies non-zero cost");
        }
    }

    function testFuzz_previewMatchesFill_complementary(uint256 amountIn, uint256 sellPrice, uint256 sellSize) public {
        amountIn = bound(amountIn, 1e6, 10_000e6);
        sellPrice = bound(sellPrice, 1, 98) * 10_000;
        sellSize = bound(sellSize, 1e6, 1_000e6);

        _placeSellYes(alice, sellPrice, sellSize);
        _giveUsdc(bob, amountIn);

        (uint256 pf, uint256 pc) =
            exchange.previewFillMarketOrder(MARKET_ID, IPrediXExchange.Side.BUY_YES, 990_000, amountIn, 0);

        vm.prank(bob);
        (uint256 af, uint256 ac) = exchange.fillMarketOrder(
            MARKET_ID, IPrediXExchange.Side.BUY_YES, 990_000, amountIn, bob, bob, 0, _deadline()
        );

        assertEq(pf, af, "filled");
        assertEq(pc, ac, "cost");
    }

    function testFuzz_previewMatchesFill_synthetic(uint256 amountIn, uint256 makerPrice, uint256 makerSize) public {
        amountIn = bound(amountIn, 1e6, 10_000e6);
        makerPrice = bound(makerPrice, 1, 98) * 10_000;
        makerSize = bound(makerSize, 1e6, 1_000e6);

        _placeBuyNo(alice, makerPrice, makerSize);
        _giveUsdc(bob, amountIn);

        (uint256 pf, uint256 pc) =
            exchange.previewFillMarketOrder(MARKET_ID, IPrediXExchange.Side.BUY_YES, 990_000, amountIn, 0);

        vm.prank(bob);
        (uint256 af, uint256 ac) = exchange.fillMarketOrder(
            MARKET_ID, IPrediXExchange.Side.BUY_YES, 990_000, amountIn, bob, bob, 0, _deadline()
        );

        assertEq(pf, af);
        assertEq(pc, ac);
    }

    function testFuzz_placeOrder_depositMatchesPriceAmount(uint256 price, uint256 amount) public {
        price = bound(price, 1, 98) * 10_000;
        amount = bound(amount, 1e6, 1_000_000e6);

        uint256 deposit = (amount * price) / 1e6;
        if (deposit == 0) return; // dust skip — placeOrder reverts InvalidAmount otherwise

        usdc.mint(alice, deposit);
        vm.startPrank(alice);
        usdc.approve(address(exchange), type(uint256).max);
        (bytes32 id,) = exchange.placeOrder(MARKET_ID, IPrediXExchange.Side.BUY_YES, price, amount);
        vm.stopPrank();

        IPrediXExchange.Order memory ord = exchange.getOrder(id);
        assertEq(ord.depositLocked, deposit, "depositLocked == amount * price / 1e6");
    }
}
