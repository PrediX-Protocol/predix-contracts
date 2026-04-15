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

    // At spot: 1 USDC → 2 YES, so yesPriceSpot = 0.5, noPriceSpot = 0.5.
    // For usdcIn = 40 USDC, noOutTarget = 40 / 0.5 = 80 → *0.97 margin = 77.6 (77_600_000).
    // To simplify we pick pool results assuming mintAmount and cost align.
    function _stubQuoterForBuyNo() internal {
        // quoteExactInputSingle(1e6 USDC → YES) → returns yesPerUsdcUnit = 2e6 (price 0.5).
        quoter.setExactInResult(2e6);
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
        assertEq(hook.commitCount(), 1);
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

    function test_Revert_BuyNo_InsufficientLiquidity_NoQuote() public {
        // Quoter returns 0 → router can't compute mintAmount → InsufficientLiquidity
        quoter.setExactInResult(0);
        _approveUsdcAsAlice(40e6);
        vm.prank(alice);
        vm.expectRevert(IPrediXRouter.InsufficientLiquidity.selector);
        router.buyNo(MARKET_ID, 40e6, 0, alice, 5, _deadline());
    }
}
