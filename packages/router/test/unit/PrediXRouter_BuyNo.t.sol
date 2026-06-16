// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import {RouterFixture} from "../utils/RouterFixture.sol";
import {IPrediXRouter} from "@predix/router/interfaces/IPrediXRouter.sol";
import {IPrediXExchangeView} from "@predix/router/interfaces/IPrediXExchangeView.sol";

contract PrediXRouter_BuyNo is RouterFixture {
    function _approveUsdcAsAlice(uint256 amount) internal {
        vm.prank(alice);
        usdc.approve(address(router), amount);
    }

    // At spot: 1 YES → 0.5 USDC (fee-adjusted sell). For usdcIn = 40 USDC,
    // effectiveNoPrice = 0.5 → Pass-1 estimatedTarget = 80_000_000. Each
    // `buyNo` call hits the sell-direction quoter 4 times in the no-impact
    // case (Path D iter converges in 1 step + 1 final safety quote):
    //   [0] `_clobBuyNoLimit` spot probe       (exactAmount = 1e6)
    //   [1] `_computeBuyNoMintAmount` Pass 1   (exactAmount = 1e6)
    //   [2] `_computeBuyNoMintAmount` iter 1   (exactAmount = 80e6 YES)
    //   [3] `_computeBuyNoMintAmount` final    (exactAmount = candidate 79.6e6)
    // No-impact pool: iter 1 returns 40e6. Final safety at 79.6e6 returns
    // 39.8e6 (linear). `39.8 + 40 = 79.8 ≥ 79.6` → mintAmount = candidate
    // = 79_600_000 (cushion 0.5%).
    function _stubQuoterForBuyNo() internal {
        bool sellIsZeroForOne = address(yes1) < address(usdc);
        uint256[] memory sequence = new uint256[](5);
        sequence[0] = 500_000; // clobBuyNoLimit spot probe ($1 in)
        sequence[1] = 40_000_000; // clobBuyNoLimit effective at mintEstimate 80e6 (linear)
        sequence[2] = 500_000; // compute Pass 1 spot
        sequence[3] = 40_000_000; // iter 1 at 80e6
        sequence[4] = 39_800_000; // final safety at 79.6e6 (linear)
        quoter.setExactInSequence(sellIsZeroForOne, sequence);
    }

    function test_HappyPath_ClobOnly() public {
        exchange.setResult(MARKET_ID, IPrediXExchangeView.Side.BUY_NO, 200e6, 100e6);
        _approveUsdcAsAlice(100e6);
        vm.prank(alice);
        (uint256 noOut, uint256 clobFilled, uint256 ammFilled) =
            router.buyNo(MARKET_ID, 100e6, 0, alice, 5, _deadline(), bytes32(0));
        assertEq(noOut, 200e6);
        assertEq(clobFilled, 200e6);
        assertEq(ammFilled, 0);
        assertEq(no1.balanceOf(alice), 1_000_000e6 + 200e6);
    }

    /// @notice RTR-1 (clm6.7): the CITED path. An AMM-leg revert inside `_callbackBuyNo` (here forced) must be
    ///         CAUGHT, not bubbled. With no CLOB book the trade then surfaces the graceful `ExactInUnfilled`
    ///         (nothing filled, full refund) instead of propagating the raw AMM revert — which, with a CLOB
    ///         fill present, would have wrongly killed it (the buyYes sibling test proves CLOB survival).
    function test_RTR1_buyNo_ammRevert_caughtNotPropagated() public {
        uint256 usdcIn = 40e6;
        _stubQuoterForBuyNo();
        poolManager.setRevertOnSwap(true); // AMM swap reverts inside the unlock callback

        _approveUsdcAsAlice(usdcIn);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(IPrediXRouter.ExactInUnfilled.selector, usdcIn));
        router.buyNo(MARKET_ID, usdcIn, 0, alice, 5, _deadline(), bytes32(0));
    }

    function test_VirtualPath_BuyNo_AmmOnly_Quoter() public {
        // Quoter: yesPriceSpot = 0.5, iter-1 proceeds = 40e6 (linear at 80e6),
        // final safety at 79.6e6 returns 39.8e6. Post-Path-D mintAmount =
        // 80e6 × 0.995 = 79_600_000.
        uint256 usdcIn = 40e6;
        _stubQuoterForBuyNo();
        uint256 expectedMint = (((usdcIn * 1e6) / 500_000) * 9950) / 10_000; // 79_600_000 (cushion 0.5%)

        // Swap: mintAmount YES → USDC at spot 0.5 → yields expectedMint / 2 USDC.
        uint256 proceeds = expectedMint / 2;
        // USDC is currency0 when usdc < yes1 in ascending order. zeroForOne = yes < usdc for sell.
        if (address(yes1) < address(usdc)) {
            poolManager.queueSwapResult(-int128(uint128(expectedMint)), int128(uint128(proceeds)));
        } else {
            poolManager.queueSwapResult(int128(uint128(proceeds)), -int128(uint128(expectedMint)));
        }

        _approveUsdcAsAlice(usdcIn);
        vm.prank(alice);
        (uint256 noOut,, uint256 ammFilled) = router.buyNo(MARKET_ID, usdcIn, 0, alice, 5, _deadline(), bytes32(0));
        assertEq(noOut, expectedMint);
        assertEq(ammFilled, expectedMint);
        assertEq(no1.balanceOf(alice), 1_000_000e6 + expectedMint);
        // Hook commits post-effective-cap: CLOB cap spot probe + CLOB cap
        // effective + Pass 1 sell spot + iter-1 quote + final safety quote +
        // AMM swap = 6 commits total.
        assertEq(hook.commitCount(), 6);
    }

    function test_Revert_BuyNo_QuoteOutsideSafetyMargin() public {
        // Quoter: same two-pass no-impact stub; the actual AMM flash swap
        // returns only a pittance (1 USDC) so the callback invariant
        // `proceeds + usdcIn >= mintAmount` fails and reverts.
        uint256 usdcIn = 40e6;
        _stubQuoterForBuyNo();
        uint256 expectedMint = (((usdcIn * 1e6) / 500_000) * 9950) / 10_000; // cushion 0.5%
        // proceeds too small (e.g. 1e6) so usdcIn + proceeds < expectedMint
        uint256 proceeds = 1e6;
        if (address(yes1) < address(usdc)) {
            poolManager.queueSwapResult(-int128(uint128(expectedMint)), int128(uint128(proceeds)));
        } else {
            poolManager.queueSwapResult(int128(uint128(proceeds)), -int128(uint128(expectedMint)));
        }
        _approveUsdcAsAlice(usdcIn);
        vm.prank(alice);
        // RTR-1 (clm6.7): the safety-margin breach (QuoteOutsideSafetyMargin in `_callbackBuyNo`) is now CAUGHT
        // inside the AMM leg → ship CLOB-only. With no CLOB book here it surfaces the graceful
        // `ExactInUnfilled(usdcIn)` instead of bubbling the raw AMM revert.
        vm.expectRevert(abi.encodeWithSelector(IPrediXRouter.ExactInUnfilled.selector, usdcIn));
        router.buyNo(MARKET_ID, usdcIn, 0, alice, 5, _deadline(), bytes32(0));
    }

    function test_VirtualPath_BuyNo_RespectsPerTradeCap() public {
        // Cap total collateral at 50e6 — mintAmount 77.6e6 must revert early.
        diamond.setPerMarketCap(MARKET_ID, 50e6);
        uint256 usdcIn = 40e6;
        _stubQuoterForBuyNo();
        _approveUsdcAsAlice(usdcIn);
        vm.prank(alice);
        vm.expectRevert(IPrediXRouter.PerMarketCapExceeded.selector);
        router.buyNo(MARKET_ID, usdcIn, 0, alice, 5, _deadline(), bytes32(0));
    }

    function test_Revert_BuyNo_ExactInUnfilled_NoQuote() public {
        // Quoter returns 0 → router can't compute mintAmount → AMM leg skipped.
        // With no CLOB fill either, the outer waterfall reports ExactInUnfilled.
        quoter.setExactInResult(0);
        _approveUsdcAsAlice(40e6);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(IPrediXRouter.ExactInUnfilled.selector, 40e6));
        router.buyNo(MARKET_ID, 40e6, 0, alice, 5, _deadline(), bytes32(0));
    }

    function test_VirtualPath_BuyNo_FeeAsymmetry_Succeeds() public {
        // Regression for on-chain tx 0x42ec90e7…79e02: `_computeBuyNoMintAmount` must probe the
        // SELL direction (YES → USDC) because the callback flash-SELLS YES. The fee skews the
        // two directions differently: buying 1 USDC gets 1.899M YES (yesPrice 0.526 post-fee),
        // selling 1M YES gets 475k USDC (yesPrice 0.475 post-fee). Sizing on the BUY quote
        // would over-estimate `mintAmount` and leak `QuoteOutsideSafetyMargin`.
        //
        // With the fix, sizing uses the SELL quote → mintAmount fits within the
        // (usdcIn + flash-proceeds) budget. Post-NEW-M7 uses a two-pass probe so
        // the sell direction is stubbed with a sequence instead of a single value.
        uint256 usdcIn = 2e6;

        bool yesIsToken0Sell = address(yes1) < address(usdc);

        // 5 sell-dir quoter calls per buyNo (no-impact case): [clobBuyNoLimit
        // spot probe, clobBuyNoLimit effective at mintEstimate, Pass 1 spot,
        // iter-1 quote, final safety quote]. Spot probes at exactAmount=1e6 →
        // 475_000. Effective at mintEstimate ≈3.81M YES → linear 1_809_524.
        // Iter 1 quote at 3.81M YES → 1_809_524 USDC. Final safety at candidate
        // 3.79M YES → 1_800_476 USDC.
        uint256[] memory sellSequence = new uint256[](5);
        sellSequence[0] = 475_000; // clobBuyNoLimit spot probe
        sellSequence[1] = 1_809_524; // clobBuyNoLimit effective at mintEstimate
        sellSequence[2] = 475_000; // compute Pass 1 spot
        sellSequence[3] = 1_809_524; // iter 1 at 3_809_524
        sellSequence[4] = 1_800_476; // final safety at candidate 3_790_476 (linear)
        quoter.setExactInSequence(yesIsToken0Sell, sellSequence);
        // Buy direction (used by CLOB cap derivation) stays single-shot.
        quoter.setExactInResult(!yesIsToken0Sell, 1_899_872);

        uint256 expectedMint = (((usdcIn * 1e6) / (1e6 - 475_000)) * 9950) / 10_000; // cushion 0.5%
        // Flash proceeds at effective sell price 0.475.
        uint256 proceeds = (expectedMint * 475_000) / 1e6;

        if (address(yes1) < address(usdc)) {
            poolManager.queueSwapResult(-int128(uint128(expectedMint)), int128(uint128(proceeds)));
        } else {
            poolManager.queueSwapResult(int128(uint128(proceeds)), -int128(uint128(expectedMint)));
        }

        _approveUsdcAsAlice(usdcIn);
        vm.prank(alice);
        (uint256 noOut,, uint256 ammFilled) = router.buyNo(MARKET_ID, usdcIn, 0, alice, 5, _deadline(), bytes32(0));

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
            router.buyNo(MARKET_ID, usdcIn, 0, alice, 5, _deadline(), bytes32(0));

        assertEq(clobFilled, 78e6, "clobFilled");
        assertEq(ammFilled, 0, "ammFilled dust skipped");
        assertEq(noOut, 78e6, "noOut = clob only");
        assertEq(usdc.balanceOf(address(router)), 0, "router usdc zero");
        assertEq(no1.balanceOf(address(router)), 0, "router no zero");
    }
}
