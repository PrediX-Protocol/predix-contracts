// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {RouterFixture} from "../utils/RouterFixture.sol";
import {IPrediXExchangeView} from "@predix/router/interfaces/IPrediXExchangeView.sol";

contract PrediXRouter_Fuzz is RouterFixture {
    uint256 private constant MIN_TRADE = 1000;
    uint256 private constant MAX_TRADE = 1_000_000e6;

    function testFuzz_BuyYes_AmountIn_AlwaysRefundsDust(uint256 usdcIn, uint256 clobRate) public {
        usdcIn = bound(usdcIn, MIN_TRADE, MAX_TRADE);
        clobRate = bound(clobRate, 1, 1e7); // 1..10x yes-per-usdc at 1e6 precision
        uint256 yesOut = (usdcIn * clobRate) / 1e6;
        if (yesOut == 0) return;

        exchange.setResult(MARKET_ID, IPrediXExchangeView.Side.BUY_YES, yesOut, usdcIn);

        vm.prank(alice);
        usdc.approve(address(router), usdcIn);
        vm.prank(alice);
        router.buyYes(MARKET_ID, usdcIn, 0, alice, 5, _deadline());

        assertEq(usdc.balanceOf(address(router)), 0, "usdc dust");
        assertEq(yes1.balanceOf(address(router)), 0, "yes dust");
    }

    function testFuzz_SellYes_AmountIn_AlwaysRefundsDust(uint256 yesIn, uint256 clobUsdc) public {
        yesIn = bound(yesIn, MIN_TRADE, MAX_TRADE);
        clobUsdc = bound(clobUsdc, 1, yesIn); // USDC out ≤ shares in (price ≤ 1)

        exchange.setResult(MARKET_ID, IPrediXExchangeView.Side.SELL_YES, clobUsdc, yesIn);

        vm.prank(alice);
        yes1.approve(address(router), yesIn);
        vm.prank(alice);
        router.sellYes(MARKET_ID, yesIn, 0, alice, 5, _deadline());

        assertEq(usdc.balanceOf(address(router)), 0, "usdc dust");
        assertEq(yes1.balanceOf(address(router)), 0, "yes dust");
    }

    function testFuzz_PriceCap_PermissiveFallbackWhenPoolEmpty(uint256 usdcIn) public {
        usdcIn = bound(usdcIn, MIN_TRADE, MAX_TRADE);
        // Quoter unset → `_ammSpotPriceForBuy` returns 0 → router falls back to PRICE_PRECISION
        // as a permissive cap, so the CLOB is free to fill up to $1 when no AMM exists.
        exchange.setResult(MARKET_ID, IPrediXExchangeView.Side.BUY_YES, usdcIn, usdcIn);
        vm.prank(alice);
        usdc.approve(address(router), usdcIn);
        vm.prank(alice);
        router.buyYes(MARKET_ID, usdcIn, 0, alice, 5, _deadline());
        assertEq(exchange.lastLimitPrice(), 1e6, "permissive cap");
    }
}
