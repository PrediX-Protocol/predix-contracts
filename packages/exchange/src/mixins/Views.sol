// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import {IMarketFacet} from "@predix/shared/interfaces/IMarketFacet.sol";

import {IPrediXExchange} from "../IPrediXExchange.sol";
import {ExchangeStorage} from "../ExchangeStorage.sol";
import {PriceBitmap} from "../libraries/PriceBitmap.sol";
import {MatchMath} from "../libraries/MatchMath.sol";

/// @title Views
/// @notice Read-only orderbook queries + `fillMarketOrder` simulation.
/// @dev `_previewFillMarketOrder` mirrors the taker-path waterfall using the same
///      `MarketView` cache pattern, the same `MatchMath` helpers, and the same
///      output/cost arithmetic the execution helpers in `TakerPath` use. It tracks
///      "virtually consumed" capacity per maker order in two bounded memory arrays
///      so a multi-fill simulation never re-picks the same order.
abstract contract Views is ExchangeStorage {
    using PriceBitmap for uint256;

    // ============ previewFillMarketOrder ============

    function _previewFillMarketOrder(
        uint256 marketId,
        IPrediXExchange.Side takerSide,
        uint256 limitPrice,
        uint256 amountIn,
        uint256 maxFills,
        address taker
    ) internal view virtual returns (uint256 filled, uint256 cost) {
        (filled, cost,) = _simulateFill(marketId, takerSide, limitPrice, amountIn, maxFills, taker);
    }

    /// @notice Protocol fee `ΣF` the real fill would charge (BUY marginal clamp / per-fill SELL). The builder
    ///         fee is EXCLUDED (the router + plain-preview path pass `builder = bytes32(0)`); a `*WithFee` FE
    ///         variant would cover the builder case. For integrator/FE net-of-fee quoting (§13.1).
    function _previewProtocolFee(
        uint256 marketId,
        IPrediXExchange.Side takerSide,
        uint256 limitPrice,
        uint256 amountIn,
        uint256 maxFills,
        address taker
    ) internal view returns (uint256 protocolFee) {
        (,, protocolFee) = _simulateFill(marketId, takerSide, limitPrice, amountIn, maxFills, taker);
    }

    /// @dev Shared simulation core for both preview entry points. Mirrors the taker-path EXECUTE exactly:
    ///      same `MatchMath.computeFillDeltas` rounding, the same shared `_clampBuyFill` for budget-bound BUYs,
    ///      the same protocol-fee curve per fill — so the router's `_convergeCap` keeps its monotone fixed
    ///      point (§13.1). Protocol-fee-inclusive (rate read off `MarketView`), builder fee EXCLUDED. BUY:
    ///      `cost` folds `inDelta + F` and the marginal clamp bounds it. SELL: `cost` stays SHARES (NOT
    ///      fee-reduced; the SELL fee is skimmed from `usdcOut` at execute), `F` accumulates into `protocolFee`.
    ///      `coef == 0` ⇒ byte-identical to the pre-fee preview (P10).
    function _simulateFill(
        uint256 marketId,
        IPrediXExchange.Side takerSide,
        uint256 limitPrice,
        uint256 amountIn,
        uint256 maxFills,
        address taker
    ) internal view returns (uint256 filled, uint256 cost, uint256 protocolFee) {
        if (amountIn == 0) return (0, 0, 0);

        // Match `_fillMarketOrder` validation so a successful preview implies the real call would not revert.
        IMarketFacet.MarketView memory mkt = _loadMarket(marketId);
        _validateMarketActive(mkt);

        uint16 coef = mkt.protocolFeeRateBps; // builder excluded (router passes builder=0)
        bool feeActive = coef > 0;
        uint256 effectiveMaxFills = maxFills == 0 ? DEFAULT_MAX_FILLS : maxFills;
        uint256 remaining = amountIn;
        bool takerIsBuy = MatchMath.isBuy(takerSide);

        bytes32[] memory visitedOrderIds = new bytes32[](effectiveMaxFills);
        uint256[] memory consumedPerOrder = new uint256[](effectiveMaxFills);
        uint256 visited;

        for (uint256 i; i < effectiveMaxFills; ++i) {
            if (remaining == 0) break;

            (FillSource source, uint256 makerPrice, bytes32 makerOrderId, uint256 fillAmount) = _pickBestSourceVirtual(
                marketId, takerSide, limitPrice, remaining, visitedOrderIds, consumedPerOrder, visited, taker
            );

            if (source == FillSource.NONE || fillAmount == 0) break;

            // Marginal BUY clamp — identical to execute (shared `_clampBuyFill`, builder bps 0).
            if (takerIsBuy && feeActive) {
                fillAmount = _clampBuyFill(fillAmount, makerPrice, source, coef, 0, remaining);
                if (fillAmount == 0) break;
            }

            // Preview and execute share `MatchMath.computeFillDeltas` so their rounding cannot drift.
            (uint256 inDelta, uint256 outDelta) =
                MatchMath.computeFillDeltas(makerPrice, fillAmount, takerIsBuy, source == FillSource.SYNTHETIC);

            if (outDelta == 0) break;

            filled += outDelta;
            if (feeActive) {
                uint256 pEff = source == FillSource.SYNTHETIC ? (PRICE_PRECISION - makerPrice) : makerPrice;
                uint256 f = _curveFee(fillAmount, coef, pEff);
                protocolFee += f;
                cost += takerIsBuy ? inDelta + f : inDelta; // BUY fee-inclusive; SELL `cost` stays shares
            } else {
                cost += inDelta;
            }
            remaining = amountIn > cost ? amountIn - cost : 0;

            visitedOrderIds[visited] = makerOrderId;
            consumedPerOrder[visited] = fillAmount;
            visited++;
        }
    }

    function _pickBestSourceVirtual(
        uint256 marketId,
        IPrediXExchange.Side takerSide,
        uint256 limitPrice,
        uint256 remainingBudget,
        bytes32[] memory visitedOrderIds,
        uint256[] memory consumedPerOrder,
        uint256 visited,
        address taker
    ) internal view returns (FillSource source, uint256 makerPrice, bytes32 makerOrderId, uint256 fillAmount) {
        (IPrediXExchange.Side compSide, IPrediXExchange.Side synSide) = MatchMath.sidesFor(takerSide);

        (uint256 compBest, bytes32 compOrderId, uint256 compCapacity) =
            _peekBestVirtual(marketId, compSide, visitedOrderIds, consumedPerOrder, visited, taker);
        (uint256 synBestMaker, bytes32 synOrderId, uint256 synCapacity) =
            _peekBestVirtual(marketId, synSide, visitedOrderIds, consumedPerOrder, visited, taker);

        uint256 synBestEffective = MatchMath.syntheticEffectivePrice(synBestMaker);

        bool takerIsBuy = MatchMath.isBuy(takerSide);
        bool compOk = compBest > 0 && MatchMath.priceWithinLimit(compBest, limitPrice, takerIsBuy);
        bool synOk = synBestEffective > 0 && MatchMath.priceWithinLimit(synBestEffective, limitPrice, takerIsBuy);

        if (!compOk && !synOk) return (FillSource.NONE, 0, bytes32(0), 0);

        bool pickComp = MatchMath.preferComplementary(compBest, synBestEffective, compOk, synOk, takerIsBuy);

        if (pickComp) {
            source = FillSource.COMPLEMENTARY;
            makerPrice = compBest;
            makerOrderId = compOrderId;
            fillAmount = MatchMath.computeFillAmount(compCapacity, remainingBudget, compBest, takerIsBuy, false);
        } else {
            source = FillSource.SYNTHETIC;
            makerPrice = synBestMaker;
            makerOrderId = synOrderId;
            fillAmount = MatchMath.computeFillAmount(synCapacity, remainingBudget, synBestMaker, takerIsBuy, true);
        }
    }

    /// @dev Multi-level virtual peek. Walks the bitmap from the best price toward the
    ///      worst, and at each populated level walks the queue, skipping cancelled /
    ///      fully-filled / zero-deposit entries and subtracting any virtually
    ///      consumed amount from each live order's capacity. Returns the first
    ///      live order with positive remaining capacity. Walking multiple levels
    ///      mirrors the way `_fillMarketOrder` advances after cleanup clears a
    ///      level's bitmap bit between iterations — without this loop, preview would
    ///      under-report fills whenever a single iteration exhausts the best level.
    function _peekBestVirtual(
        uint256 marketId,
        IPrediXExchange.Side side,
        bytes32[] memory visitedOrderIds,
        uint256[] memory consumedPerOrder,
        uint256 visited,
        address taker
    ) internal view returns (uint256 price, bytes32 orderId, uint256 adjustedCapacity) {
        uint256 bitmap = priceBitmap[marketId][side];
        if (bitmap == 0) return (0, bytes32(0), 0);

        bool isBuySide = MatchMath.isBuy(side);
        uint8 idx = isBuySide ? bitmap.highestBit() : bitmap.lowestBit();

        while (true) {
            if (bitmap & (uint256(1) << idx) != 0) {
                bytes32[] storage queue = _orderQueue[marketId][side][idx];
                uint256 len = queue.length;
                for (uint256 i; i < len; ++i) {
                    IPrediXExchange.Order storage order = orders[queue[i]];
                    if (order.cancelled) continue;
                    if (order.filled >= order.amount) continue;
                    if (order.depositLocked == 0) continue;
                    // Mirror taker-path self-match skip so preview matches
                    // execute when the caller has resting orders on the
                    // opposite side.
                    if (taker != address(0) && order.owner == taker) continue;

                    uint256 rawCapacity = order.amount - order.filled;
                    uint256 virtuallyConsumed;
                    for (uint256 j; j < visited; ++j) {
                        if (visitedOrderIds[j] == queue[i]) {
                            virtuallyConsumed += consumedPerOrder[j];
                        }
                    }

                    if (rawCapacity > virtuallyConsumed) {
                        return (order.price, queue[i], rawCapacity - virtuallyConsumed);
                    }
                }
            }

            // Advance to the next worse price level. Bounded by [0, MAX_PRICE_INDEX].
            if (isBuySide) {
                if (idx == 0) return (0, bytes32(0), 0);
                idx--;
            } else {
                if (idx >= MAX_PRICE_INDEX) return (0, bytes32(0), 0);
                idx++;
            }
        }
    }

    // ============ Orderbook views ============

    function _getBestPrices(uint256 marketId)
        internal
        view
        virtual
        returns (uint256 bestBidYes, uint256 bestAskYes, uint256 bestBidNo, uint256 bestAskNo)
    {
        uint256 bm;

        bm = priceBitmap[marketId][IPrediXExchange.Side.BUY_YES];
        bestBidYes = bm != 0 ? _indexToPrice(bm.highestBit()) : 0;

        bm = priceBitmap[marketId][IPrediXExchange.Side.SELL_YES];
        bestAskYes = bm != 0 ? _indexToPrice(bm.lowestBit()) : 0;

        bm = priceBitmap[marketId][IPrediXExchange.Side.BUY_NO];
        bestBidNo = bm != 0 ? _indexToPrice(bm.highestBit()) : 0;

        bm = priceBitmap[marketId][IPrediXExchange.Side.SELL_NO];
        bestAskNo = bm != 0 ? _indexToPrice(bm.lowestBit()) : 0;
    }

    function _getDepthAtPrice(uint256 marketId, IPrediXExchange.Side side, uint256 price)
        internal
        view
        virtual
        returns (uint256 totalAmount)
    {
        uint8 idx = _priceToIndex(price);
        bytes32[] storage queue = _orderQueue[marketId][side][idx];
        uint256 qLen = queue.length;
        for (uint256 i; i < qLen; ++i) {
            IPrediXExchange.Order storage o = orders[queue[i]];
            if (!o.cancelled && o.filled < o.amount) {
                totalAmount += o.amount - o.filled;
            }
        }
    }

    function _getOrderBook(uint256 marketId, uint8 depth)
        internal
        view
        virtual
        returns (
            IPrediXExchange.PriceLevel[] memory yesBids,
            IPrediXExchange.PriceLevel[] memory yesAsks,
            IPrediXExchange.PriceLevel[] memory noBids,
            IPrediXExchange.PriceLevel[] memory noAsks
        )
    {
        yesBids = _getLevels(marketId, IPrediXExchange.Side.BUY_YES, depth, false);
        yesAsks = _getLevels(marketId, IPrediXExchange.Side.SELL_YES, depth, true);
        noBids = _getLevels(marketId, IPrediXExchange.Side.BUY_NO, depth, false);
        noAsks = _getLevels(marketId, IPrediXExchange.Side.SELL_NO, depth, true);
    }

    /// @dev Walk the bitmap for up to `depth` populated price levels in either
    ///      direction. Used by `_getOrderBook`.
    function _getLevels(uint256 marketId, IPrediXExchange.Side side, uint8 depth, bool ascending)
        internal
        view
        returns (IPrediXExchange.PriceLevel[] memory levels)
    {
        uint256 bitmap = priceBitmap[marketId][side];
        if (bitmap == 0) return new IPrediXExchange.PriceLevel[](0);

        IPrediXExchange.PriceLevel[] memory temp = new IPrediXExchange.PriceLevel[](depth);
        uint256 count;
        uint8 idx = ascending ? bitmap.lowestBit() : bitmap.highestBit();

        while (count < depth) {
            if (priceBitmap[marketId][side] & (uint256(1) << idx) != 0) {
                uint256 total;
                bytes32[] storage queue = _orderQueue[marketId][side][idx];
                uint256 qLen = queue.length;
                for (uint256 j; j < qLen; ++j) {
                    IPrediXExchange.Order storage o = orders[queue[j]];
                    if (!o.cancelled && o.filled < o.amount) {
                        total += o.amount - o.filled;
                    }
                }
                if (total > 0) {
                    temp[count] = IPrediXExchange.PriceLevel({price: _indexToPrice(idx), totalAmount: total});
                    count++;
                }
            }
            if (ascending) {
                if (idx >= MAX_PRICE_INDEX) break;
                idx++;
            } else {
                if (idx == 0) break;
                idx--;
            }
        }

        levels = new IPrediXExchange.PriceLevel[](count);
        for (uint256 k; k < count; ++k) {
            levels[k] = temp[k];
        }
    }
}
