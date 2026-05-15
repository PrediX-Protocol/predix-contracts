// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import {IPrediXExchange} from "../../src/IPrediXExchange.sol";
import {MatchMath} from "../../src/libraries/MatchMath.sol";

import {ExchangeTestBase} from "../base/ExchangeTestBase.sol";

/// @title Audit_N01_SyntheticRoundingFairness
/// @notice Audit N-01 documents the rounding asymmetry between taker and maker
///         on the synthetic (MINT / MERGE) paths: `makerShare = floor(fillAmt *
///         makerPrice / 1e6)` always rounds down, so the fractional remainder
///         is shifted onto the taker. Protocol-level solvency is preserved
///         because `makerShare + takerPortion = fillAmt` by construction, but
///         counterparty fairness drifts by ≤ 1 wei per fill.
///
///         The tests below pin the property explicitly so any future change to
///         the rounding direction is caught immediately, and bound the worst
///         case across the entire price + size domain.
contract Audit_N01_SyntheticRoundingFairnessTest is ExchangeTestBase {
    uint256 internal constant PRICE_PRECISION = 1e6;

    /// @notice Per-fill drift on the synthetic-MINT path never exceeds 1 wei
    ///         USDC. Verified directly against `MatchMath.computeFillDeltas`,
    ///         which is the canonical source of the rounding for every
    ///         taker / maker / preview / merge entry point.
    function testFuzz_N01_MintPerFillDriftBounded(uint128 fillAmt, uint24 makerPriceRaw) public pure {
        uint256 makerPrice = bound(uint256(makerPriceRaw), 10_000, 990_000);
        // Snap to tick to match real maker prices.
        makerPrice = (makerPrice / 10_000) * 10_000;
        if (makerPrice < 10_000) makerPrice = 10_000;

        uint256 amt = bound(uint256(fillAmt), 1, type(uint96).max);

        (uint256 inDelta, uint256 outDelta) =
            MatchMath.computeFillDeltas(makerPrice, amt, /*takerIsBuy*/ true, /*isSynthetic*/ true);

        // Dust shortcut path: both deltas zero. Nothing to verify.
        if (outDelta == 0) return;

        uint256 makerShareExact = (amt * makerPrice) / PRICE_PRECISION; // already floored
        uint256 takerPortion = inDelta;
        assertEq(outDelta, amt, "outDelta == fillAmt for MINT");
        assertEq(takerPortion, amt - makerShareExact, "takerPortion = fillAmt - makerShare");

        // Real-number "exact" taker share = fillAmt * (1e6 - makerPrice) / 1e6.
        // Compare against scaled integer to avoid floats.
        uint256 takerPortionScaled = takerPortion * PRICE_PRECISION;
        uint256 exactScaled = amt * (PRICE_PRECISION - makerPrice);
        // takerPortion ≥ exact (taker over-pays by < 1 wei) AND drift < PRICE_PRECISION.
        assertGe(takerPortionScaled, exactScaled, "taker pays at least the exact share");
        assertLt(takerPortionScaled - exactScaled, PRICE_PRECISION, "drift < 1 wei per fill");
    }

    /// @notice Symmetric property on the synthetic-MERGE path: taker receives
    ///         AT LEAST the exact share back, never less.
    function testFuzz_N01_MergePerFillDriftBounded(uint128 fillAmt, uint24 makerPriceRaw) public pure {
        uint256 makerPrice = bound(uint256(makerPriceRaw), 10_000, 990_000);
        makerPrice = (makerPrice / 10_000) * 10_000;
        if (makerPrice < 10_000) makerPrice = 10_000;
        uint256 amt = bound(uint256(fillAmt), 1, type(uint96).max);

        (uint256 inDelta, uint256 outDelta) =
            MatchMath.computeFillDeltas(makerPrice, amt, /*takerIsBuy*/ false, /*isSynthetic*/ true);
        if (outDelta == 0) return;

        // For MERGE: inDelta == fillAmt (taker pays tokens), outDelta = USDC share.
        assertEq(inDelta, amt, "inDelta == fillAmt for MERGE");

        // Taker receives `fillAmt - makerShare`. makerShare is floored, so taker
        // receives AT LEAST the exact share.
        uint256 makerShareExact = (amt * makerPrice) / PRICE_PRECISION;
        assertEq(outDelta, amt - makerShareExact, "outDelta = fillAmt - makerShare");

        uint256 takerOutScaled = outDelta * PRICE_PRECISION;
        uint256 exactScaled = amt * (PRICE_PRECISION - makerPrice);
        assertGe(takerOutScaled, exactScaled, "taker receives at least the exact share");
        assertLt(takerOutScaled - exactScaled, PRICE_PRECISION, "drift < 1 wei per fill");
    }

    /// @notice Sum bound: 1024 random fills cannot accumulate drift > 1024 wei
    ///         on either path. Combined with the per-fill bound above, this
    ///         documents that long-running protocol operation cannot leak
    ///         meaningful value via rounding even after millions of trades.
    function test_N01_CumulativeDrift1024Fills() public pure {
        uint256 totalDriftMint;
        uint256 totalDriftMerge;
        for (uint256 i; i < 1024; ++i) {
            uint256 amt = (i * 12345 + 7) % type(uint64).max;
            if (amt == 0) amt = 1;
            uint256 makerPrice = 10_000 * ((i % 98) + 1); // tick-aligned 10_000..980_000

            (uint256 mintIn,) = MatchMath.computeFillDeltas(makerPrice, amt, true, true);
            (, uint256 mergeOut) = MatchMath.computeFillDeltas(makerPrice, amt, false, true);

            uint256 exact = (amt * (PRICE_PRECISION - makerPrice)) / PRICE_PRECISION;
            if (mintIn > exact) totalDriftMint += (mintIn - exact);
            if (mergeOut > exact) totalDriftMerge += (mergeOut - exact);
        }
        // Worst case: 1 wei per fill across 1024 fills.
        assertLe(totalDriftMint, 1024, "cumulative MINT drift bounded by N fills");
        assertLe(totalDriftMerge, 1024, "cumulative MERGE drift bounded by N fills");
    }
}
