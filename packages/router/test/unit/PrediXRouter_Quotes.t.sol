// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import {RouterFixture} from "../utils/RouterFixture.sol";
import {IPrediXExchangeView} from "@predix/router/interfaces/IPrediXExchangeView.sol";
import {Modules} from "@predix/shared/constants/Modules.sol";

contract PrediXRouter_Quotes is RouterFixture {
    function test_QuoteBuyYes_ClobAndAmm() public {
        exchange.setResult(MARKET_ID, IPrediXExchangeView.Side.BUY_YES, 120e6, 60e6);
        quoter.setExactInResult(80e6); // exact-in on remaining 40 USDC → 80 YES
        (uint256 total, uint256 clob, uint256 amm) = router.quoteBuyYes(MARKET_ID, 100e6, 5);
        assertEq(clob, 120e6);
        assertEq(amm, 80e6);
        assertEq(total, 200e6);
    }

    function test_QuoteBuyYes_NotFound_ReturnsZero() public {
        (uint256 total, uint256 clob, uint256 amm) = router.quoteBuyYes(999, 100e6, 5);
        assertEq(total, 0);
        assertEq(clob, 0);
        assertEq(amm, 0);
    }

    function test_QuoteBuyYes_Paused_ReturnsZero() public {
        diamond.setModulePaused(Modules.MARKET, true);
        (uint256 total,,) = router.quoteBuyYes(MARKET_ID, 100e6, 5);
        assertEq(total, 0);
    }

    function test_QuoteBuyYes_Resolved_ReturnsZero() public {
        diamond.setMarket(MARKET_ID, address(yes1), address(no1), block.timestamp + 1 days, true, false);
        (uint256 total,,) = router.quoteBuyYes(MARKET_ID, 100e6, 5);
        assertEq(total, 0);
    }

    function test_QuoteSellYes_ClobAndAmm() public {
        // previewFillMarketOrder returns (filled, cost): filled = output delivered
        // to taker, cost = input consumed. For SELL_YES: filled = USDC out,
        // cost = YES in. Setup reflects real Exchange convention per Views.sol
        // L61-L87; prior test used the inverted order which masked a Router
        // tuple-binding bug caught on-chain 2026-04-20.
        exchange.setResult(MARKET_ID, IPrediXExchangeView.Side.SELL_YES, 60e6, 30e6);
        quoter.setExactInResult(18e6);
        (uint256 total, uint256 clob, uint256 amm) = router.quoteSellYes(MARKET_ID, 100e6, 5);
        assertEq(clob, 60e6);
        assertEq(amm, 18e6);
        assertEq(total, 78e6);
    }

    function test_QuoteSellNo_ClobAndAmm() public {
        // SELL_NO: filled = USDC out, cost = NO in. Coverage for quoteSellNo
        // CLOB+AMM composition under the fixed tuple binding.
        exchange.setResult(MARKET_ID, IPrediXExchangeView.Side.SELL_NO, 40e6, 50e6);
        quoter.setExactOutResult(30e6);
        (uint256 total, uint256 clob, uint256 amm) = router.quoteSellNo(MARKET_ID, 100e6, 5);
        // noIn=100, cost(sharesFilled)=50 → noLeft = 50.
        // maxCost = 30e6 * 10000/9950 ≈ 30_150_754 → amm = 50_000_000 - 30_150_754 = 19_849_246
        // (cushion tightened from 3% to 0.5% — SELL_NO trader keeps more USDC)
        assertEq(clob, 40e6);
        uint256 expectedMax = (uint256(30e6) * 10_000) / 9_950;
        assertEq(amm, 50e6 - expectedMax);
        assertEq(total, clob + amm);
    }

    function test_QuoteBuyNo_AmmOnly() public {
        // 4 sell-dir quoter calls during `quoteBuyNo`: clobBuyNoLimit spot,
        // _ammSpotPriceForSell (Pass 1), Path D iter-1 at 80e6, final
        // safety at candidate 79.6e6. No-impact pool → iter-1 returns 40e6,
        // breaks. Final safety at 79.6e6 returns 39.8e6 (linear). Both
        // satisfy budget → mintAmount = 80e6 × 0.995 = 79.6e6.
        bool sellIsZeroForOne = address(yes1) < address(usdc);
        uint256[] memory sequence = new uint256[](4);
        sequence[0] = 500_000;
        sequence[1] = 500_000;
        sequence[2] = 40_000_000; // iter 1
        sequence[3] = 39_800_000; // final safety
        quoter.setExactInSequence(sellIsZeroForOne, sequence);

        (uint256 total, uint256 clob, uint256 amm) = router.quoteBuyNo(MARKET_ID, 40e6, 5);
        assertEq(clob, 0);
        assertEq(amm, 79_600_000);
        assertEq(total, 79_600_000);
    }

    function test_QuoteSellNo_AmmOnly() public {
        quoter.setExactOutResult(50e6); // cost 50, noIn 100 → usdcOut = 100 - maxCost
        (uint256 total, uint256 clob, uint256 amm) = router.quoteSellNo(MARKET_ID, 100e6, 5);
        assertEq(clob, 0);
        // maxCost = 50e6 * 10000 / 9950 ≈ 50_251_256 → noIn - maxCost ≈ 49_748_744
        // (cushion tightened from 3% to 0.5%)
        uint256 expectedMax = (uint256(50e6) * 10_000) / 9_950;
        assertEq(amm, 100e6 - expectedMax);
        assertEq(total, amm);
    }

    function test_QuoteSellNo_NotFound_ReturnsZero() public {
        (uint256 total,,) = router.quoteSellNo(999, 100e6, 5);
        assertEq(total, 0);
    }
}
