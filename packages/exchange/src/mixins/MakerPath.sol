// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {IMarketFacet} from "@predix/shared/interfaces/IMarketFacet.sol";

import {IPrediXExchange} from "../IPrediXExchange.sol";
import {ExchangeStorage} from "../ExchangeStorage.sol";
import {PriceBitmap} from "../libraries/PriceBitmap.sol";
import {MatchMath} from "../libraries/MatchMath.sol";

/// @title MakerPath
/// @notice Maker-side logic: `_placeOrder` (with phase-A complementary + phase-B
///         synthetic auto-matching against resting orders) and `_cancelOrder`.
/// @dev Ported from the legacy monolith with the V2 interface migration and the
///      audit fixes mandated by the package review:
///        - H-01 (M1)  : `userOrderCount` decremented when a maker order is fully
///                       filled (in matching) or cancelled. Wired through
///                       `_onMakerFullyFilled` so M5 cleanup happens in lock-step.
///        - H-02 (M2)  : `_cancelOrder` is permissionless on terminal markets
///                       (expired / resolved / refund-mode), keeper pattern.
///        - M4         : `_placeOrder` enforces the `uint128` bound on `amount` and
///                       on the computed `depositLocked` so the packed-struct cast
///                       never silently truncates.
///        - M5         : every fully-filled order goes through `_onMakerFullyFilled`,
///                       which calls `_removeFromQueue` and clears the bitmap bit
///                       when the queue empties.
///
///      `FullMath.mulDiv` from the legacy is replaced with `(a * b) / c`. Each call
///      site is bounded by `amount ≤ uint128.max` (M4) and `price ≤ MAX_PRICE`, so
///      the product stays well within `uint256`.
abstract contract MakerPath is ExchangeStorage {
    using SafeERC20 for IERC20;
    using PriceBitmap for uint256;

    /// @dev Threaded through matching helpers to avoid stack-too-deep.
    struct MatchCtx {
        bytes32 takerId;
        uint256 marketId;
        IPrediXExchange.Side takerSide;
        uint256 takerPrice;
        address yesToken;
        address noToken;
    }

    // ============ placeOrder ============

    function _placeOrder(uint256 marketId, IPrediXExchange.Side side, uint256 price, uint256 amount)
        internal
        virtual
        returns (bytes32 orderId, uint256 filledAmount)
    {
        // 1. Validate
        _validatePrice(price);
        if (amount == 0 || amount < MIN_ORDER_AMOUNT) revert IPrediXExchange.InvalidAmount();
        if (amount > type(uint128).max) revert IPrediXExchange.InvalidAmount(); // M4

        IMarketFacet.MarketView memory mkt = _loadMarket(marketId);
        _validateMarketActive(mkt);

        if (userOrderCount[marketId][msg.sender] >= MAX_ORDERS_PER_USER) {
            revert IPrediXExchange.MaxOrdersExceeded();
        }

        // 2. Pull deposit (M4 bound applied inside)
        uint256 depositRequired = _collectDeposit(side, price, amount, mkt.yesToken, mkt.noToken);

        // 3. Create order
        orderId = keccak256(abi.encode(msg.sender, _orderNonce++));
        orders[orderId] = IPrediXExchange.Order({
            owner: msg.sender,
            timestamp: uint64(block.timestamp),
            side: side,
            cancelled: false,
            marketId: marketId,
            price: price,
            amount: amount,
            filled: 0,
            depositLocked: uint128(depositRequired)
        });

        // 4. Try matching against resting makers
        uint256 remaining = amount;
        uint256 fillCount;
        MatchCtx memory ctx = MatchCtx({
            takerId: orderId,
            marketId: marketId,
            takerSide: side,
            takerPrice: price,
            yesToken: mkt.yesToken,
            noToken: mkt.noToken
        });

        // Phase A — direct opposite-side (COMPLEMENTARY)
        (remaining, fillCount) = _tryComplementary(ctx, remaining, fillCount);

        // Phase B — same-action opposite-token (MINT for buys, MERGE for sells)
        if (remaining > 0 && fillCount < MAX_FILLS_PER_PLACE) {
            if (MatchMath.isBuy(side)) {
                (remaining, fillCount) = _tryMint(ctx, remaining, fillCount);
            } else {
                (remaining, fillCount) = _tryMerge(ctx, remaining, fillCount);
            }
        }

        // 5. Insert remaining into the book
        filledAmount = amount - remaining;
        orders[orderId].filled = uint128(filledAmount);

        if (remaining > 0) {
            uint8 idx = _priceToIndex(price);
            if (_orderQueue[marketId][side][idx].length >= MAX_QUEUE_DEPTH_PER_PRICE) {
                revert IPrediXExchange.Exchange_QueueFull();
            }
            _orderQueue[marketId][side][idx].push(orderId);
            priceBitmap[marketId][side] = priceBitmap[marketId][side].set(idx);
            userOrderCount[marketId][msg.sender]++;
        } else if (side == IPrediXExchange.Side.BUY_YES || side == IPrediXExchange.Side.BUY_NO) {
            // Placer fully consumed by matching and NOT resting in the book.
            // `_onMakerFullyFilled` never fires for the placer (that hook runs on
            // resting makers during matching), so sweep the BUY residual dust
            // directly to `feeRecipient`. SELL placers have no residual because
            // their deposit and decrements are exact integers.
            uint128 residual = orders[orderId].depositLocked;
            if (residual > 0) {
                orders[orderId].depositLocked = 0;
                IERC20(usdc).safeTransfer(feeRecipient, uint256(residual));
                emit IPrediXExchange.FeeCollected(marketId, uint256(residual));
            }
        }

        emit IPrediXExchange.OrderPlaced(orderId, marketId, msg.sender, side, price, amount);
    }

    // ============ cancelOrder ============

    /// @dev Owner can always cancel. Anyone can cancel on terminal markets — H-02
    ///      keeper pattern, extended to include refund mode (V2 has 3 terminal states).
    function _cancelOrder(bytes32 orderId) internal virtual {
        IPrediXExchange.Order storage order = orders[orderId];
        if (order.owner == address(0)) revert IPrediXExchange.OrderNotFound();
        if (order.cancelled) revert IPrediXExchange.OrderAlreadyCancelled();
        if (order.filled >= order.amount) revert IPrediXExchange.OrderFullyFilled();

        // M3: load `MarketView` once and reuse for both the keeper guard and the
        // refund-token resolution at the end.
        IMarketFacet.MarketView memory mkt = _loadMarket(order.marketId);

        if (order.owner != msg.sender) {
            // H-02 (M2): keepers may cancel after a market reaches a terminal state.
            // V2 has 3 terminal states; refundModeActive added per package review.
            bool marketClosed = mkt.isResolved || mkt.refundModeActive || block.timestamp >= mkt.endTime;
            if (!marketClosed) revert IPrediXExchange.NotOrderOwner();
        }

        // CEI: state first.
        order.cancelled = true;
        uint256 marketId = order.marketId;
        IPrediXExchange.Side side = order.side;
        uint256 price = order.price;
        address orderOwner = order.owner;
        uint128 lockedRefund = order.depositLocked;
        order.depositLocked = 0;

        // M5 + H-01: drop the queue entry (clearing the bitmap bit if empty) and
        // release the per-user slot.
        _decrementOrderCount(marketId, orderOwner);
        _removeFromQueue(marketId, side, _priceToIndex(price), orderId);

        emit IPrediXExchange.OrderCancelled(orderId);

        // Interactions: refund the actual deposit currently held for this order.
        // Refunding `depositLocked` (instead of recomputing `(remaining * price) / 1e6`)
        // returns any per-fill flooring dust that accumulated as over-collateralization
        // on partial-fill BUY orders, keeping the strict invariant exact.
        if (side == IPrediXExchange.Side.BUY_YES || side == IPrediXExchange.Side.BUY_NO) {
            IERC20(usdc).safeTransfer(orderOwner, uint256(lockedRefund));
        } else if (side == IPrediXExchange.Side.SELL_YES) {
            IERC20(mkt.yesToken).safeTransfer(orderOwner, uint256(lockedRefund));
        } else {
            IERC20(mkt.noToken).safeTransfer(orderOwner, uint256(lockedRefund));
        }
    }

    // ============ Phase A — COMPLEMENTARY matching ============

    function _tryComplementary(MatchCtx memory ctx, uint256 remaining, uint256 fillCount)
        internal
        returns (uint256, uint256)
    {
        (IPrediXExchange.Side makerSide,) = MatchMath.sidesFor(ctx.takerSide);
        uint256 bitmap = priceBitmap[ctx.marketId][makerSide];
        if (bitmap == 0) return (remaining, fillCount);

        bool takerIsBuy = MatchMath.isBuy(ctx.takerSide);
        uint8 idx = takerIsBuy ? bitmap.lowestBit() : bitmap.highestBit();

        while (remaining > 0 && fillCount < MAX_FILLS_PER_PLACE) {
            if (priceBitmap[ctx.marketId][makerSide] & (uint256(1) << idx) == 0) {
                if (takerIsBuy) {
                    if (idx >= MAX_PRICE_INDEX) break;
                    idx++;
                } else {
                    if (idx == 0) break;
                    idx--;
                }
                continue;
            }

            uint256 makerPrice = _indexToPrice(idx);
            if (takerIsBuy && makerPrice > ctx.takerPrice) break;
            if (!takerIsBuy && makerPrice < ctx.takerPrice) break;

            (remaining, fillCount) = _matchCompAtTick(ctx, makerSide, idx, makerPrice, takerIsBuy, remaining, fillCount);

            if (takerIsBuy) {
                if (idx >= MAX_PRICE_INDEX) break;
                idx++;
            } else {
                if (idx == 0) break;
                idx--;
            }
        }
        return (remaining, fillCount);
    }

    function _matchCompAtTick(
        MatchCtx memory ctx,
        IPrediXExchange.Side makerSide,
        uint8 priceIdx,
        uint256 makerPrice,
        bool takerIsBuy,
        uint256 remaining,
        uint256 fillCount
    ) internal returns (uint256 newRemaining, uint256 newFillCount) {
        IPrediXExchange.Order storage taker = orders[ctx.takerId];
        bytes32[] storage queue = _orderQueue[ctx.marketId][makerSide][priceIdx];
        newRemaining = remaining;
        newFillCount = fillCount;

        uint256 i;
        while (i < queue.length && newRemaining > 0 && newFillCount < MAX_FILLS_PER_PLACE) {
            bytes32 makerOrderId = queue[i];
            IPrediXExchange.Order storage maker = orders[makerOrderId];
            if (maker.cancelled || maker.filled >= maker.amount) {
                _removeFromQueue(ctx.marketId, makerSide, priceIdx, makerOrderId);
                continue; // queue length changed; re-read at index `i`
            }
            if (maker.owner == taker.owner) {
                i++;
                continue;
            }

            uint256 makerRemaining = maker.amount - maker.filled;
            uint256 fillAmt = newRemaining < makerRemaining ? newRemaining : makerRemaining;

            // E-01 dust filter: if `fillAmt * makerPrice` floors to 0, executing
            // this fill would transfer tokens on one leg for 0 USDC consideration
            // — a silent wealth transfer. Mirrors TakerPath L200 guard. Skip the
            // maker atomically without ANY state mutation so `cost` / `filled`
            // stay accurate and the phase-A loop advances cleanly.
            uint256 usdcAmt = (fillAmt * makerPrice) / PRICE_PRECISION;
            if (usdcAmt == 0) {
                i++;
                continue;
            }

            // Effects on both order ledgers BEFORE any external transfer (CEI).
            // Drain the taker's `depositLocked` by the consumed amount as well — the
            // legacy code only mutated the maker's side, leaving the taker's field
            // stale on full / partial fills. Mirroring the decrement here keeps the
            // I1 accounting invariant clean (`balance == Σ active depositLocked + fees`).
            address makerOwner = maker.owner;
            maker.filled += uint128(fillAmt);
            if (MatchMath.isBuy(makerSide)) {
                maker.depositLocked -= uint128(usdcAmt);
            } else {
                maker.depositLocked -= uint128(fillAmt);
            }
            if (MatchMath.isBuy(ctx.takerSide)) {
                taker.depositLocked -= uint128(usdcAmt);
            } else {
                taker.depositLocked -= uint128(fillAmt);
            }
            bool makerFullyFilled = maker.filled >= maker.amount;

            // Interactions.
            _executeComplementaryFill(maker.side, fillAmt, usdcAmt, makerOwner, taker.owner, ctx.yesToken, ctx.noToken);

            if (takerIsBuy && ctx.takerPrice > makerPrice) {
                _refundPriceImprovement(taker, fillAmt, ctx.takerPrice, makerPrice);
            }

            newRemaining -= fillAmt;
            newFillCount++;

            emit IPrediXExchange.OrderMatched(
                makerOrderId, ctx.takerId, ctx.marketId, IPrediXExchange.MatchType.COMPLEMENTARY, fillAmt, makerPrice
            );

            if (makerFullyFilled) {
                _onMakerFullyFilled(ctx.marketId, makerSide, priceIdx, makerOrderId, makerOwner);
                // queue length shrunk; do not advance `i`
            } else {
                i++;
            }
        }
    }

    /// @dev Token movements only — maker-state effects already applied by the caller.
    function _executeComplementaryFill(
        IPrediXExchange.Side makerSide,
        uint256 fillAmt,
        uint256 usdcAmt,
        address makerOwner,
        address takerOwner,
        address yesToken,
        address noToken
    ) internal {
        if (makerSide == IPrediXExchange.Side.SELL_YES) {
            IERC20(usdc).safeTransfer(makerOwner, usdcAmt);
            IERC20(yesToken).safeTransfer(takerOwner, fillAmt);
        } else if (makerSide == IPrediXExchange.Side.BUY_YES) {
            IERC20(yesToken).safeTransfer(makerOwner, fillAmt);
            IERC20(usdc).safeTransfer(takerOwner, usdcAmt);
        } else if (makerSide == IPrediXExchange.Side.SELL_NO) {
            IERC20(usdc).safeTransfer(makerOwner, usdcAmt);
            IERC20(noToken).safeTransfer(takerOwner, fillAmt);
        } else {
            // BUY_NO
            IERC20(noToken).safeTransfer(makerOwner, fillAmt);
            IERC20(usdc).safeTransfer(takerOwner, usdcAmt);
        }
    }

    // ============ Phase B — synthetic MINT (taker is BUY) ============

    function _tryMint(MatchCtx memory ctx, uint256 remaining, uint256 fillCount) internal returns (uint256, uint256) {
        IPrediXExchange.Side makerSide =
            ctx.takerSide == IPrediXExchange.Side.BUY_YES ? IPrediXExchange.Side.BUY_NO : IPrediXExchange.Side.BUY_YES;
        uint256 complementPrice = PRICE_PRECISION - ctx.takerPrice;

        uint256 bitmap = priceBitmap[ctx.marketId][makerSide];
        if (bitmap == 0) return (remaining, fillCount);

        uint8 idx = bitmap.highestBit();
        uint8 minIdx = complementPrice >= PRICE_TICK ? _priceToIndex(complementPrice) : 0;

        while (remaining > 0 && fillCount < MAX_FILLS_PER_PLACE) {
            if (idx < minIdx) break;
            if (priceBitmap[ctx.marketId][makerSide] & (uint256(1) << idx) == 0) {
                if (idx == 0) break;
                idx--;
                continue;
            }

            uint256 makerPrice = _indexToPrice(idx);
            if (ctx.takerPrice + makerPrice < PRICE_PRECISION) break;

            (remaining, fillCount) = _matchMintAtTick(ctx, makerSide, idx, makerPrice, remaining, fillCount);

            if (idx == 0) break;
            idx--;
        }
        return (remaining, fillCount);
    }

    function _matchMintAtTick(
        MatchCtx memory ctx,
        IPrediXExchange.Side makerSide,
        uint8 priceIdx,
        uint256 makerPrice,
        uint256 remaining,
        uint256 fillCount
    ) internal returns (uint256 newRemaining, uint256 newFillCount) {
        IPrediXExchange.Order storage taker = orders[ctx.takerId];
        bytes32[] storage queue = _orderQueue[ctx.marketId][makerSide][priceIdx];
        newRemaining = remaining;
        newFillCount = fillCount;

        uint256 i;
        while (i < queue.length && newRemaining > 0 && newFillCount < MAX_FILLS_PER_PLACE) {
            bytes32 makerOrderId = queue[i];
            IPrediXExchange.Order storage maker = orders[makerOrderId];
            if (maker.cancelled || maker.filled >= maker.amount) {
                _removeFromQueue(ctx.marketId, makerSide, priceIdx, makerOrderId);
                continue;
            }
            if (maker.owner == taker.owner) {
                i++;
                continue;
            }

            uint256 makerRemaining = maker.amount - maker.filled;
            uint256 fillAmt = newRemaining < makerRemaining ? newRemaining : makerRemaining;
            address makerOwner = maker.owner;

            // Dust filter (Option 4, MakerPath variant). In MakerPath MINT, both
            // `makerUsdc` and `takerUsdc` are each floored independently. The sum
            // can be up to 1 wei less than `fillAmt` when the combined prices
            // cover the mint cost only with sub-wei precision. Skipping here
            // atomically preserves the `Σ depositLocked == Exchange USDC`
            // invariant: we never execute a `splitPosition` pull that the
            // two orders' deposit decrements can't fund. Unlike TakerPath's
            // `if (makerUsdc == 0)` filter (which has a different structural
            // cause), this filter covers the double-flooring gap intrinsic to
            // computing both sides' USDC independently.
            uint256 makerUsdc = (fillAmt * makerPrice) / PRICE_PRECISION;
            uint256 takerUsdc = (fillAmt * ctx.takerPrice) / PRICE_PRECISION;
            if (makerUsdc + takerUsdc < fillAmt) {
                // Advance past this maker — same price level can't produce a
                // clean fill at the current `newRemaining`, so there is no
                // point retrying this entry.
                i++;
                continue;
            }

            // Effects: settle both sides BEFORE the diamond call.
            maker.filled += uint128(fillAmt);
            maker.depositLocked -= uint128(makerUsdc);
            taker.depositLocked -= uint128(takerUsdc);
            bool makerFullyFilled = maker.filled >= maker.amount;

            // Interactions. Pass the strictly-decremented deposit sum so the
            // helper computes `surplus = depositSum - splitAmt` with the same
            // flooring the two-order ledger just applied. Using a re-floored
            // `(fillAmt * (takerPrice + makerPrice)) / 1e6` instead would
            // over-pay `feeRecipient` by 1 wei on misaligned partial fills.
            _executeMintFill(taker, maker, fillAmt, makerUsdc + takerUsdc, ctx.yesToken, ctx.noToken);

            newRemaining -= fillAmt;
            newFillCount++;

            emit IPrediXExchange.OrderMatched(
                makerOrderId, ctx.takerId, ctx.marketId, IPrediXExchange.MatchType.MINT, fillAmt, makerPrice
            );

            if (makerFullyFilled) {
                _onMakerFullyFilled(ctx.marketId, makerSide, priceIdx, makerOrderId, makerOwner);
            } else {
                i++;
            }
        }
    }

    /// @dev Both orders are BUY. Combined USDC funds `splitPosition`; surplus
    ///      = (decremented deposit sum) - `splitAmt` flows to `feeRecipient`.
    ///
    ///      `depositSum` is the already-floored `makerUsdc + takerUsdc` from the
    ///      caller — using it here (instead of re-computing from prices) keeps
    ///      the surplus exactly consistent with what the two orders' ledgers
    ///      just lost, avoiding a 1-wei under-collateralization that occurs
    ///      when `floor((a+b)/c)` differs from `floor(a/c) + floor(b/c)`.
    function _executeMintFill(
        IPrediXExchange.Order storage taker,
        IPrediXExchange.Order storage maker,
        uint256 fillAmt,
        uint256 depositSum,
        address yesToken,
        address noToken
    ) internal {
        uint256 usdcAvailable = IERC20(usdc).balanceOf(address(this));
        if (usdcAvailable < fillAmt) revert IPrediXExchange.Exchange_InsufficientBalanceForMint();

        IMarketFacet(diamond).splitPosition(taker.marketId, fillAmt);

        bool takerIsBuyYes = taker.side == IPrediXExchange.Side.BUY_YES;
        address yesBuyer = takerIsBuyYes ? taker.owner : maker.owner;
        address noBuyer = takerIsBuyYes ? maker.owner : taker.owner;

        IERC20(yesToken).safeTransfer(yesBuyer, fillAmt);
        IERC20(noToken).safeTransfer(noBuyer, fillAmt);

        if (depositSum > fillAmt) {
            uint256 surplus = depositSum - fillAmt;
            IERC20(usdc).safeTransfer(feeRecipient, surplus);
            emit IPrediXExchange.FeeCollected(taker.marketId, surplus);
        }
    }

    // ============ Phase B — synthetic MERGE (taker is SELL) ============

    function _tryMerge(MatchCtx memory ctx, uint256 remaining, uint256 fillCount) internal returns (uint256, uint256) {
        IPrediXExchange.Side makerSide = ctx.takerSide == IPrediXExchange.Side.SELL_YES
            ? IPrediXExchange.Side.SELL_NO
            : IPrediXExchange.Side.SELL_YES;
        uint256 complementPrice = PRICE_PRECISION - ctx.takerPrice;

        uint256 bitmap = priceBitmap[ctx.marketId][makerSide];
        if (bitmap == 0) return (remaining, fillCount);

        uint8 idx = bitmap.lowestBit();
        uint8 maxIdx = _priceToIndex(complementPrice);

        while (remaining > 0 && fillCount < MAX_FILLS_PER_PLACE) {
            if (idx > maxIdx) break;
            if (priceBitmap[ctx.marketId][makerSide] & (uint256(1) << idx) == 0) {
                if (idx >= MAX_PRICE_INDEX) break;
                idx++;
                continue;
            }

            uint256 makerPrice = _indexToPrice(idx);
            if (ctx.takerPrice + makerPrice > PRICE_PRECISION) break;

            (remaining, fillCount) = _matchMergeAtTick(ctx, makerSide, idx, makerPrice, remaining, fillCount);

            if (idx >= MAX_PRICE_INDEX) break;
            idx++;
        }
        return (remaining, fillCount);
    }

    function _matchMergeAtTick(
        MatchCtx memory ctx,
        IPrediXExchange.Side makerSide,
        uint8 priceIdx,
        uint256 makerPrice,
        uint256 remaining,
        uint256 fillCount
    ) internal returns (uint256 newRemaining, uint256 newFillCount) {
        IPrediXExchange.Order storage taker = orders[ctx.takerId];
        bytes32[] storage queue = _orderQueue[ctx.marketId][makerSide][priceIdx];
        newRemaining = remaining;
        newFillCount = fillCount;

        uint256 i;
        while (i < queue.length && newRemaining > 0 && newFillCount < MAX_FILLS_PER_PLACE) {
            bytes32 makerOrderId = queue[i];
            IPrediXExchange.Order storage maker = orders[makerOrderId];
            if (maker.cancelled || maker.filled >= maker.amount) {
                _removeFromQueue(ctx.marketId, makerSide, priceIdx, makerOrderId);
                continue;
            }
            if (maker.owner == taker.owner) {
                i++;
                continue;
            }

            uint256 makerRemaining = maker.amount - maker.filled;
            uint256 fillAmt = newRemaining < makerRemaining ? newRemaining : makerRemaining;
            address makerOwner = maker.owner;

            // Effects: token deposits consumed by the merge.
            maker.filled += uint128(fillAmt);
            maker.depositLocked -= uint128(fillAmt); // SELL maker → tokens
            taker.depositLocked -= uint128(fillAmt); // SELL taker → tokens
            bool makerFullyFilled = maker.filled >= maker.amount;

            // Interactions.
            _executeMergeFill(taker, maker, fillAmt, ctx.takerPrice, makerPrice);

            newRemaining -= fillAmt;
            newFillCount++;

            emit IPrediXExchange.OrderMatched(
                makerOrderId, ctx.takerId, ctx.marketId, IPrediXExchange.MatchType.MERGE, fillAmt, makerPrice
            );

            if (makerFullyFilled) {
                _onMakerFullyFilled(ctx.marketId, makerSide, priceIdx, makerOrderId, makerOwner);
            } else {
                i++;
            }
        }
    }

    /// @dev Both orders are SELL. Diamond burns YES+NO and returns `fillAmt` USDC.
    ///      BACKLOG 2026-04-21 fix: taker receives the price improvement
    ///      (`fillAmt - makerPayout`) rather than its own limit; maker always
    ///      gets its limit. Surplus = 0 by construction — no `FeeCollected`
    ///      emit in the MERGE path. Aligns with the taker-path synthetic fill
    ///      (`_executeSyntheticTakerFill`), with the preview
    ///      (`_previewFillMarketOrder` synthetic branch in `Views.sol`), and
    ///      with industry CLOB price-improvement convention (Polymarket /
    ///      Kalshi / Binance / dYdX all pass improvement to the taker).
    ///      `_tryMerge` enforces `takerPrice + makerPrice ≤ PRICE_PRECISION`,
    ///      so `makerPayout ≤ fillAmt` and `takerPayout ≥ takerLimit` hold by
    ///      construction; both are re-asserted with custom-error reverts
    ///      below for defense-in-depth.
    function _executeMergeFill(
        IPrediXExchange.Order storage taker,
        IPrediXExchange.Order storage maker,
        uint256 fillAmt,
        uint256 takerPrice,
        uint256 makerPrice
    ) internal {
        IMarketFacet(diamond).mergePositions(taker.marketId, fillAmt);

        // GAP-C: shared rounding with preview + taker path. `outDelta` is the
        // taker's USDC share (= `fillAmt - makerShare`) by construction.
        (, uint256 takerPayout) = MatchMath.computeFillDeltas(makerPrice, fillAmt, false, true);
        uint256 makerPayout = fillAmt - takerPayout;

        // Sanity: taker receives at least its limit price. `_tryMerge`'s
        // invariant implies this; the assert protects against a future caller
        // that skips the invariant check.
        uint256 takerLimit = (fillAmt * takerPrice) / PRICE_PRECISION;
        if (takerPayout < takerLimit) revert IPrediXExchange.InsufficientLiquidity();

        IERC20(usdc).safeTransfer(taker.owner, takerPayout);
        IERC20(usdc).safeTransfer(maker.owner, makerPayout);
    }

    // ============ Helpers ============

    function _validatePrice(uint256 price) internal pure {
        if (price == 0 || price >= PRICE_PRECISION || price % PRICE_TICK != 0) {
            revert IPrediXExchange.InvalidPrice(price);
        }
    }

    /// @dev M4 bound check enforced here on the computed `depositLocked`.
    function _collectDeposit(
        IPrediXExchange.Side side,
        uint256 price,
        uint256 amount,
        address yesToken,
        address noToken
    ) internal returns (uint256 depositRequired) {
        if (side == IPrediXExchange.Side.BUY_YES || side == IPrediXExchange.Side.BUY_NO) {
            depositRequired = (amount * price) / PRICE_PRECISION;
            if (depositRequired == 0) revert IPrediXExchange.InvalidAmount();
            IERC20(usdc).safeTransferFrom(msg.sender, address(this), depositRequired);
        } else if (side == IPrediXExchange.Side.SELL_YES) {
            depositRequired = amount;
            IERC20(yesToken).safeTransferFrom(msg.sender, address(this), amount);
        } else {
            depositRequired = amount;
            IERC20(noToken).safeTransferFrom(msg.sender, address(this), amount);
        }
        if (depositRequired > type(uint128).max) revert IPrediXExchange.InvalidAmount(); // M4
    }

    /// @dev Phase-A complementary BUY fills at a maker price below the taker's limit
    ///      get a per-share USDC refund equal to `(takerPrice - makerPrice) * fillAmt`.
    function _refundPriceImprovement(
        IPrediXExchange.Order storage taker,
        uint256 fillAmt,
        uint256 takerPrice,
        uint256 makerPrice
    ) internal {
        uint256 takerCost = (fillAmt * takerPrice) / PRICE_PRECISION;
        uint256 actualCost = (fillAmt * makerPrice) / PRICE_PRECISION;
        uint256 improvement = takerCost - actualCost;
        if (improvement > 0) {
            taker.depositLocked -= uint128(improvement);
            IERC20(usdc).safeTransfer(taker.owner, improvement);
        }
    }
}
