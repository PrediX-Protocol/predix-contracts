// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {IPrediXExchange} from "../IPrediXExchange.sol";

/// @title MatchMath
/// @notice Pure math + side mapping helpers shared by the taker waterfall and the preview path.
/// @dev No state, no side effects.
///
///      Plain `(a*b)/c` is used instead of `FullMath.mulDiv`. Prediction-market bounds:
///        amount ≤ totalCollateral (far below 2^128 / 1e6),
///        price  ≤ MAX_PRICE = 990_000,
///      so the product stays well within uint256 and Solidity 0.8 overflow checks cover the
///      remaining corner cases. Matches spec §8.7.
library MatchMath {
    uint256 internal constant PRICE_PRECISION = 1e6;

    /// @notice Whether `side` is a BUY (taker pays USDC) as opposed to a SELL (taker pays tokens).
    function isBuy(IPrediXExchange.Side side) internal pure returns (bool) {
        return side == IPrediXExchange.Side.BUY_YES || side == IPrediXExchange.Side.BUY_NO;
    }

    /// @notice Given a taker side, return the complementary and synthetic opposite sides.
    /// @dev   taker       | comp      | syn            effect
    ///        BUY_YES     | SELL_YES  | BUY_NO         (MINT)
    ///        SELL_YES    | BUY_YES   | SELL_NO        (MERGE)
    ///        BUY_NO      | SELL_NO   | BUY_YES        (MINT)
    ///        SELL_NO     | BUY_NO    | SELL_YES       (MERGE)
    function sidesFor(IPrediXExchange.Side takerSide)
        internal
        pure
        returns (IPrediXExchange.Side comp, IPrediXExchange.Side syn)
    {
        if (takerSide == IPrediXExchange.Side.BUY_YES) {
            return (IPrediXExchange.Side.SELL_YES, IPrediXExchange.Side.BUY_NO);
        }
        if (takerSide == IPrediXExchange.Side.SELL_YES) {
            return (IPrediXExchange.Side.BUY_YES, IPrediXExchange.Side.SELL_NO);
        }
        if (takerSide == IPrediXExchange.Side.BUY_NO) {
            return (IPrediXExchange.Side.SELL_NO, IPrediXExchange.Side.BUY_YES);
        }
        return (IPrediXExchange.Side.BUY_NO, IPrediXExchange.Side.SELL_YES);
    }

    /// @notice Effective price paid by the taker in a synthetic match against a maker priced at `makerPrice`.
    /// @dev `takerEffective + makerPrice == PRICE_PRECISION` always → zero surplus in the taker synthetic path.
    ///      Returns 0 for out-of-range `makerPrice` so callers treat it as "no liquidity".
    function syntheticEffectivePrice(uint256 makerPrice) internal pure returns (uint256) {
        if (makerPrice == 0 || makerPrice >= PRICE_PRECISION) return 0;
        return PRICE_PRECISION - makerPrice;
    }

    /// @notice Whether `price` respects the taker's limit (cap for BUY, floor for SELL).
    function priceWithinLimit(uint256 price, uint256 limitPrice, bool takerIsBuy) internal pure returns (bool) {
        return takerIsBuy ? price <= limitPrice : price >= limitPrice;
    }

    /// @notice Decide whether the complementary source beats the synthetic source this iteration.
    /// @dev Tiebreaker prefers complementary because it avoids a Diamond external call.
    function preferComplementary(uint256 compPrice, uint256 synEffectivePrice, bool compOk, bool synOk, bool takerIsBuy)
        internal
        pure
        returns (bool)
    {
        if (!compOk) return false;
        if (!synOk) return true;
        return takerIsBuy ? compPrice <= synEffectivePrice : compPrice >= synEffectivePrice;
    }

    /// @notice Fill size at a single maker level = min(maker capacity, taker capacity derived from budget).
    /// @dev For BUY takers, capacity converts budget → shares at the per-share price (raw for complementary,
    ///      `1 - makerPrice` for synthetic). For SELL takers, budget is already in shares.
    function computeFillAmount(
        uint256 makerCapacity,
        uint256 remainingBudget,
        uint256 price,
        bool takerIsBuy,
        bool isSynthetic
    ) internal pure returns (uint256 fillAmount) {
        uint256 takerCapacity;

        if (takerIsBuy) {
            uint256 pricePerShare = isSynthetic ? PRICE_PRECISION - price : price;
            takerCapacity = pricePerShare == 0 ? type(uint256).max : (remainingBudget * PRICE_PRECISION) / pricePerShare;
        } else {
            takerCapacity = remainingBudget;
        }

        fillAmount = makerCapacity < takerCapacity ? makerCapacity : takerCapacity;
    }

    /// @notice Canonical (inDelta, outDelta) for a single fill. GAP-C fix:
    ///         both preview (`Views._previewFillMarketOrder`) and execute
    ///         (`TakerPath._execute{Complementary,Synthetic}TakerFill`,
    ///         `MakerPath._executeMergeFill`) MUST call this so the rounding
    ///         is byte-identical and a "preview says X, execute delivers X+1"
    ///         drift cannot re-emerge.
    /// @dev    A `(0, 0)` return is the canonical dust signal: the waterfall
    ///         caller breaks out of its fill loop, matching the pre-helper
    ///         "`usdcAmount == 0 break;`" short-circuit. Do NOT revert — the
    ///         outer loop must also stop advancing maker capacity.
    ///         SYNTHETIC branch covers both MINT (both-BUY, `takerIsBuy=true`)
    ///         and MERGE (both-SELL, `takerIsBuy=false`) because the rounding
    ///         formula `takerPortion = fillAmt - makerShare` is identical —
    ///         only the assignment to `inDelta` vs `outDelta` differs.
    function computeFillDeltas(uint256 makerPrice, uint256 fillAmt, bool takerIsBuy, bool isSynthetic)
        internal
        pure
        returns (uint256 inDelta, uint256 outDelta)
    {
        uint256 makerShare = (fillAmt * makerPrice) / PRICE_PRECISION;
        if (makerShare == 0) return (0, 0);

        if (!isSynthetic) {
            if (takerIsBuy) {
                outDelta = fillAmt;
                inDelta = makerShare;
            } else {
                outDelta = makerShare;
                inDelta = fillAmt;
            }
        } else {
            uint256 takerPortion = fillAmt - makerShare;
            if (takerIsBuy) {
                outDelta = fillAmt;
                inDelta = takerPortion;
            } else {
                outDelta = takerPortion;
                inDelta = fillAmt;
            }
        }
    }
}
