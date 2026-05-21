// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import {IPrediXExchangeView} from "@predix/router/interfaces/IPrediXExchangeView.sol";
import {IPrediXRouter} from "@predix/router/interfaces/IPrediXRouter.sol";

import {RouterFixture} from "../utils/RouterFixture.sol";

/// @title PathD_BuyNoIterativeSizing
/// @notice Algebraic fix-lock for Path D in `_computeBuyNoMintAmount`. The
///         historical 2-pass design quoted at the Pass-1 estimate `X` and
///         cushioned to `0.99R` where `R < X`, leaving an algebraic gap that
///         only real-pool concavity could bridge — and that concavity ran
///         out at ~1% of pool TVL, producing the on-chain
///         `QuoteOutsideSafetyMargin` reverts observed in staging.
///
///         Path D closes the gap by iterating: each step quotes at the
///         current candidate size and shrinks the size until
///         `proceeds + usdcIn >= size`. Once converged, the quote was at
///         the EXACT swap size — the budget invariant is guaranteed by
///         construction (modulo quoter-vs-actual EVM precision drift,
///         absorbed by the 0.5% cushion).
///
///         These tests pin the iterative behaviour numerically across the
///         three canonical pool curves: deep (1 iter), thin (2 iter), and
///         heavily skewed (size-down converges within MAX_ITER).
contract PathD_BuyNoIterativeSizing is RouterFixture {
    function _approveUsdcAsAlice(uint256 amount) internal {
        vm.prank(alice);
        usdc.approve(address(router), amount);
    }

    function _queueSellSequence(uint256[] memory amounts) internal {
        bool sellIsZeroForOne = address(yes1) < address(usdc);
        quoter.setExactInSequence(sellIsZeroForOne, amounts);
    }

    function _queueFlashSell(uint256 mintAmount, uint256 proceeds) internal {
        if (address(yes1) < address(usdc)) {
            poolManager.queueSwapResult(-int128(uint128(mintAmount)), int128(uint128(proceeds)));
        } else {
            poolManager.queueSwapResult(int128(uint128(proceeds)), -int128(uint128(mintAmount)));
        }
    }

    // ====================================================================
    // Convergence behaviour across pool curves
    // ====================================================================

    /// @dev Deep pool (linear, no impact): Path D converges in iter 1.
    ///      proceeds(80e6) = 40e6 = 80e6 × 0.5. `40 + 40 = 80 >= 80` → break.
    ///      Final safety quote at candidate = 79.6e6 also returns linear
    ///      (39.8e6); 39.8 + 40 = 79.8 ≥ 79.6 → mintAmount = candidate.
    ///      Total quoter calls: clobSpot + computeSpot + iter1 + finalSafety = 4.
    function test_PathD_DeepPool_ConvergesInOneIter() public {
        uint256 usdcIn = 40e6;
        uint256[] memory seq = new uint256[](5);
        seq[0] = 500_000; // clobCap spot probe
        seq[1] = 40_000_000; // clobCap effective at mintEstimate=80e6 (linear)
        seq[2] = 500_000; // Pass 1 spot
        seq[3] = 40_000_000; // iter 1 at 80e6
        seq[4] = 39_800_000; // final safety at 79.6e6 (linear)
        _queueSellSequence(seq);

        uint256 expectedMint = (80_000_000 * 9950) / 10_000; // 79_600_000
        _queueFlashSell(expectedMint, expectedMint / 2);

        _approveUsdcAsAlice(usdcIn);
        vm.prank(alice);
        (uint256 noOut,,) = router.buyNo(MARKET_ID, usdcIn, 0, alice, 5, _deadline());
        assertEq(noOut, expectedMint, "iter-1 convergence + safety pass");
    }

    /// @dev Heavy-impact pool: iter 1 quote returns far less than linear,
    ///      iter 2 at the shrunk size sees better per-unit price (concavity
    ///      bonus) and converges.
    function test_PathD_ThinPool_ConvergesInTwoIters() public {
        // usdcIn = 40e6, spot 0.5 → Pass 1 estimatedTarget = 80e6.
        // Iter 1: quote(80e6) = 5e6 (heavy impact). size_new = 45e6.
        // Iter 2: quote(45e6) = 22.5e6 (linear at 45e6 — `22.5 + 40 = 62.5 >= 45`).
        // Final safety quote at candidate = 44.775e6: returns 22.3875e6
        // (linear at smaller-still size). 22.3875 + 40 = 62.3875 ≥ 44.775 → pass.
        uint256 usdcIn = 40e6;
        uint256[] memory seq = new uint256[](6);
        seq[0] = 500_000; // clobCap spot probe
        seq[1] = 5_000_000; // clobCap effective at mintEstimate=80e6 (thin pool)
        seq[2] = 500_000; // Pass 1 spot
        seq[3] = 5_000_000; // iter 1 at 80e6
        seq[4] = 22_500_000; // iter 2 at 45e6
        seq[5] = 22_387_500; // final safety at 44.775e6
        _queueSellSequence(seq);

        uint256 expectedMint = (45_000_000 * 9950) / 10_000; // 44_775_000
        _queueFlashSell(expectedMint, expectedMint / 2);

        _approveUsdcAsAlice(usdcIn);
        vm.prank(alice);
        (uint256 noOut,,) = router.buyNo(MARKET_ID, usdcIn, 0, alice, 5, _deadline());
        assertEq(noOut, expectedMint, "iter-2 convergence + safety pass");
    }

    /// @dev Pathological "linear all the way down" pool: each iter returns
    ///      proportional proceeds, so the main loop strictly shrinks at every
    ///      iteration without converging within `BUY_NO_SIZING_MAX_ITER`. The
    ///      safety loop that follows the cushion application then converges
    ///      geometrically toward the cushioned linear-pool fixed point
    ///      `cushion · usdcIn / (1 - cushion · spot)` where the budget
    ///      invariant holds strictly.
    function test_PathD_PathologicalLinear_BoundedByMaxIter() public {
        // Pass 1 estimatedTarget = 80e6 (spot 0.5, usdcIn 40e6).
        // Each quote returns proceeds = 0.45 × size (uniform impact — the
        // worst case for iterative convergence).
        //
        // Main loop trajectory (size_n+1 = 0.45 × size_n + 40e6):
        //   iter 1: size 80,    quote 36,    new 76
        //   iter 2: size 76,    quote 34.2,  new 74.2
        //   iter 3: size 74.2,  quote 33.39, new 73.39 — MAX_ITER exhausted
        //
        // Safety loop (candidate_0 = 73.39 × 0.995 = 73_023_050):
        //   iter 1: quote(73_023_050) = 32_860_372.
        //           32_860_372 + 40e6 = 72_860_372 < 73_023_050
        //           → candidate_1 = 72_860_372 × 0.995 = 72_496_070.
        //   iter 2: quote(72_496_070) = 32_623_232.
        //           32_623_232 + 40e6 = 72_623_232 ≥ 72_496_070
        //           → CONVERGED. mintAmount = 72_496_070.
        //
        // Actual flash-swap at mintAmount = 72_496_070 in the same linear
        // pool yields 0.45 × 72_496_070 = 32_623_232. Budget = 72_623_232 ≥
        // mintAmount ✓. Trade succeeds.
        uint256 usdcIn = 40e6;
        uint256[] memory seq = new uint256[](8);
        seq[0] = 500_000; // clobCap spot probe
        seq[1] = 36_000_000; // clobCap effective at mintEstimate=80e6 (linear 0.45)
        seq[2] = 500_000; // Pass 1 spot
        seq[3] = 36_000_000; // main loop iter 1 at 80e6
        seq[4] = 34_200_000; // main loop iter 2 at 76e6
        seq[5] = 33_390_000; // main loop iter 3 at 74.2e6 (MAX_ITER exhausted)
        seq[6] = 32_860_372; // safety iter 1 at candidate_0 = 73_023_050
        seq[7] = 32_623_232; // safety iter 2 at candidate_1 = 72_496_070 (converges)
        _queueSellSequence(seq);

        uint256 expectedMint = 72_496_070;
        _queueFlashSell(expectedMint, 32_623_232);

        _approveUsdcAsAlice(usdcIn);
        vm.prank(alice);
        (uint256 noOut,,) = router.buyNo(MARKET_ID, usdcIn, 0, alice, 5, _deadline());
        assertEq(noOut, expectedMint, "safety loop converges in linear pool");
    }

    // ====================================================================
    // Hidden-cost / fairness invariants
    // ====================================================================

    /// @dev Verify the hidden cost for BUY_NO trader (vs theoretical max)
    ///      stays at 0.5% under deep-pool conditions.
    function test_PathD_HiddenCost_DeepPool_AtMostHalfPercent() public {
        uint256 usdcIn = 40e6;
        uint256[] memory seq = new uint256[](5);
        seq[0] = 500_000; // clobCap spot probe
        seq[1] = 40_000_000; // clobCap effective at mintEstimate=80e6 (linear)
        seq[2] = 500_000; // Pass 1 spot
        seq[3] = 40_000_000; // iter 1
        seq[4] = 39_800_000; // final safety
        _queueSellSequence(seq);

        uint256 expectedMint = (80_000_000 * 9950) / 10_000;
        _queueFlashSell(expectedMint, expectedMint / 2);

        _approveUsdcAsAlice(usdcIn);
        vm.prank(alice);
        (uint256 noOut,,) = router.buyNo(MARKET_ID, usdcIn, 0, alice, 5, _deadline());

        // Theoretical max (no cushion) = 80e6
        // Actual          = 79.6e6
        // Hidden cost     = 0.4e6 / 80e6 = 0.5%
        uint256 theoreticalMax = 80_000_000;
        uint256 hiddenCostBps = ((theoreticalMax - noOut) * 10_000) / theoreticalMax;
        assertEq(hiddenCostBps, 50, "hidden cost = 0.5% exact (cushion only)");
        assertLe(hiddenCostBps, 50, "hidden cost <= 0.5% (cushion bound)");
    }

    /// @dev Verify monotonic improvement vs pre-fix cushion choices.
    ///      Post-Path-D NO traders MUST receive strictly more NO per USDC
    ///      than under the historical 1% and 3% cushions.
    function test_PathD_StrictlyBetterThan_PreviousCushions() public {
        uint256 usdcIn = 40e6;
        uint256[] memory seq = new uint256[](5);
        seq[0] = 500_000; // clobCap spot probe
        seq[1] = 40_000_000; // clobCap effective at mintEstimate=80e6 (linear)
        seq[2] = 500_000; // Pass 1 spot
        seq[3] = 40_000_000; // iter 1
        seq[4] = 39_800_000; // final safety
        _queueSellSequence(seq);

        uint256 expectedMint = (80_000_000 * 9950) / 10_000;
        _queueFlashSell(expectedMint, expectedMint / 2);

        _approveUsdcAsAlice(usdcIn);
        vm.prank(alice);
        (uint256 noOut,,) = router.buyNo(MARKET_ID, usdcIn, 0, alice, 5, _deadline());

        uint256 preNewM7_3pct = (80_000_000 * 9700) / 10_000; // 77.6M
        uint256 newM7_1pct = (80_000_000 * 9900) / 10_000; // 79.2M
        uint256 pathD_05pct = (80_000_000 * 9950) / 10_000; // 79.6M

        assertGt(noOut, preNewM7_3pct, "PathD > pre-NEW-M7 (3% margin)");
        assertGt(noOut, newM7_1pct, "PathD > NEW-M7 (1% margin)");
        assertEq(noOut, pathD_05pct, "PathD = expected 0.5% cushion");
    }

    /// @dev Stress: reproduce the on-chain $238 cusp behaviour and confirm
    ///      Path D no longer reverts. Pre-fix: $238 reverted
    ///      QuoteOutsideSafetyMargin on the Sepolia market. Post-Path-D:
    ///      the same size succeeds because iter 2 at the shrunk size
    ///      proves feasibility.
    function test_PathD_OnchainReproThreshold_NoReverts() public {
        // Mimic on-chain numbers: spot YES = 0.71, NO = 0.29. usdcIn = 240e6.
        // estimatedTarget = 240e6 / 0.29 ≈ 827.586e6.
        // Iter 1 (heavy impact): quote(827.586e6) returns 561.5e6 (per-unit 0.6786).
        // size_new = 561.5e6 + 240e6 = 801.5e6.
        // Iter 2 at 801.5e6 (concavity bonus, per-unit improves to ~0.70):
        //   quote(801.5e6) = 561.5e6. 561.5 + 240 = 801.5 >= 801.5 → break.
        // Final safety at 797.4925e6 (= 801.5e6 × 0.995): quote returns 558.2e6
        //   (linear scaling from 561.5 × 797.49/801.5). 558.2 + 240 = 798.2 ≥
        //   797.49 → use candidate.
        // mintAmount = 797_492_500.
        uint256 usdcIn = 240e6;
        uint256[] memory seq = new uint256[](6);
        seq[0] = 710_000; // clobCap spot probe (YES sell spot ≈ 0.71)
        seq[1] = 561_500_000; // clobCap effective at mintEstimate=827.586e6 (same impact as iter 1)
        seq[2] = 710_000; // compute Pass 1 spot
        seq[3] = 561_500_000; // iter 1 at 827.586e6 (heavy impact)
        seq[4] = 561_500_000; // iter 2 at 801.5e6 (converges)
        seq[5] = 558_244_750; // final safety at 797.4925e6 (linear at smaller size)
        _queueSellSequence(seq);

        uint256 sizeAfterIter = 801_500_000;
        uint256 expectedMint = (sizeAfterIter * 9950) / 10_000;
        _queueFlashSell(expectedMint, (expectedMint * 70) / 100); // proceeds ~70%

        _approveUsdcAsAlice(usdcIn);
        vm.prank(alice);
        (uint256 noOut,,) = router.buyNo(MARKET_ID, usdcIn, 0, alice, 5, _deadline());
        assertGt(noOut, 0, "$240 trade succeeds post-Path-D");
        assertEq(noOut, expectedMint, "exact expected mint");
    }

    // ====================================================================
    // Edge cases
    // ====================================================================

    /// @dev Zero pool liquidity → Path-D early-exit at Pass 1 spot probe.
    function test_PathD_Edge_ZeroLiquidity_Returns0() public {
        bool sellIsZeroForOne = address(yes1) < address(usdc);
        quoter.setExactInResult(sellIsZeroForOne, 0);
        quoter.setExactInResult(!sellIsZeroForOne, 0);

        _approveUsdcAsAlice(40e6);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(IPrediXRouter.ExactInUnfilled.selector, uint256(40e6)));
        router.buyNo(MARKET_ID, 40e6, 0, alice, 5, _deadline());
    }

    /// @dev Spot at 100% (YES = 1) → effectiveNoPrice = 0 → division by zero
    ///      guard returns 0.
    function test_PathD_Edge_SpotAtUnity_Returns0() public {
        bool sellIsZeroForOne = address(yes1) < address(usdc);
        uint256[] memory seq = new uint256[](2);
        seq[0] = 999_999; // clobBuyNoLimit
        seq[1] = 1_000_000; // _ammSpotPriceForSell at unity → guard triggers
        quoter.setExactInSequence(sellIsZeroForOne, seq);

        _approveUsdcAsAlice(40e6);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(IPrediXRouter.ExactInUnfilled.selector, uint256(40e6)));
        router.buyNo(MARKET_ID, 40e6, 0, alice, 5, _deadline());
    }

    /// @dev Sweep the trade sizes that pre-fix reverted on Sepolia
    ///      ($240, $500, $3000) with the same per-iteration concavity profile.
    ///      Each size shapes its own (iter1, iter2, final) sequence so the
    ///      strict-cap path is exercised under multiple absolute magnitudes,
    ///      not just the original cusp value.
    function test_PathD_OnchainStressSweep_500usd_DoesNotRevert() public {
        // YES sell spot 0.71, NO virtual 0.29. usdcIn = 500e6.
        // estimatedTarget = 500e6 / 0.29 ≈ 1_724_137_931.
        // Iter 1 (heavy impact, simulating 2× scale concavity vs $240):
        //   quote(1_724_137_931) returns 1_124_137_931 (per-unit 0.6520).
        //   size_new = 1_124_137_931 + 500e6 = 1_624_137_931.
        // Iter 2 at 1_624_137_931:
        //   quote returns 1_124_137_931 (linear at slightly smaller scale).
        //   1_124_137_931 + 500e6 = 1_624_137_931 ≥ 1_624_137_931 → break.
        // Final safety at candidate = 1_624_137_931 × 0.995 = 1_616_017_241:
        //   linear scaling 1_124_137_931 × 1_616_017_241 / 1_624_137_931 ≈ 1_118_516_241.
        //   1_118_516_241 + 500e6 = 1_618_516_241 ≥ 1_616_017_241 → use candidate.
        uint256 usdcIn = 500e6;
        uint256[] memory seq = new uint256[](6);
        seq[0] = 710_000; // clobCap spot probe
        seq[1] = 1_124_137_931; // clobCap effective at mintEstimate=1.724e9 (same as iter 1)
        seq[2] = 710_000; // Pass 1 spot
        seq[3] = 1_124_137_931; // iter 1 at 1.724e9
        seq[4] = 1_124_137_931; // iter 2 at 1.624e9 (converges)
        seq[5] = 1_118_516_241; // final safety at 1.616e9 (linear from iter 2)
        _queueSellSequence(seq);

        uint256 sizeAfterIter = 1_624_137_931;
        uint256 expectedMint = (sizeAfterIter * 9950) / 10_000;
        _queueFlashSell(expectedMint, (expectedMint * 70) / 100);

        _approveUsdcAsAlice(usdcIn);
        vm.prank(alice);
        (uint256 noOut,,) = router.buyNo(MARKET_ID, usdcIn, 0, alice, 5, _deadline());
        assertGt(noOut, 0, "$500 trade succeeds post-Path-D");
        assertEq(noOut, expectedMint, "exact expected mint at $500");
    }

    function test_PathD_OnchainStressSweep_3000usd_DoesNotRevert() public {
        // YES sell spot 0.71, NO virtual 0.29. usdcIn = 3000e6.
        // estimatedTarget = 3000e6 / 0.29 ≈ 10_344_827_586.
        // Iter 1: quote returns 6_744_827_586 (per-unit 0.6520, deep-pool impact).
        //   size_new = 6_744_827_586 + 3000e6 = 9_744_827_586.
        // Iter 2 at 9_744_827_586:
        //   quote returns 6_744_827_586 (converges, same magnitude).
        //   6_744_827_586 + 3000e6 = 9_744_827_586 ≥ 9_744_827_586 → break.
        // Final safety at 9_744_827_586 × 0.995 = 9_696_103_448:
        //   linear scaling 6_744_827_586 × 9_696_103_448 / 9_744_827_586 = 6_711_103_448.
        //   6_711_103_448 + 3000e6 = 9_711_103_448 ≥ 9_696_103_448 → use candidate.
        uint256 usdcIn = 3000e6;
        uint256[] memory seq = new uint256[](6);
        seq[0] = 710_000; // clobCap spot probe
        seq[1] = 6_744_827_586; // clobCap effective at mintEstimate (same impact as iter 1)
        seq[2] = 710_000; // Pass 1 spot
        seq[3] = 6_744_827_586; // iter 1
        seq[4] = 6_744_827_586; // iter 2 (converges)
        seq[5] = 6_711_103_448; // final safety at 9.696e9 (linear at smaller)
        _queueSellSequence(seq);

        uint256 sizeAfterIter = 9_744_827_586;
        uint256 expectedMint = (sizeAfterIter * 9950) / 10_000;
        _queueFlashSell(expectedMint, (expectedMint * 70) / 100);

        _approveUsdcAsAlice(usdcIn);
        vm.prank(alice);
        (uint256 noOut,,) = router.buyNo(MARKET_ID, usdcIn, 0, alice, 5, _deadline());
        assertGt(noOut, 0, "$3000 trade succeeds post-Path-D");
        assertEq(noOut, expectedMint, "exact expected mint at $3000");
    }

    /// @dev Iter shrinks under usdcIn → strict-cap path returns mintAmount =
    ///      usdcIn. Flash swap returns proceeds; balance ≥ mintAmount is
    ///      trivially satisfied (proceeds ≥ 0, usdcIn covers mintAmount).
    ///      Path D handles the edge gracefully: trade succeeds with a tiny
    ///      mint instead of reverting.
    function test_PathD_Edge_IterationShrinksToUsdcIn_StillFeasible() public {
        // usdcIn = 1000 (= MIN_TRADE_AMOUNT). spot 0.5.
        // estimatedTarget = 2000. iter 1 quote = 0 (pool empty at 2000).
        //   newSize = 0 + 1000 = 1000. 1000 < 2000 → continue. size = 1000.
        // iter 2 at 1000 = 0 (still empty). newSize = 1000 + 0 = 1000.
        //   newSize >= size → break (saturated).
        // candidate = 1000 × 0.995 = 995.
        // Final safety quote at 995 = 0. 0 + 1000 = 1000 ≥ 995 → use candidate.
        // mintAmount = 995. Flash swap 995 YES gets 0 USDC. Balance = 1000.
        // 1000 ≥ 995 → invariant holds, mint 995 NO succeeds.
        uint256 usdcIn = 1000;
        uint256[] memory seq = new uint256[](6);
        seq[0] = 500_000; // clobCap spot probe
        seq[1] = 0; // clobCap effective at mintEstimate=2000 (empty pool returns 0)
        seq[2] = 500_000; // Pass 1 spot
        seq[3] = 0; // iter 1 returns 0
        seq[4] = 0; // iter 2 returns 0
        seq[5] = 0; // final safety returns 0
        _queueSellSequence(seq);
        _queueFlashSell(995, 0); // flash returns 0 proceeds

        _approveUsdcAsAlice(usdcIn);
        vm.prank(alice);
        (uint256 noOut,,) = router.buyNo(MARKET_ID, usdcIn, 0, alice, 5, _deadline());
        assertEq(noOut, 995, "graceful tiny mint instead of revert");
    }
}
