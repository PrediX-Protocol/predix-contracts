// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {IMarketFacet} from "@predix/shared/interfaces/IMarketFacet.sol";
import {IPausableFacet} from "@predix/shared/interfaces/IPausableFacet.sol";
import {Modules} from "@predix/shared/constants/Modules.sol";

import {IBuilderRegistry} from "@predix/shared/interfaces/IBuilderRegistry.sol";
import {IPrediXExchange} from "./IPrediXExchange.sol";
import {PriceBitmap} from "./libraries/PriceBitmap.sol";
import {MatchMath} from "./libraries/MatchMath.sol";
import {LibBuilderFeeStorage} from "./libraries/LibBuilderFeeStorage.sol";
import {LibProtocolFeeStorage} from "./libraries/LibProtocolFeeStorage.sol";

/// @title ExchangeStorage
/// @notice Shared storage layout + constants + storage-adjacent helpers
///         + market-validity helpers used by both maker and taker paths.
/// @dev All mixins inherit this. Storage layout is append-only — NEVER reorder
///      or remove existing slots once the proxy is live.
///      Proxy upgrade model: `PrediXExchangeProxy` (ERC-1967 style) delegates
///      all calls to the Exchange implementation. State lives in the proxy's
///      storage; immutables have been converted to regular storage slots so
///      the proxy pattern works correctly under delegatecall.
abstract contract ExchangeStorage {
    using PriceBitmap for uint256;
    using SafeERC20 for IERC20;

    // ======== Storage (slots 0..N, proxy-delegated) ========

    /// @notice Diamond proxy address. Set once via `initialize`. All market-state
    ///         reads and split/merge calls go through this address.
    address public diamond;

    /// @notice USDC collateral token address. Set once via `initialize`.
    address public usdc;

    /// @notice Protocol fee recipient. Mutable via `setFeeRecipient` so the
    ///         protocol can redirect fees to a FeeController without redeploying.
    address public feeRecipient;

    /// @notice Initializer guard. `true` after `initialize` runs (or in the
    ///         bare impl constructor for defense-in-depth).
    bool internal _initialized;

    // ======== Constants ========

    uint256 internal constant PRICE_PRECISION = 1e6;
    uint256 internal constant PRICE_TICK = 10_000;
    uint8 internal constant MAX_PRICE_INDEX = 98;
    uint256 internal constant MIN_ORDER_AMOUNT = 1e6;
    uint256 internal constant MAX_ORDERS_PER_USER = 50;
    uint256 internal constant DEFAULT_MAX_FILLS = 10;
    uint8 internal constant MAX_FILLS_PER_PLACE = 20;
    uint256 internal constant MAX_QUEUE_DEPTH_PER_PRICE = 200;
    uint256 internal constant MAX_BATCH_CANCEL = 50;

    uint256 internal constant BPS_DENOMINATOR = 10_000;
    /// @dev 1e16 = BPS_DENOMINATOR(1e4) * PRICE_PRECISION(1e6) * PRICE_PRECISION(1e6)
    uint256 internal constant CURVE_DENOMINATOR = 1e16;

    // ======== Internal enums ========

    /// @dev Implementation detail — not exposed in IPrediXExchange.
    enum FillSource {
        NONE,
        COMPLEMENTARY,
        SYNTHETIC
    }

    // ======== Storage (continued) ========

    /// @notice All orders indexed by orderId.
    mapping(bytes32 orderId => IPrediXExchange.Order) public orders;

    /// @notice FIFO queue of orderIds at each (market, side, priceIdx).
    mapping(uint256 marketId => mapping(IPrediXExchange.Side => mapping(uint8 priceIdx => bytes32[]))) internal
        _orderQueue;

    /// @notice Bitmap of populated price indices per (market, side).
    /// @dev Bit i set ⇔ price level (i+1)*PRICE_TICK has at least one live order.
    mapping(uint256 marketId => mapping(IPrediXExchange.Side => uint256)) public priceBitmap;

    /// @notice Number of live orders a user has in a given market (for MAX_ORDERS_PER_USER cap).
    mapping(uint256 marketId => mapping(address user => uint256)) public userOrderCount;

    /// @notice Monotonic nonce for orderId derivation.
    uint256 internal _orderNonce;

    // ======== Storage-adjacent helpers ========

    /// @notice Map a tick-aligned price to its bitmap index.
    /// @dev Caller is responsible for tick alignment / range — this is internal-only.
    function _priceToIndex(uint256 price) internal pure returns (uint8) {
        return uint8(price / PRICE_TICK - 1);
    }

    /// @notice Inverse of `_priceToIndex`.
    function _indexToPrice(uint8 idx) internal pure returns (uint256) {
        return uint256(idx + 1) * PRICE_TICK;
    }

    /// @notice Decrement `userOrderCount` for `user` in `marketId`.
    /// @dev Must be called whenever a maker order becomes fully filled (in either
    ///      path) and on cancel. Reverts on underflow — a zero count here signals
    ///      a bookkeeping bug that must be surfaced, not silently absorbed.
    function _decrementOrderCount(uint256 marketId, address user) internal {
        uint256 count = userOrderCount[marketId][user];
        if (count == 0) revert IPrediXExchange.OrderNotFound();
        userOrderCount[marketId][user] = count - 1;
    }

    /// @notice Remove `orderId` from its FIFO queue and clear the bitmap bit if the queue
    ///         becomes empty.
    /// @dev Shift-and-pop: shifts all entries after the removed one left by one
    ///      position, then pops the tail. Preserves FIFO ordering and keeps the
    ///      same caller semantic as the old swap-and-pop (queue shrinks by 1, the
    ///      entry at the removed index now holds the next element).
    function _removeFromQueue(uint256 marketId, IPrediXExchange.Side side, uint8 priceIdx, bytes32 orderId) internal {
        bytes32[] storage queue = _orderQueue[marketId][side][priceIdx];
        uint256 len = queue.length;
        for (uint256 i; i < len; ++i) {
            if (queue[i] == orderId) {
                for (uint256 j = i; j < len - 1; ++j) {
                    queue[j] = queue[j + 1];
                }
                queue.pop();
                break;
            }
        }
        if (queue.length == 0) {
            priceBitmap[marketId][side] = priceBitmap[marketId][side].clear(priceIdx);
        }
    }

    /// @notice Single cleanup hook for "this maker order just reached a terminal state".
    /// @dev Releases the per-user slot AND swap-pops the queue (clearing the bitmap bit
    ///      if the queue empties). Called from both taker execution helpers and maker-vs-
    ///      maker matching helpers, so the discipline lives in one place.
    ///
    ///      Also sweeps any residual `depositLocked` dust on BUY orders to
    ///      `feeRecipient`. BUY initial deposit is a single-floored `(amount * price)
    ///      / 1e6`, while per-fill consumption uses per-fill floors — their sum can
    ///      be 1 wei less than the initial, leaving phantom USDC in storage when
    ///      the order goes terminal. Sweeping at this central site keeps the strict
    ///      `balance == Σ active depositLocked` invariant intact across all paths.
    ///      SELL orders have no residual (deposit and decrements are exact integers).
    function _onMakerFullyFilled(
        uint256 marketId,
        IPrediXExchange.Side side,
        uint8 priceIdx,
        bytes32 orderId,
        address owner_
    ) internal {
        IPrediXExchange.Order storage ord = orders[orderId];
        if (side == IPrediXExchange.Side.BUY_YES || side == IPrediXExchange.Side.BUY_NO) {
            uint128 residual = ord.depositLocked;
            if (residual > 0) {
                ord.depositLocked = 0;
                IERC20(usdc).safeTransfer(feeRecipient, uint256(residual));
                emit IPrediXExchange.FeeCollected(marketId, uint256(residual));
            }
        }
        // Refund SITE-1: return any unused prefunded fee budgets to the order owner. Dust force-clean flows
        // through here too (`_forceCleanDustMaker` → `_onMakerFullyFilled`), so do NOT refund again there.
        _refundOrderFeeBudgets(orderId, owner_);
        _decrementOrderCount(marketId, owner_);
        _removeFromQueue(marketId, side, priceIdx, orderId);
    }

    // ======== Market-view helpers ========

    /// @notice Read `getMarket` once and translate the diamond's `Market_NotFound`
    ///         into Exchange's own `MarketNotFound` so the public error surface is
    ///         self-contained. Other failure modes bubble up unchanged.
    function _loadMarket(uint256 marketId) internal view returns (IMarketFacet.MarketView memory mkt) {
        try IMarketFacet(diamond).getMarket(marketId) returns (IMarketFacet.MarketView memory m) {
            mkt = m;
        } catch (bytes memory data) {
            if (data.length >= 4 && bytes4(data) == IMarketFacet.Market_NotFound.selector) {
                revert IPrediXExchange.MarketNotFound();
            }
            // Bubble up any other revert verbatim (standard pattern).
            assembly ("memory-safe") {
                revert(add(data, 0x20), mload(data))
            }
        }
    }

    /// @notice 4-check market gating on the cached `MarketView` (no extra external call).
    ///         Used by both maker (`_placeOrder`) and taker (`_fillMarketOrder`) entry points.
    function _validateMarketActive(IMarketFacet.MarketView memory mkt) internal view {
        if (block.timestamp >= mkt.endTime) revert IPrediXExchange.MarketExpired();
        if (mkt.isResolved) revert IPrediXExchange.MarketResolved();
        if (mkt.refundModeActive) revert IPrediXExchange.MarketInRefundMode();
        if (IPausableFacet(diamond).isModulePaused(Modules.MARKET)) revert IPrediXExchange.MarketPaused();
    }

    /// @notice Whether `marketId` has reached a terminal state (resolved, in refund
    ///         mode, or past its end time) — the point past which a resting order can
    ///         no longer be filled. Lets the batch-cancel keeper path return resting
    ///         escrow to owners. Mirrors the inline guard in `MakerPath._cancelOrder`.
    function _isMarketTerminal(uint256 marketId) internal view returns (bool) {
        IMarketFacet.MarketView memory mkt = _loadMarket(marketId);
        return mkt.isResolved || mkt.refundModeActive || block.timestamp >= mkt.endTime;
    }

    // ======== Synthetic MINT approval (scoped) ========

    /// @dev Grant the diamond an EXACT, single-use USDC allowance for the very
    ///      next `splitPosition` on the synthetic MINT path. The split's
    ///      `transferFrom(exchange, ..., amount)` consumes the allowance straight
    ///      back to zero, so the exchange never carries a standing allowance that
    ///      a malicious diamond upgrade could use to pull idle CLOB deposits.
    ///      Callers MUST invoke this immediately before `splitPosition` with the
    ///      same amount.
    function _approveSplit(uint256 amount) internal {
        IERC20(usdc).forceApprove(diamond, amount);
    }

    // ======== Dust force-clean ========

    /// @dev Force-clean a dust maker order whose remaining capacity is too small
    ///      to produce a non-zero fill at its own price level (i.e.
    ///      `(amount - filled) * price / 1e6 == 0`). Marks the order
    ///      fully-filled, drops it from the queue/bitmap via
    ///      `_onMakerFullyFilled`, and sweeps residual `depositLocked` to
    ///      `feeRecipient`. Shared by both `TakerPath` and `MakerPath` so the
    ///      orderbook never accumulates structurally unfillable entries.
    ///
    ///      `_onMakerFullyFilled` already sweeps the USDC residual on BUY
    ///      orders. For SELL orders the residual sits in `depositLocked` as
    ///      outcome-token wei; sweep it explicitly here because the BUY-only
    ///      branch of `_onMakerFullyFilled` does not cover the token leg.
    function _forceCleanDustMaker(uint256 marketId, bytes32 dustOrderId, uint256 makerPrice) internal {
        IPrediXExchange.Order storage dust = orders[dustOrderId];
        IPrediXExchange.Side dustSide = dust.side;
        address dustOwner = dust.owner;
        uint8 priceIdx = _priceToIndex(makerPrice);
        dust.filled = uint128(dust.amount);
        if (dustSide == IPrediXExchange.Side.SELL_YES || dustSide == IPrediXExchange.Side.SELL_NO) {
            uint128 tokenResidual = dust.depositLocked;
            if (tokenResidual > 0) {
                dust.depositLocked = 0;
                address tokenAddr =
                    dustSide == IPrediXExchange.Side.SELL_YES ? _yesTokenFor(marketId) : _noTokenFor(marketId);
                IERC20(tokenAddr).safeTransfer(feeRecipient, uint256(tokenResidual));
                emit IPrediXExchange.FeeCollected(marketId, uint256(tokenResidual));
            }
        }
        _onMakerFullyFilled(marketId, dustSide, priceIdx, dustOrderId, dustOwner);
    }

    function _yesTokenFor(uint256 marketId) internal view returns (address) {
        return IMarketFacet(diamond).getMarket(marketId).yesToken;
    }

    function _noTokenFor(uint256 marketId) internal view returns (address) {
        return IMarketFacet(diamond).getMarket(marketId).noToken;
    }

    // ======== Fee helpers (functions only — NO new state) ========

    /// @notice Flat fee = notional * bps / 10_000 (floor).
    function _feeOn(uint256 notional, uint16 bps) internal pure returns (uint256) {
        return (notional * uint256(bps)) / BPS_DENOMINATOR;
    }

    /// @notice Protocol-fee curve = fillShares * feeCoefBps * p * (1e6 - p) / 1e16.
    /// @dev `p` is the traded side's own fill price (PRICE_PRECISION). Floors to 0 on
    ///      dust (MatchMath (0,0) convention) — caller must not revert. Worst product
    ///      fillShares(<=uint128) * 700 * 1e6 * 1e6 ~= 2^176 << 2^256, plain mul-div safe.
    function _curveFee(uint256 fillShares, uint16 feeCoefBps, uint256 p) internal pure returns (uint256) {
        return (fillShares * uint256(feeCoefBps) * p * (PRICE_PRECISION - p)) / CURVE_DENOMINATOR;
    }

    /// @notice (takerBps, makerBps) for a builder code. (0,0) if no registry / zero code / unregistered.
    function _builderBps(bytes32 code) internal view returns (uint16 takerBps, uint16 makerBps) {
        if (code == bytes32(0)) return (0, 0);
        address reg = LibBuilderFeeStorage.layout().builderRegistry;
        if (reg == address(0)) return (0, 0);
        (takerBps, makerBps,) = IBuilderRegistry(reg).feeOf(code);
    }

    /// @notice Maker builder-bps snapshot for an order (0 if unset). Snapshotted at placeOrder (Task 8);
    ///         read by the taker/maker fill sites to charge the resting maker's builder fee.
    function _orderMakerBps(bytes32 orderId) internal view returns (uint16) {
        return LibBuilderFeeStorage.layout().orderMakerBps[orderId];
    }

    /// @notice Credit `amount` USDC of builder fee to `code`'s accrual ledger. No-op on zero.
    function _accrueBuilderFee(bytes32 code, uint256 amount) internal {
        if (amount == 0 || code == bytes32(0)) return;
        LibBuilderFeeStorage.layout().accrued[code] += amount;
        emit IPrediXExchange.BuilderFeeAccrued(code, amount);
    }

    /// @notice Charge an additive (prefunded) builder fee against an order's locked budget.
    ///         Caps at the remaining budget so a post-placement rate rise cannot overdraw.
    function _takeLockedFee(bytes32 orderId, uint256 notional, uint16 bps) internal returns (uint256 fee) {
        fee = _feeOn(notional, bps);
        uint256 locked = LibBuilderFeeStorage.layout().makerFeeLocked[orderId];
        if (fee > locked) fee = locked;
        LibBuilderFeeStorage.layout().makerFeeLocked[orderId] = locked - fee;
    }

    /// @notice Accrue the protocol-fee treasury cut T. No-op on zero.
    function _accrueProtocol(uint256 amount) internal {
        if (amount == 0) return;
        LibProtocolFeeStorage.layout().accruedProtocolFee += amount;
    }

    /// @notice Charge an additive protocol fee against a BUY placer's reserve. Caps at
    ///         the remaining budget (the marginal-clamp also bounds it, this is defense-in-depth).
    function _takeProtocolBudget(bytes32 orderId, uint256 amount) internal returns (uint256 spent) {
        spent = amount;
        uint256 budget = LibProtocolFeeStorage.layout().placerProtocolFeeBudget[orderId];
        if (spent > budget) spent = budget;
        LibProtocolFeeStorage.layout().placerProtocolFeeBudget[orderId] = budget - spent;
    }

    /// @notice Record a freshly placed order's fee context: snapshot the maker builder bps (consumed when
    ///         the order later RESTS and is filled) and lock the prefunded BUY budgets the caller pulled.
    ///         The caller (`MakerPath._placeOrder`) computes + pulls the USDC; this only writes storage.
    function _prefundOrderFees(bytes32 orderId, uint16 makerBps, uint256 makerFeeLockedAmt, uint256 protocolBudget)
        internal
    {
        if (makerBps > 0) LibBuilderFeeStorage.layout().orderMakerBps[orderId] = makerBps;
        if (makerFeeLockedAmt > 0) LibBuilderFeeStorage.layout().makerFeeLocked[orderId] = makerFeeLockedAmt;
        if (protocolBudget > 0) LibProtocolFeeStorage.layout().placerProtocolFeeBudget[orderId] = protocolBudget;
    }

    /// @notice Refund any unused prefunded fee budgets (builder `makerFeeLocked` + placer protocol reserve)
    ///         for `orderId` to `to`. Zeroes BEFORE transfer (CEI). Shared by the 3 refund sites (cancel /
    ///         fully-filled / placer-fully-consumed) so a placer/maker never loses its own unused prefund.
    function _refundOrderFeeBudgets(bytes32 orderId, address to) internal {
        uint256 feeResidual = LibBuilderFeeStorage.layout().makerFeeLocked[orderId];
        if (feeResidual > 0) {
            LibBuilderFeeStorage.layout().makerFeeLocked[orderId] = 0;
            IERC20(usdc).safeTransfer(to, feeResidual);
        }
        uint256 protoResidual = LibProtocolFeeStorage.layout().placerProtocolFeeBudget[orderId];
        if (protoResidual > 0) {
            LibProtocolFeeStorage.layout().placerProtocolFeeBudget[orderId] = 0;
            IERC20(usdc).safeTransfer(to, protoResidual);
        }
    }

    // ======== Marginal BUY clamp (§13.1 / REVIEW_FIXES F3-1) — shared by TakerPath (execute) + Views (preview) ========

    /// @notice EXACT total USDC cost (notional + protocol fee + taker builder fee) of buying `s` shares
    ///         against a maker at `makerPrice`. `inDelta` is read from `MatchMath.computeFillDeltas` — the SAME
    ///         function the execute path charges — so the clamp basis is byte-identical to the executed cost
    ///         for BOTH COMPLEMENTARY (`inDelta = floor(s*makerPrice/1e6)`) and SYNTHETIC MINT
    ///         (`inDelta = s - floor(s*makerPrice/1e6)`, NOT `floor(s*(1e6-makerPrice)/1e6)` — those differ by
    ///         up to 1 wei and a naive `pEff` basis under-charges → overspend revert). Curve `p` = the taker's
    ///         traded-side price (COMP `makerPrice`; SYN `1e6-makerPrice`). `takerBps`=0 on the router/preview path.
    function _fillTotalCost(uint256 s, uint256 makerPrice, bool isSynthetic, uint16 coefBps, uint16 takerBps)
        internal
        pure
        returns (uint256)
    {
        (uint256 inDelta,) = MatchMath.computeFillDeltas(makerPrice, s, true, isSynthetic);
        uint256 pCurve = isSynthetic ? (PRICE_PRECISION - makerPrice) : makerPrice;
        return inDelta + _curveFee(s, coefBps, pCurve) + _feeOn(inDelta, takerBps);
    }

    /// @notice Clamp a budget-bound BUY fill so notional + protocol + builder fee fits `remaining` (USDC).
    /// @dev Monotone in `s`: a closed-form `pEff` estimate plus a floor-correction down to the EXACT
    ///      `_fillTotalCost`. Returns 0 when even the marginal share over-spends (caller stops the loop).
    ///      Shared so the preview mirrors execute EXACTLY (else the router's `_convergeCap` diverges, §13.1).
    function _clampBuyFill(
        uint256 fillAmount,
        uint256 makerPrice,
        FillSource source,
        uint16 coefBps,
        uint16 takerBps,
        uint256 remaining
    ) internal pure returns (uint256) {
        bool isSyn = source != FillSource.COMPLEMENTARY;
        if (_fillTotalCost(fillAmount, makerPrice, isSyn, coefBps, takerBps) <= remaining) {
            return fillAmount;
        }
        uint256 pEff = isSyn ? (PRICE_PRECISION - makerPrice) : makerPrice;
        uint256 denom = pEff * (1e10 + uint256(takerBps) * 1e6 + uint256(coefBps) * (PRICE_PRECISION - pEff));
        uint256 s = denom == 0 ? fillAmount : (remaining * 1e16) / denom;
        if (s > fillAmount) s = fillAmount;
        while (s > 0 && _fillTotalCost(s, makerPrice, isSyn, coefBps, takerBps) > remaining) {
            --s;
        }
        return s;
    }
}
