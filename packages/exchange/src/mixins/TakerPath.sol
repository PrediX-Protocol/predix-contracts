// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {IMarketFacet} from "@predix/shared/interfaces/IMarketFacet.sol";

import {IPrediXExchange} from "../IPrediXExchange.sol";
import {ExchangeStorage} from "../ExchangeStorage.sol";
import {PriceBitmap} from "../libraries/PriceBitmap.sol";
import {MatchMath} from "../libraries/MatchMath.sol";

/// @title TakerPath
/// @notice Permissionless taker-side logic for `fillMarketOrder` (4-way waterfall).
/// @dev Inherited by `PrediXExchange`. The external wrapper in the composed contract
///      applies `nonReentrant`; this mixin only exposes `internal` helpers.
abstract contract TakerPath is ExchangeStorage {
    using SafeERC20 for IERC20;
    using PriceBitmap for uint256;

    /// @dev Hot-path context cached once at the top of `_fillMarketOrder`. Avoids
    ///      stack-too-deep in `_executeComplementaryTakerFill` /
    ///      `_executeSyntheticTakerFill` and prevents the helpers from re-reading
    ///      `getMarket` (hot-path waste).
    struct TakerCtx {
        uint256 marketId;
        IPrediXExchange.Side takerSide;
        uint256 limitPrice;
        address taker;
        address recipient;
        address yesToken;
        address noToken;
        bool takerIsBuy;
        bytes32 takerBuilder;
    }

    /// @dev Accumulated taker-side output across the fill loop. Settled once
    ///      at the end of `_fillMarketOrder` instead of per-fill, saving one
    ///      `safeTransfer` per additional fill (~25K gas each).
    ///      Maker settlements remain per-fill (each maker is a different address).
    struct TakerDeltas {
        uint256 usdcOut;
        uint256 tokenOut;
    }

    // ======== Entry ========

    /// @notice Internal entry — the external `nonReentrant` wrapper lives in `PrediXExchange`.
    function _fillMarketOrder(
        uint256 marketId,
        IPrediXExchange.Side takerSide,
        uint256 limitPrice,
        uint256 amountIn,
        address taker,
        address recipient,
        uint256 maxFills,
        uint256 deadline,
        bytes32 takerBuilder
    ) internal returns (uint256 filled, uint256 cost) {
        if (block.timestamp > deadline) {
            revert IPrediXExchange.DeadlineExpired(deadline, block.timestamp);
        }
        if (amountIn == 0) return (0, 0);
        if (taker == address(0) || recipient == address(0)) revert IPrediXExchange.ZeroAddress();
        // Taker MUST be msg.sender. Otherwise any attacker with a matching order
        // could drain any address that has a non-zero USDC allowance to the
        // Exchange (every address that ever placed a maker order). The router
        // always calls with taker=address(this), so this constraint is compatible.
        if (msg.sender != taker) revert IPrediXExchange.NotTaker();

        IMarketFacet.MarketView memory mkt = _loadMarket(marketId);
        _validateMarketActive(mkt);

        TakerCtx memory ctx = TakerCtx({
            marketId: marketId,
            takerSide: takerSide,
            limitPrice: limitPrice,
            taker: taker,
            recipient: recipient,
            yesToken: mkt.yesToken,
            noToken: mkt.noToken,
            takerIsBuy: MatchMath.isBuy(takerSide),
            takerBuilder: takerBuilder
        });

        address inputToken = _inputTokenFor(ctx);
        IERC20(inputToken).safeTransferFrom(taker, address(this), amountIn);

        uint256 effectiveMaxFills = maxFills == 0 ? DEFAULT_MAX_FILLS : maxFills;
        uint256 remaining = amountIn;
        uint256 matchCount;
        TakerDeltas memory deltas;

        for (uint256 i; i < effectiveMaxFills; ++i) {
            if (remaining == 0) break;

            (FillSource source, uint256 makerPrice, bytes32 makerOrderId, uint256 fillAmount) =
                _pickBestSource(ctx, remaining);

            if (source == FillSource.NONE || fillAmount == 0) break;

            (uint256 outDelta, uint256 inDelta) = source == FillSource.COMPLEMENTARY
                ? _executeComplementaryTakerFill(ctx, makerPrice, makerOrderId, fillAmount, deltas)
                : _executeSyntheticTakerFill(ctx, makerPrice, makerOrderId, fillAmount, deltas);

            if (outDelta == 0) {
                // Zero-fill differentiation:
                // Type A — maker is structurally dust: `makerRemaining * price / 1e6 == 0`.
                //          Force-clean and continue to deeper liquidity.
                // Type B — taker has sub-tick budget remaining. Maker is NOT dust
                //          at its own scale, so leave it intact and break.
                IPrediXExchange.Order storage outerMaker = orders[makerOrderId];
                uint256 makerRemaining = outerMaker.amount - outerMaker.filled;
                if ((makerRemaining * makerPrice) / PRICE_PRECISION == 0) {
                    _forceCleanDustMaker(ctx.marketId, makerOrderId, makerPrice);
                    continue;
                }
                break;
            }

            filled += outDelta;
            cost += inDelta;
            remaining = amountIn > cost ? amountIn - cost : 0;
            matchCount++;
        }

        _settleTakerDeltas(ctx, deltas);

        uint256 unused = amountIn - cost;
        if (unused > 0) {
            IERC20(inputToken).safeTransfer(taker, unused);
        }

        emit IPrediXExchange.TakerFilled(marketId, taker, recipient, takerSide, filled, cost, matchCount);
    }

    // ======== Waterfall core ========

    function _pickBestSource(TakerCtx memory ctx, uint256 remainingBudget)
        internal
        view
        returns (FillSource source, uint256 makerPrice, bytes32 makerOrderId, uint256 fillAmount)
    {
        (IPrediXExchange.Side compSide, IPrediXExchange.Side synSide) = MatchMath.sidesFor(ctx.takerSide);

        // Peek with `taker` filter so own orders are skipped silently like
        // MakerPath does (mirrors `i++; continue;`). Without this, a taker
        // holding any resting order at the FIFO head of the opposite side
        // would have the entire `fillMarketOrder` revert with
        // `SelfMatchNotAllowed`, even when non-self liquidity sits behind.
        (uint256 compBest, bytes32 compOrderId) = _peekBest(ctx.marketId, compSide, ctx.taker);
        (uint256 synBestMaker, bytes32 synOrderId) = _peekBest(ctx.marketId, synSide, ctx.taker);

        uint256 synBestEffective = MatchMath.syntheticEffectivePrice(synBestMaker);

        bool compOk = compBest > 0 && MatchMath.priceWithinLimit(compBest, ctx.limitPrice, ctx.takerIsBuy);
        bool synOk =
            synBestEffective > 0 && MatchMath.priceWithinLimit(synBestEffective, ctx.limitPrice, ctx.takerIsBuy);

        if (!compOk && !synOk) return (FillSource.NONE, 0, bytes32(0), 0);

        bool pickComp = MatchMath.preferComplementary(compBest, synBestEffective, compOk, synOk, ctx.takerIsBuy);

        if (pickComp) {
            source = FillSource.COMPLEMENTARY;
            makerPrice = compBest;
            makerOrderId = compOrderId;
            fillAmount = _computeFillAmount(compOrderId, compBest, remainingBudget, ctx.takerIsBuy, false);
        } else {
            source = FillSource.SYNTHETIC;
            makerPrice = synBestMaker;
            makerOrderId = synOrderId;
            fillAmount = _computeFillAmount(synOrderId, synBestMaker, remainingBudget, ctx.takerIsBuy, true);
        }
    }

    /// @notice Best resting order on `side`, skipping cancelled / fully-filled / zero-deposit entries.
    /// @dev With queue-cleanup discipline the loop body executes once in the well-behaved case.
    ///      The defensive `continue` chain stays as a safety net for any future leak.
    /// @dev `taker` parameter is passed through so self-owned orders are skipped
    ///      silently (mirroring MakerPath's `i++; continue;`). Pass `address(0)`
    ///      to disable the filter.
    function _peekBest(uint256 marketId, IPrediXExchange.Side side, address taker)
        internal
        view
        returns (uint256 price, bytes32 orderId)
    {
        uint256 bitmap = priceBitmap[marketId][side];
        if (bitmap == 0) return (0, bytes32(0));

        uint8 priceIdx = MatchMath.isBuy(side) ? bitmap.highestBit() : bitmap.lowestBit();
        bytes32[] storage queue = _orderQueue[marketId][side][priceIdx];

        uint256 len = queue.length;
        for (uint256 i; i < len; ++i) {
            IPrediXExchange.Order storage order = orders[queue[i]];
            if (order.cancelled) continue;
            if (order.filled >= order.amount) continue;
            if (order.depositLocked == 0) continue;
            // Skip own orders so the waterfall progresses past them.
            if (taker != address(0) && order.owner == taker) continue;
            return (order.price, queue[i]);
        }
        return (0, bytes32(0));
    }

    function _computeFillAmount(
        bytes32 makerOrderId,
        uint256 price,
        uint256 remainingBudget,
        bool takerIsBuy,
        bool isSynthetic
    ) internal view returns (uint256) {
        IPrediXExchange.Order storage order = orders[makerOrderId];
        uint256 makerCapacity = order.amount - order.filled;
        return MatchMath.computeFillAmount(makerCapacity, remainingBudget, price, takerIsBuy, isSynthetic);
    }

    // ======== Execution helpers ========

    /// @dev Direct opposite-side match. Tokens already in this contract from upfront pull
    ///      (taker side) and from maker's `depositLocked`.
    /// @dev Self-match check compares against the fund-provider (`taker`), NOT the
    ///      ultimate `recipient`. A router pattern where `taker == router` and the
    ///      end user is both `maker.owner` and `recipient` will NOT trigger this
    ///      guard — that case is a gas waste, not a solvency issue, and is left to
    ///      the router to surface.
    function _executeComplementaryTakerFill(
        TakerCtx memory ctx,
        uint256 price,
        bytes32 makerOrderId,
        uint256 matchAmount,
        TakerDeltas memory deltas
    ) internal returns (uint256 outDelta, uint256 inDelta) {
        IPrediXExchange.Order storage makerOrder = orders[makerOrderId];
        if (makerOrder.owner == ctx.taker) revert IPrediXExchange.SelfMatchNotAllowed();

        // Rounding shared with preview via MatchMath.computeFillDeltas.
        // Returns (0, 0) on dust → skip before state mutation.
        (inDelta, outDelta) = MatchMath.computeFillDeltas(price, matchAmount, ctx.takerIsBuy, false);
        if (outDelta == 0) return (0, 0);
        uint256 usdcAmount = ctx.takerIsBuy ? inDelta : outDelta;

        address makerOwner = makerOrder.owner;
        IPrediXExchange.Side makerSide = makerOrder.side;

        // Effects: settle maker order state before external transfer (CEI).
        makerOrder.filled += uint128(matchAmount);
        if (ctx.takerIsBuy) {
            makerOrder.depositLocked -= uint128(matchAmount);
        } else {
            makerOrder.depositLocked -= uint128(usdcAmount);
        }
        bool fullyFilled = makerOrder.filled >= makerOrder.amount;

        // Interactions: maker paid per-fill, taker output accumulated in deltas.
        if (ctx.takerIsBuy) {
            deltas.tokenOut += matchAmount;
            IERC20(usdc).safeTransfer(makerOwner, usdcAmount);
        } else {
            deltas.usdcOut += usdcAmount;
            IERC20(ctx.takerSide == IPrediXExchange.Side.SELL_YES ? ctx.yesToken : ctx.noToken).safeTransfer(
                makerOwner, matchAmount
            );
        }

        emit IPrediXExchange.OrderMatched(
            makerOrderId,
            bytes32(0),
            ctx.marketId,
            IPrediXExchange.MatchType.COMPLEMENTARY,
            matchAmount,
            price,
            makerOrder.builder,
            ctx.takerBuilder
        );

        if (fullyFilled) {
            _onMakerFullyFilled(ctx.marketId, makerSide, _priceToIndex(price), makerOrderId, makerOwner);
        }
    }

    /// @dev Synthetic match: same-action opposite-token via `splitPosition` (MINT)
    ///      or `mergePositions` (MERGE). Taker effective price = `1 - makerPrice`,
    ///      so the per-fill sum is exactly `matchAmount` USDC and zero surplus is
    ///      generated in the taker path (spec Q11).
    /// @dev Self-match check compares against the fund-provider (`taker`), NOT the
    ///      ultimate `recipient`. A router pattern where `taker == router` and the
    ///      end user is both `maker.owner` and `recipient` will NOT trigger this
    ///      guard — that case is a gas waste, not a solvency issue, and is left to
    ///      the router to surface.
    function _executeSyntheticTakerFill(
        TakerCtx memory ctx,
        uint256 makerPrice,
        bytes32 makerOrderId,
        uint256 matchAmount,
        TakerDeltas memory deltas
    ) internal returns (uint256 outDelta, uint256 inDelta) {
        IPrediXExchange.Order storage makerOrder = orders[makerOrderId];
        if (makerOrder.owner == ctx.taker) revert IPrediXExchange.SelfMatchNotAllowed();

        address makerOwner = makerOrder.owner;
        IPrediXExchange.Side makerSide = makerOrder.side;
        uint8 priceIdx = _priceToIndex(makerOrder.price);
        bool fullyFilled;

        (inDelta, outDelta) = MatchMath.computeFillDeltas(makerPrice, matchAmount, ctx.takerIsBuy, true);
        if (outDelta == 0) return (0, 0);

        if (ctx.takerIsBuy) {
            // MINT — combined USDC funds splitPosition, distribute YES/NO.
            // inDelta = taker USDC contribution; maker fronts the complement.
            uint256 makerUsdc = matchAmount - inDelta;
            if (makerOrder.depositLocked < makerUsdc) revert IPrediXExchange.InsufficientLiquidity();

            makerOrder.filled += uint128(matchAmount);
            makerOrder.depositLocked -= uint128(makerUsdc);
            fullyFilled = makerOrder.filled >= makerOrder.amount;

            IMarketFacet(diamond).splitPosition(ctx.marketId, matchAmount);

            (, address makerOut) = ctx.takerSide == IPrediXExchange.Side.BUY_YES
                ? (ctx.yesToken, ctx.noToken)
                : (ctx.noToken, ctx.yesToken);

            deltas.tokenOut += matchAmount;
            IERC20(makerOut).safeTransfer(makerOwner, matchAmount);

            emit IPrediXExchange.OrderMatched(
                makerOrderId, bytes32(0), ctx.marketId, IPrediXExchange.MatchType.MINT, matchAmount, makerPrice,
                makerOrder.builder, ctx.takerBuilder
            );
        } else {
            // MERGE — combined YES+NO funds mergePositions, distribute USDC.
            // outDelta = taker USDC share; maker gets the complement.
            uint256 makerUsdcShare = matchAmount - outDelta;
            if (makerOrder.depositLocked < matchAmount) revert IPrediXExchange.InsufficientLiquidity();

            makerOrder.filled += uint128(matchAmount);
            makerOrder.depositLocked -= uint128(matchAmount);
            fullyFilled = makerOrder.filled >= makerOrder.amount;

            IMarketFacet(diamond).mergePositions(ctx.marketId, matchAmount);

            deltas.usdcOut += outDelta;
            IERC20(usdc).safeTransfer(makerOwner, makerUsdcShare);

            emit IPrediXExchange.OrderMatched(
                makerOrderId, bytes32(0), ctx.marketId, IPrediXExchange.MatchType.MERGE, matchAmount, makerPrice,
                makerOrder.builder, ctx.takerBuilder
            );
        }

        if (fullyFilled) {
            _onMakerFullyFilled(ctx.marketId, makerSide, priceIdx, makerOrderId, makerOwner);
        }
    }

    // ======== Deferred taker settlement ========

    /// @dev Batch-transfer accumulated taker output in one shot. Called once at
    ///      the end of `_fillMarketOrder`. Skips zero-valued legs.
    function _settleTakerDeltas(TakerCtx memory ctx, TakerDeltas memory d) internal {
        if (d.usdcOut > 0) {
            IERC20(usdc).safeTransfer(ctx.recipient, d.usdcOut);
        }
        if (d.tokenOut > 0) {
            address outToken = ctx.takerIsBuy
                ? (ctx.takerSide == IPrediXExchange.Side.BUY_YES ? ctx.yesToken : ctx.noToken)
                : usdc;
            if (outToken != usdc) {
                IERC20(outToken).safeTransfer(ctx.recipient, d.tokenOut);
            }
        }
    }

    // ======== Token resolution ========

    function _inputTokenFor(TakerCtx memory ctx) internal view returns (address) {
        if (ctx.takerIsBuy) return usdc;
        return ctx.takerSide == IPrediXExchange.Side.SELL_YES ? ctx.yesToken : ctx.noToken;
    }

    // `_forceCleanDustMaker` + `_yesTokenFor` / `_noTokenFor` were moved up to
    // `ExchangeStorage` so `MakerPath` can also reach them when force-cleaning
    // structural dust during maker-vs-maker matching (M-04).
}
