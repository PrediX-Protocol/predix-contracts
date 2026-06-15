// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import {IPrediXRouter} from "@predix/router/interfaces/IPrediXRouter.sol";

import {RouterFixture} from "../utils/RouterFixture.sol";

/// @title PathD_StrictCapHole
/// @notice Fix-lock for the residual algebraic gap that the original
///         strict-cap branch left in Path D. In a pool whose price-impact
///         curve is linear (per-unit price degrades by a constant factor
///         with size), the historical
///         `mintAmount = finalProceeds + usdcIn` strict cap produced a
///         `mintAmount` whose actual flash-swap proceeds still left the
///         callback invariant short, re-triggering the
///         `QuoteOutsideSafetyMargin` revert that Path D was designed to
///         close. The current implementation replaces the strict cap with
///         an iterative safety-convergence loop that shrinks `candidate`
///         to a cushioned multiple of the strictly feasible budget on each
///         iteration; the linear-pool fixed point lies strictly below the
///         invariant boundary so the trade succeeds.
contract PathD_StrictCapHole is RouterFixture {
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

    /// @dev Linear-pool repro: per-unit price 0.45 at every size. usdcIn = 40e6,
    ///      spot 0.5. Pass 1 estimatedTarget = 80e6.
    ///
    ///      Phase 1 (main loop) trajectory (size_n+1 = 0.45 × size_n + 40e6):
    ///        iter 1: size 80,    quote 36,    new 76
    ///        iter 2: size 76,    quote 34.2,  new 74.2
    ///        iter 3: size 74.2,  quote 33.39, new 73.39 — MAX_ITER exhausted
    ///
    ///      Phase 2 (safety convergence loop, current implementation):
    ///        candidate_0 = 73.39 × 0.995 = 73_023_050.
    ///        Iter 1: quote(73_023_050) = 32_860_372.
    ///                32_860_372 + 40e6 = 72_860_372 < candidate_0
    ///                → candidate_1 = 72_860_372 × 0.995 = 72_496_070.
    ///        Iter 2: quote(72_496_070) = 32_623_232.
    ///                32_623_232 + 40e6 = 72_623_232 ≥ candidate_1
    ///                → CONVERGED. mintAmount = 72_496_070.
    ///
    ///      Actual flash-swap at mintAmount: 72_496_070 × 0.45 = 32_623_232.
    ///      Budget = 32_623_232 + 40_000_000 = 72_623_232 ≥ mintAmount ✓.
    ///      Trade succeeds — the previously-failing strict-cap path is closed.
    function test_PathD_StrictCap_LinearPool_DoesNotRevert() public {
        uint256 usdcIn = 40e6;
        uint256[] memory seq = new uint256[](8);
        seq[0] = 500_000; // clobCap spot probe
        seq[1] = 36_000_000; // clobCap effective at mintEstimate=80e6 (0.45 linear)
        seq[2] = 500_000; // compute Pass 1 spot
        seq[3] = 36_000_000; // main loop iter 1 at 80e6 (0.45 per-unit)
        seq[4] = 34_200_000; // main loop iter 2 at 76e6
        seq[5] = 33_390_000; // main loop iter 3 at 74.2e6 (MAX_ITER exhausted)
        seq[6] = 32_860_372; // safety loop iter 1 at candidate_0 = 73_023_050
        seq[7] = 32_623_232; // safety loop iter 2 at candidate_1 = 72_496_070 (converges)
        _queueSellSequence(seq);

        uint256 expectedMint = 72_496_070;
        _queueFlashSell(expectedMint, 32_623_232);

        _approveUsdcAsAlice(usdcIn);
        vm.prank(alice);
        (uint256 noOut,,) = router.buyNo(MARKET_ID, usdcIn, 0, alice, 5, _deadline(), bytes32(0));
        assertEq(noOut, expectedMint, "linear-pool strict-cap loop converges + invariant holds");
    }
}
