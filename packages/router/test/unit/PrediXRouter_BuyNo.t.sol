// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {RouterFixture} from "../utils/RouterFixture.sol";
import {IPrediXRouter} from "@predix/router/interfaces/IPrediXRouter.sol";
import {IPrediXExchangeView} from "@predix/router/interfaces/IPrediXExchangeView.sol";

contract PrediXRouter_BuyNo is RouterFixture {
    function _approveUsdcAsAlice(uint256 amount) internal {
        vm.prank(alice);
        usdc.approve(address(router), amount);
    }

    // At spot: 1 YES → 0.5 USDC (fee-adjusted sell), so effectiveNoPrice = 0.5.
    // For usdcIn = 40 USDC, noOutTarget = 40 / 0.5 = 80 → *0.97 margin = 77.6 (77_600_000).
    // Router's _computeBuyNoMintAmount probes the SELL direction to match the direction of
    // the flash swap in _callbackBuyNo; the mock fallback `_exactIn` applies to both
    // directions so a single setter suffices.
    function _stubQuoterForBuyNo() internal {
        // quoteExactInputSingle(1e6 YES → USDC) → returns usdcPerYesSell = 500_000.
        quoter.setExactInResult(500_000);
    }

    function test_HappyPath_ClobOnly() public {
        exchange.setResult(MARKET_ID, IPrediXExchangeView.Side.BUY_NO, 200e6, 100e6);
        _approveUsdcAsAlice(100e6);
        vm.prank(alice);
        (uint256 noOut, uint256 clobFilled, uint256 ammFilled) =
            router.buyNo(MARKET_ID, 100e6, 0, alice, 5, _deadline());
        assertEq(noOut, 200e6);
        assertEq(clobFilled, 200e6);
        assertEq(ammFilled, 0);
        assertEq(no1.balanceOf(alice), 1_000_000e6 + 200e6);
    }

    function test_VirtualPath_BuyNo_AmmOnly_Quoter() public {
        // Quoter: yesPriceSpot = 0.5 → noPriceSpot = 0.5, target = 40 / 0.5 = 80e6
        // mintAmount = 80e6 * 0.97 = 77_600_000
        uint256 usdcIn = 40e6;
        _stubQuoterForBuyNo();
        uint256 expectedMint = (((usdcIn * 1e6) / 500_000) * 9700) / 10_000; // 77_600_000

        // Swap: mintAmount YES → USDC at spot 0.5 → yields 38_800_000 USDC
        uint256 proceeds = expectedMint / 2;
        // USDC is currency0 when usdc < yes1 in ascending order. zeroForOne = yes < usdc for sell.
        if (address(yes1) < address(usdc)) {
            poolManager.queueSwapResult(-int128(uint128(expectedMint)), int128(uint128(proceeds)));
        } else {
            poolManager.queueSwapResult(int128(uint128(proceeds)), -int128(uint128(expectedMint)));
        }

        _approveUsdcAsAlice(usdcIn);
        vm.prank(alice);
        (uint256 noOut,, uint256 ammFilled) = router.buyNo(MARKET_ID, usdcIn, 0, alice, 5, _deadline());
        assertEq(noOut, expectedMint);
        assertEq(ammFilled, expectedMint);
        assertEq(no1.balanceOf(alice), 1_000_000e6 + expectedMint);
        assertEq(hook.commitCount(), 3);
    }

    function test_Revert_BuyNo_QuoteOutsideSafetyMargin() public {
        // Quoter: same spot, same mint, but AMM pays only a pittance so router has < mintAmount USDC.
        uint256 usdcIn = 40e6;
        _stubQuoterForBuyNo();
        uint256 expectedMint = (((usdcIn * 1e6) / 500_000) * 9700) / 10_000;
        // proceeds too small (e.g. 1e6) so usdcIn + proceeds < expectedMint
        uint256 proceeds = 1e6;
        if (address(yes1) < address(usdc)) {
            poolManager.queueSwapResult(-int128(uint128(expectedMint)), int128(uint128(proceeds)));
        } else {
            poolManager.queueSwapResult(int128(uint128(proceeds)), -int128(uint128(expectedMint)));
        }
        _approveUsdcAsAlice(usdcIn);
        vm.prank(alice);
        vm.expectRevert(IPrediXRouter.QuoteOutsideSafetyMargin.selector);
        router.buyNo(MARKET_ID, usdcIn, 0, alice, 5, _deadline());
    }

    function test_VirtualPath_BuyNo_RespectsPerTradeCap() public {
        // Cap total collateral at 50e6 — mintAmount 77.6e6 must revert early.
        diamond.setPerMarketCap(MARKET_ID, 50e6);
        uint256 usdcIn = 40e6;
        _stubQuoterForBuyNo();
        _approveUsdcAsAlice(usdcIn);
        vm.prank(alice);
        vm.expectRevert(IPrediXRouter.PerMarketCapExceeded.selector);
        router.buyNo(MARKET_ID, usdcIn, 0, alice, 5, _deadline());
    }

    function test_Revert_BuyNo_ExactInUnfilled_NoQuote() public {
        // Quoter returns 0 → router can't compute mintAmount → AMM leg skipped.
        // With no CLOB fill either, the outer waterfall reports ExactInUnfilled.
        quoter.setExactInResult(0);
        _approveUsdcAsAlice(40e6);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(IPrediXRouter.ExactInUnfilled.selector, 40e6));
        router.buyNo(MARKET_ID, 40e6, 0, alice, 5, _deadline());
    }

    function test_VirtualPath_BuyNo_FeeAsymmetry_Succeeds() public {
        // Regression for on-chain tx 0x42ec90e7…79e02: `_computeBuyNoMintAmount` must probe the
        // SELL direction (YES → USDC) because the callback flash-SELLS YES. The fee skews the
        // two directions differently: buying 1 USDC gets 1.899M YES (yesPrice 0.526 post-fee),
        // selling 1M YES gets 475k USDC (yesPrice 0.475 post-fee). Sizing on the BUY quote
        // would over-estimate `mintAmount` and leak `QuoteOutsideSafetyMargin`.
        //
        // With the fix, sizing uses the SELL quote → mintAmount fits within the
        // (usdcIn + flash-proceeds) budget.
        uint256 usdcIn = 2e6;

        // Directional stubs: BUY returns inflated yesPerUsdc (1.899M YES / 1e6 USDC),
        // SELL returns deflated usdcPerYes (475k USDC / 1e6 YES).
        bool yesIsToken0Sell = address(yes1) < address(usdc);
        quoter.setExactInResult(yesIsToken0Sell, 475_000);
        quoter.setExactInResult(!yesIsToken0Sell, 1_899_872);

        // Sell-direction sizing: usdcPerYesSell=475k → noPrice=525k → target=2e6*1e6/525k≈3.81M
        // → mintAmount = 3.81M * 0.97 ≈ 3.695M.
        uint256 expectedMint = (((usdcIn * 1e6) / (1e6 - 475_000)) * 9700) / 10_000;
        // Flash proceeds at effective sell price 0.475.
        uint256 proceeds = (expectedMint * 475_000) / 1e6;

        if (address(yes1) < address(usdc)) {
            poolManager.queueSwapResult(-int128(uint128(expectedMint)), int128(uint128(proceeds)));
        } else {
            poolManager.queueSwapResult(int128(uint128(proceeds)), -int128(uint128(expectedMint)));
        }

        _approveUsdcAsAlice(usdcIn);
        vm.prank(alice);
        (uint256 noOut,, uint256 ammFilled) = router.buyNo(MARKET_ID, usdcIn, 0, alice, 5, _deadline());

        assertEq(ammFilled, expectedMint, "ammFilled");
        assertEq(noOut, expectedMint, "noOut");
        assertEq(usdc.balanceOf(address(router)), 0, "router usdc zero");
    }

    function test_HappyPath_BuyNo_ClobMostly_AmmDustSkipped() public {
        // CLOB consumes 39 of 40 USDC, delivering 78 NO. Quoter returns 0 on the 1 wei AMM
        // remainder → _executeAmmBuyNo returns 0 instead of reverting. Final fill = CLOB only.
        uint256 usdcIn = 40e6;
        exchange.setResult(MARKET_ID, IPrediXExchangeView.Side.BUY_NO, 78e6, usdcIn - 1);
        quoter.setExactInResult(0);

        _approveUsdcAsAlice(usdcIn);
        vm.prank(alice);
        (uint256 noOut, uint256 clobFilled, uint256 ammFilled) =
            router.buyNo(MARKET_ID, usdcIn, 0, alice, 5, _deadline());

        assertEq(clobFilled, 78e6, "clobFilled");
        assertEq(ammFilled, 0, "ammFilled dust skipped");
        assertEq(noOut, 78e6, "noOut = clob only");
        assertEq(usdc.balanceOf(address(router)), 0, "router usdc zero");
        assertEq(no1.balanceOf(address(router)), 0, "router no zero");
    }
}
