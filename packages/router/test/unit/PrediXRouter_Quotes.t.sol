// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

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
        // Mock: 30 shares filled, delivering 60 USDC (cost field is USDC out on sell paths).
        exchange.setResult(MARKET_ID, IPrediXExchangeView.Side.SELL_YES, 30e6, 60e6);
        quoter.setExactInResult(18e6);
        (uint256 total, uint256 clob, uint256 amm) = router.quoteSellYes(MARKET_ID, 100e6, 5);
        assertEq(clob, 60e6);
        assertEq(amm, 18e6);
        assertEq(total, 78e6);
    }

    function test_QuoteBuyNo_AmmOnly() public {
        // No CLOB, Quoter spot 0.5 → noPriceSpot 0.5 → target 80e6 → mintAmount 77.6e6
        quoter.setExactInResult(2e6); // yesPerUsdcUnit = 2e6 → price 0.5
        (uint256 total, uint256 clob, uint256 amm) = router.quoteBuyNo(MARKET_ID, 40e6, 5);
        assertEq(clob, 0);
        assertEq(amm, 77_600_000);
        assertEq(total, 77_600_000);
    }

    function test_QuoteSellNo_AmmOnly() public {
        quoter.setExactOutResult(50e6); // cost 50, noIn 100 → usdcOut ~ 50 * (BPS/margin) diff
        (uint256 total, uint256 clob, uint256 amm) = router.quoteSellNo(MARKET_ID, 100e6, 5);
        assertEq(clob, 0);
        // maxCost = 50e6 * 10000 / 9700 ≈ 51_546_391 → noIn - maxCost ≈ 48_453_609
        uint256 expectedMax = (uint256(50e6) * 10_000) / 9_700;
        assertEq(amm, 100e6 - expectedMax);
        assertEq(total, amm);
    }

    function test_QuoteSellNo_NotFound_ReturnsZero() public {
        (uint256 total,,) = router.quoteSellNo(999, 100e6, 5);
        assertEq(total, 0);
    }
}
