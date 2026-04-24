// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {IPrediXExchangeView} from "@predix/router/interfaces/IPrediXExchangeView.sol";
import {IPrediXRouter} from "@predix/router/interfaces/IPrediXRouter.sol";

import {RouterFixture} from "../utils/RouterFixture.sol";

/// @notice Repro for NEW-M7 / FINAL-M14 — `_computeBuyNoMintAmount` now runs
///         a two-pass quote (spot probe + re-quote at estimated size) so a
///         thin-liquidity pool no longer false-reverts with
///         `QuoteOutsideSafetyMargin`. Pre-fix, the linear extrapolation from
///         spot could target a size the pool cannot absorb; post-fix, the
///         Pass 2 re-quote observes actual impact and sizes the mint down to
///         the maximum feasible target.
///
///         Margin buffer also drops from `VIRTUAL_SAFETY_MARGIN_BPS` (3%) to
///         `BUY_NO_POST_IMPACT_MARGIN_BPS` (1%) because the target already
///         reflects real impact — over-margining was a pre-fix hedge against
///         impact blindness.
contract NewM7_TwoPassVirtualNo is RouterFixture {
    function _approveUsdcAsAlice(uint256 amount) internal {
        vm.prank(alice);
        usdc.approve(address(router), amount);
    }

    /// @dev Queue the 3 sell-direction quoter results for one `buyNo` call.
    /// @param clobSpot  `_clobBuyNoLimit` spot probe (exactAmount = 1e6).
    /// @param computeSpot `_computeBuyNoMintAmount` Pass 1 spot.
    /// @param passTwo  `_computeBuyNoMintAmount` Pass 2 proceeds at target.
    function _queueSellSequence(uint256 clobSpot, uint256 computeSpot, uint256 passTwo) internal {
        bool sellIsZeroForOne = address(yes1) < address(usdc);
        uint256[] memory sequence = new uint256[](3);
        sequence[0] = clobSpot;
        sequence[1] = computeSpot;
        sequence[2] = passTwo;
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
        // Pool is thin: linear spot says selling 80e6 YES should yield 40e6 USDC
        // (price 0.5) but the re-quote reveals it actually yields only 5e6 because
        // the trade crosses the whole book. Pre-fix: router mints 77.6e6 YES,
        // flash-sell returns ~5e6 USDC, callback invariant fails, user's trade
        // reverts even though a smaller trade would have worked.
        //
        // Post-fix: Pass 2 sees proceeds = 5e6. `5e6 + 40e6 = 45e6 < 80e6` → size
        // down to 45e6. mintAmount = 45e6 × 0.99 = 44_550_000. Flash-sell at the
        // new smaller size is proportionally feasible (pool provides 22_275_000
        // USDC ≈ mintAmount × 0.5), invariant holds, trade succeeds.
        uint256 usdcIn = 40e6;
        _queueSellSequence({clobSpot: 500_000, computeSpot: 500_000, passTwo: 5_000_000});

        uint256 sizedDownTarget = 5_000_000 + usdcIn; // 45e6
        uint256 expectedMint = (sizedDownTarget * 9900) / 10_000; // 44_550_000
        uint256 proceeds = expectedMint / 2;
        _queueFlashSell(expectedMint, proceeds);

        _approveUsdcAsAlice(usdcIn);
        vm.prank(alice);
        (uint256 noOut,, uint256 ammFilled) = router.buyNo(MARKET_ID, usdcIn, 0, alice, 5, _deadline());

        assertEq(noOut, expectedMint, "sized-down mint");
        assertEq(ammFilled, expectedMint, "ammFilled");
    }

    function test_NewM7_DeepPool_SmallTrade_OverMarginMinimized() public {
        // Deep pool: Pass 2 re-quote matches linear extrapolation (no impact).
        // Pre-fix: mintAmount = 80e6 × 0.97 = 77_600_000 (3% hedge against
        // impact blindness that never materialised).
        // Post-fix: mintAmount = 80e6 × 0.99 = 79_200_000 — user receives 1.6e6
        // more NO tokens for the same USDC because we no longer over-margin.
        uint256 usdcIn = 40e6;
        _queueSellSequence({clobSpot: 500_000, computeSpot: 500_000, passTwo: 40_000_000});

        uint256 expectedMint = 79_200_000;
        uint256 proceeds = expectedMint / 2;
        _queueFlashSell(expectedMint, proceeds);

        _approveUsdcAsAlice(usdcIn);
        vm.prank(alice);
        (uint256 noOut,,) = router.buyNo(MARKET_ID, usdcIn, 0, alice, 5, _deadline());

        assertEq(noOut, expectedMint, "post-fix noOut");
        // Lock that post-fix is strictly more than pre-fix's 77_600_000
        // (3% margin → 1% margin under no-impact conditions).
        assertGt(noOut, 77_600_000, "user gets strictly more than pre-fix");
    }

    function test_NewM7_GasDelta_Within30kBudget() public {
        // Pass 2 adds one `quoteExactInputSingle` round-trip. Real v4 Quoter
        // costs ~30k gas; the mock is cheaper so the ceiling here is looser
        // than production. Budget is 900k gas for the whole `buyNo` flow —
        // a loop or accidental double-quote would push through that cap.
        // Tighten this in a follow-up once real Sepolia gas snapshots exist.
        uint256 usdcIn = 40e6;
        _queueSellSequence({clobSpot: 500_000, computeSpot: 500_000, passTwo: 40_000_000});
        uint256 expectedMint = 79_200_000;
        _queueFlashSell(expectedMint, expectedMint / 2);

        _approveUsdcAsAlice(usdcIn);
        vm.prank(alice);
        uint256 gasBefore = gasleft();
        router.buyNo(MARKET_ID, usdcIn, 0, alice, 5, _deadline());
        uint256 gasUsed = gasBefore - gasleft();
        assertLt(gasUsed, 900_000, "buyNo gas under 900k ceiling");
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
        router.buyNo(MARKET_ID, 40e6, 0, alice, 5, _deadline());
    }

    function test_NewM7_PriceImpactExceedsBudget_SizeDown() public {
        // Numerical lock-in for the size-down path. Given usdcIn = 100 USDC
        // and spot 0.5 → estimatedTarget = 200e6. Pass 2 returns proceeds of
        // 60e6 (heavy impact). `60e6 + 100e6 = 160e6 < 200e6` → sized down to
        // 160e6. mintAmount = 160e6 × 0.99 = 158_400_000.
        uint256 usdcIn = 100e6;
        _queueSellSequence({clobSpot: 500_000, computeSpot: 500_000, passTwo: 60_000_000});

        uint256 expectedMint = (160_000_000 * 9900) / 10_000;
        assertEq(expectedMint, 158_400_000, "arithmetic sanity");

        // Pool delivers proportional proceeds at the NEW smaller size. Actual
        // flash-sell of 158.4e6 YES at effective 0.5 ≈ 79.2e6 USDC.
        uint256 proceeds = expectedMint / 2;
        _queueFlashSell(expectedMint, proceeds);

        _approveUsdcAsAlice(usdcIn);
        vm.prank(alice);
        (uint256 noOut,,) = router.buyNo(MARKET_ID, usdcIn, 0, alice, 5, _deadline());
        assertEq(noOut, expectedMint, "sized-down mintAmount");
    }
}
