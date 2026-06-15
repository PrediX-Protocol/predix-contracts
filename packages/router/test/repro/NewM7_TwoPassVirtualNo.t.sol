// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import {IPrediXExchangeView} from "@predix/router/interfaces/IPrediXExchangeView.sol";
import {IPrediXRouter} from "@predix/router/interfaces/IPrediXRouter.sol";

import {RouterFixture} from "../utils/RouterFixture.sol";

/// @notice Repro for NEW-M7 / FINAL-M14 — `_computeBuyNoMintAmount` runs
///         iterative quoter-bounded sizing so thin-liquidity pools no longer
///         false-revert with `QuoteOutsideSafetyMargin`. Pre-fix the linear
///         extrapolation from spot could target a size the pool cannot
///         absorb; post-fix the iteration observes actual impact at every
///         step and converges to the maximum feasible target.
///
///         The iterative variant (Path D) supersedes the original two-pass
///         design. Each iteration uses one `quoteExactInputSingle` call,
///         bounded by `BUY_NO_SIZING_MAX_ITER`. The precision cushion drops
///         to 0.5% (`BUY_NO_PRECISION_CUSHION_BPS`) because the iteration
///         already eliminates the algebraic gap that the historical 1%
///         cushion was masking — the smaller cushion lets NO traders keep
///         more of every trade while still absorbing quoter-vs-actual
///         precision drift.
contract NewM7_TwoPassVirtualNo is RouterFixture {
    function _approveUsdcAsAlice(uint256 amount) internal {
        vm.prank(alice);
        usdc.approve(address(router), amount);
    }

    /// @dev Queue sell-direction quoter results for one `buyNo` call. Layout:
    ///        [0] `_clobBuyNoLimit` spot probe          (exactAmount = 1e6)
    ///        [1] `_ammSpotPriceForSell` (Pass 1 spot)  (exactAmount = 1e6)
    ///        [2] Path D iter 1 quote                   (exactAmount = est)
    ///        [3] Path D final safety quote             (exactAmount = candidate)
    ///      Single-iter variant: iter 1 already satisfies budget so the loop
    ///      breaks after 1 iteration. Final safety quote confirms feasibility
    ///      at the cushioned size.
    function _queueSellSequence(uint256 clobSpot, uint256 computeSpot, uint256 iter1, uint256 finalSafety) internal {
        bool sellIsZeroForOne = address(yes1) < address(usdc);
        // 5 entries: [clobCap spot probe, clobCap effective at mintEstimate,
        // Pass 1 spot, iter 1, final safety]. For these tests the clobCap
        // effective is at the same nominal target as iter 1 (mintEstimate
        // = usdcIn / (1 - spot) which equals the Pass 1 estimatedTarget),
        // so the two values are identical in no-impact runs.
        uint256[] memory sequence = new uint256[](5);
        sequence[0] = clobSpot;
        sequence[1] = iter1; // clobCap effective at mintEstimate
        sequence[2] = computeSpot;
        sequence[3] = iter1;
        sequence[4] = finalSafety;
        quoter.setExactInSequence(sellIsZeroForOne, sequence);
    }

    /// @dev Two-iteration variant for thin-pool tests where iter 1 sizes
    ///      down and iter 2 at the smaller size confirms convergence. Then
    ///      final safety quote at the cushioned candidate.
    function _queueSellSequenceTwoIter(
        uint256 clobSpot,
        uint256 computeSpot,
        uint256 iter1,
        uint256 iter2,
        uint256 finalSafety
    ) internal {
        bool sellIsZeroForOne = address(yes1) < address(usdc);
        // 6 entries: [clobCap spot probe, clobCap effective, Pass 1 spot,
        // iter 1, iter 2, final safety]. ClobCap effective at mintEstimate
        // sees the same impact curve as iter 1 (same nominal size).
        uint256[] memory sequence = new uint256[](6);
        sequence[0] = clobSpot;
        sequence[1] = iter1; // clobCap effective
        sequence[2] = computeSpot;
        sequence[3] = iter1;
        sequence[4] = iter2;
        sequence[5] = finalSafety;
        quoter.setExactInSequence(sellIsZeroForOne, sequence);
    }

    /// @dev Queue the AMM leg's flash-sell result: router sells `mintAmount`
    ///      YES and receives `proceeds` USDC.
    function _queueFlashSell(uint256 mintAmount, uint256 proceeds) internal {
        if (address(yes1) < address(usdc)) {
            poolManager.queueSwapResult(-int128(uint128(mintAmount)), int128(uint128(proceeds)));
        } else {
            poolManager.queueSwapResult(int128(uint128(proceeds)), -int128(uint128(mintAmount)));
        }
    }

    function test_NewM7_ThinPool_LargeTrade_DoesNotRevert() public {
        // Pool is thin: linear spot says selling 80e6 YES would yield 40e6 USDC
        // (price 0.5) but the iter-1 quote reveals it actually yields only 5e6
        // (concentrated liquidity exhausts past current tick).
        //
        // Path D iter 1: quote(80e6) = 5e6. 5e6 + 40e6 = 45e6 < 80e6 → size = 45e6.
        // Path D iter 2: quote(45e6) = 22.5e6 (better per-unit at smaller size,
        //   simulating concentrated-liquidity concavity). 22.5e6 + 40e6 = 62.5e6
        //   ≥ 45e6 → loop breaks at size = 45e6.
        // mintAmount = 45e6 × 0.995 = 44_775_000.
        uint256 usdcIn = 40e6;
        _queueSellSequenceTwoIter({
            clobSpot: 500_000,
            computeSpot: 500_000,
            iter1: 5_000_000,
            iter2: 22_500_000,
            finalSafety: 22_387_500 // linear at candidate 44.775e6
        });

        uint256 sizedDownTarget = 5_000_000 + usdcIn; // 45e6 (iter 1 → iter 2 confirms)
        uint256 expectedMint = (sizedDownTarget * 9950) / 10_000; // 44_775_000 (cushion 0.5%)
        uint256 proceeds = expectedMint / 2;
        _queueFlashSell(expectedMint, proceeds);

        _approveUsdcAsAlice(usdcIn);
        vm.prank(alice);
        (uint256 noOut,, uint256 ammFilled) = router.buyNo(MARKET_ID, usdcIn, 0, alice, 5, _deadline(), bytes32(0));

        assertEq(noOut, expectedMint, "sized-down mint");
        assertEq(ammFilled, expectedMint, "ammFilled");
    }

    function test_NewM7_DeepPool_SmallTrade_OverMarginMinimized() public {
        // Deep pool: iter 1 quote matches linear extrapolation (no impact).
        // proceeds(80e6) = 40e6 → 40+40=80 ≥ 80 → break in iter 1.
        //
        // Cushion evolution:
        //   pre-NEW-M7:  77_600_000 (3% hedge, blind to actual impact)
        //   post-NEW-M7: 79_200_000 (1% cushion, two-pass quote)
        //   post-Path-D: 79_600_000 (0.5% cushion, iterative quote — algebra
        //                fully closed so cushion's only job is precision drift)
        // Each step gives NO traders more tokens per USDC.
        uint256 usdcIn = 40e6;
        _queueSellSequence({clobSpot: 500_000, computeSpot: 500_000, iter1: 40_000_000, finalSafety: 39_800_000});

        uint256 expectedMint = 79_600_000;
        uint256 proceeds = expectedMint / 2;
        _queueFlashSell(expectedMint, proceeds);

        _approveUsdcAsAlice(usdcIn);
        vm.prank(alice);
        (uint256 noOut,,) = router.buyNo(MARKET_ID, usdcIn, 0, alice, 5, _deadline(), bytes32(0));

        assertEq(noOut, expectedMint, "post-Path-D noOut");
        // Pin monotonic improvement across the historical cushion evolution.
        assertGt(noOut, 77_600_000, "user gets strictly more than pre-NEW-M7 (3% margin)");
        assertGt(noOut, 79_200_000, "user gets strictly more than NEW-M7 (1% margin)");
    }

    function test_NewM7_GasDelta_WithinBudget() public {
        // Path D iteration adds up to MAX_ITER `quoteExactInputSingle`
        // round-trips. Real v4 Quoter costs ~30k gas; mock is cheaper so the
        // ceiling here is looser than production. Budget is 1_100_000 gas for
        // the whole `buyNo` flow (no-impact, 1 iter) — leaves headroom for
        // the additional iter quotes vs the historical two-pass design.
        uint256 usdcIn = 40e6;
        _queueSellSequence({clobSpot: 500_000, computeSpot: 500_000, iter1: 40_000_000, finalSafety: 39_800_000});
        uint256 expectedMint = 79_600_000;
        _queueFlashSell(expectedMint, expectedMint / 2);

        _approveUsdcAsAlice(usdcIn);
        vm.prank(alice);
        uint256 gasBefore = gasleft();
        router.buyNo(MARKET_ID, usdcIn, 0, alice, 5, _deadline(), bytes32(0));
        uint256 gasUsed = gasBefore - gasleft();
        assertLt(gasUsed, 1_100_000, "buyNo gas under 1.1M ceiling");
    }

    function test_NewM7_ZeroLiquidity_Returns0() public {
        // Spot probe returns 0 → pool is empty / uninitialised. Early return
        // preserved — no attempt to re-quote or mint.
        bool sellIsZeroForOne = address(yes1) < address(usdc);
        quoter.setExactInResult(sellIsZeroForOne, 0);
        quoter.setExactInResult(!sellIsZeroForOne, 0);

        _approveUsdcAsAlice(40e6);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(IPrediXRouter.ExactInUnfilled.selector, uint256(40e6)));
        router.buyNo(MARKET_ID, 40e6, 0, alice, 5, _deadline(), bytes32(0));
    }

    function test_NewM7_PriceImpactExceedsBudget_SizeDown() public {
        // Numerical lock-in for the iterative size-down path. usdcIn = 100 USDC,
        // spot 0.5 → Pass 1 estimatedTarget = 200e6.
        //   Iter 1: quote(200e6) = 60e6 (impact). 60+100=160 < 200 → size=160e6.
        //   Iter 2: quote(160e6) = 80e6 (perfect linear at smaller scale,
        //           simulating "deeper" tick range below the iter-1 boundary).
        //           80+100=180 ≥ 160 → loop breaks at size=160e6.
        // mintAmount = 160e6 × 0.995 = 159_200_000 (cushion 0.5%).
        uint256 usdcIn = 100e6;
        _queueSellSequenceTwoIter({
            clobSpot: 500_000,
            computeSpot: 500_000,
            iter1: 60_000_000,
            iter2: 80_000_000,
            finalSafety: 79_600_000 // linear at candidate 159.2e6
        });

        uint256 expectedMint = (160_000_000 * 9950) / 10_000;
        assertEq(expectedMint, 159_200_000, "arithmetic sanity");

        // Flash-sell of 159.2e6 YES at effective 0.5 ≈ 79.6e6 USDC.
        uint256 proceeds = expectedMint / 2;
        _queueFlashSell(expectedMint, proceeds);

        _approveUsdcAsAlice(usdcIn);
        vm.prank(alice);
        (uint256 noOut,,) = router.buyNo(MARKET_ID, usdcIn, 0, alice, 5, _deadline(), bytes32(0));
        assertEq(noOut, expectedMint, "sized-down mintAmount");
    }
}
