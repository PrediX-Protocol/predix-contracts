// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {IPrediXExchange} from "../../src/IPrediXExchange.sol";
import {MatchMath} from "../../src/libraries/MatchMath.sol";

import {ExchangeTestBase} from "../base/ExchangeTestBase.sol";

/// @notice Repro for GAP-C / §X2 — preview and execute both route rounding
///         through `MatchMath.computeFillDeltas`, so the pre-fix 1-wei drift
///         (session 2026-04-20 BUY_YES $1 trace: preview cost = 1_000_000,
///         execute cost = 999_999) cannot re-emerge. Complements the
///         `PreviewExecuteParity.t.sol` fuzz by locking specific per-match-
///         type scenarios and the helper's dust / assignment contract.
contract GapC_PreviewExecuteParity is ExchangeTestBase {
    function _previewAndExecute(
        address taker,
        IPrediXExchange.Side side,
        uint256 limitPrice,
        uint256 amountIn,
        uint256 maxFills
    ) internal returns (uint256 previewFilled, uint256 previewCost, uint256 actualFilled, uint256 actualCost) {
        uint256 snap = vm.snapshot();
        (previewFilled, previewCost) = exchange.previewFillMarketOrder(MARKET_ID, side, limitPrice, amountIn, maxFills);
        vm.revertTo(snap);

        vm.prank(taker);
        (actualFilled, actualCost) =
            exchange.fillMarketOrder(MARKET_ID, side, limitPrice, amountIn, taker, taker, maxFills, _deadline());
    }

    function test_GapC_PreviewMatchesExecute_ComplementaryFill() public {
        // Taker BUY_YES hits a resting SELL_YES maker (classic complementary).
        _placeSellYes(alice, 470_000, 10 * ONE_SHARE);
        _giveUsdc(bob, 100 * ONE_SHARE);

        (uint256 pFilled, uint256 pCost, uint256 aFilled, uint256 aCost) =
            _previewAndExecute(bob, IPrediXExchange.Side.BUY_YES, 500_000, 5 * ONE_SHARE, 5);

        assertEq(pFilled, aFilled, "complementary filled byte-match");
        assertEq(pCost, aCost, "complementary cost byte-match");
    }

    function test_GapC_PreviewMatchesExecute_SyntheticMint() public {
        // Taker BUY_YES with no SELL_YES on book but a BUY_NO @ 0.40 → synthetic
        // MINT (taker + maker combine USDC for splitPosition).
        _placeBuyNo(alice, 400_000, 10 * ONE_SHARE);
        _giveUsdc(bob, 100 * ONE_SHARE);

        (uint256 pFilled, uint256 pCost, uint256 aFilled, uint256 aCost) =
            _previewAndExecute(bob, IPrediXExchange.Side.BUY_YES, 990_000, 6 * ONE_SHARE, 5);

        assertEq(pFilled, aFilled, "MINT filled byte-match");
        assertEq(pCost, aCost, "MINT cost byte-match");
    }

    function test_GapC_PreviewMatchesExecute_SyntheticMerge() public {
        // Taker SELL_NO hits SELL_YES maker → MERGE. Ties directly to §X1
        // (taker gets complement); preview and execute must agree on the
        // shares paid in AND USDC paid out.
        _placeSellYes(alice, 770_000, 10 * ONE_SHARE);
        _giveYesNo(bob, 10 * ONE_SHARE);

        (uint256 pFilled, uint256 pCost, uint256 aFilled, uint256 aCost) =
            _previewAndExecute(bob, IPrediXExchange.Side.SELL_NO, 10_000, 5 * ONE_SHARE, 5);

        assertEq(pFilled, aFilled, "MERGE filled byte-match");
        assertEq(pCost, aCost, "MERGE cost byte-match");
    }

    function test_GapC_NoSingleWeiDrift_BuyYes1USD() public {
        // Fresh-deploy BUY_YES $1 trace from the 2026-04-20 diagnosis.
        // Pre-fix: preview 1_000_000 vs execute 999_999. Post-fix: equal.
        _placeSellYes(alice, 470_000, 10 * ONE_SHARE);
        _giveUsdc(bob, 100 * ONE_SHARE);

        (uint256 pFilled, uint256 pCost, uint256 aFilled, uint256 aCost) =
            _previewAndExecute(bob, IPrediXExchange.Side.BUY_YES, 500_000, 1_000_000, 5);

        assertEq(pCost, aCost, "1-wei drift must not return");
        assertEq(pFilled, aFilled, "filled also match at 1 USDC input");
    }

    function test_GapC_MatchMath_DustShortCircuit() public pure {
        // Direct contract on the helper: the `(0, 0)` dust return IS the
        // canonical break signal for the waterfall. A later refactor that
        // makes the helper revert on dust would break the loop-break pattern
        // in Views / TakerPath without touching either call site, so this
        // test locks the current contract.
        (uint256 inDelta, uint256 outDelta) =
            MatchMath.computeFillDeltas({makerPrice: 1, fillAmt: 100, takerIsBuy: true, isSynthetic: false});
        assertEq(inDelta, 0, "dust in");
        assertEq(outDelta, 0, "dust out");

        // Non-dust sanity: BUY complementary at 0.5, fillAmt = 100.
        (inDelta, outDelta) = MatchMath.computeFillDeltas({
            makerPrice: 500_000, fillAmt: 100 * ONE_SHARE, takerIsBuy: true, isSynthetic: false
        });
        assertEq(outDelta, 100 * ONE_SHARE, "BUY COMP outDelta = shares");
        assertEq(inDelta, 50 * ONE_SHARE, "BUY COMP inDelta = shares * price");

        // SYNTHETIC both branches: MINT (takerIsBuy=true) and MERGE (false)
        // share identical math; only the in/out assignment flips.
        (uint256 mintIn, uint256 mintOut) = MatchMath.computeFillDeltas({
            makerPrice: 770_000, fillAmt: 10 * ONE_SHARE, takerIsBuy: true, isSynthetic: true
        });
        (uint256 mergeIn, uint256 mergeOut) = MatchMath.computeFillDeltas({
            makerPrice: 770_000, fillAmt: 10 * ONE_SHARE, takerIsBuy: false, isSynthetic: true
        });
        assertEq(mintOut, mergeIn, "MINT.out == MERGE.in (both = fillAmt)");
        assertEq(mintIn, mergeOut, "MINT.in == MERGE.out (both = takerPortion)");
        assertEq(mintOut, 10 * ONE_SHARE);
        assertEq(mintIn, 10 * ONE_SHARE - (10 * ONE_SHARE * 770_000) / 1e6);
    }
}
