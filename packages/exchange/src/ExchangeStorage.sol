// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {IMarketFacet} from "@predix/shared/interfaces/IMarketFacet.sol";
import {IPausableFacet} from "@predix/shared/interfaces/IPausableFacet.sol";
import {Modules} from "@predix/shared/constants/Modules.sol";

import {IPrediXExchange} from "./IPrediXExchange.sol";
import {PriceBitmap} from "./libraries/PriceBitmap.sol";

/// @title ExchangeStorage
/// @notice Shared storage layout + immutables + constants + storage-adjacent helpers
///         + market-validity helpers used by both maker and taker paths.
/// @dev All mixins inherit this. The small helpers that mutate the order book in
///      lock-step with the bitmap (`_removeFromQueue`, `_decrementOrderCount`,
///      `_onMakerFullyFilled`) and the cached-`MarketView` validators
///      (`_loadMarket`, `_validateMarketActive`) live here so both paths share one
///      implementation and the same Exchange-owned error surface.
abstract contract ExchangeStorage {
    using PriceBitmap for uint256;
    using SafeERC20 for IERC20;

    // ======== Immutables ========

    address public immutable diamond;
    address public immutable usdc;
    address public immutable feeRecipient;

    // ======== Constants ========

    uint256 internal constant PRICE_PRECISION = 1e6;
    uint256 internal constant PRICE_TICK = 10_000;
    uint8 internal constant MAX_PRICE_INDEX = 98;
    uint256 internal constant MIN_ORDER_AMOUNT = 1e6;
    uint256 internal constant MAX_ORDERS_PER_USER = 50;
    uint256 internal constant DEFAULT_MAX_FILLS = 10;
    uint8 internal constant MAX_FILLS_PER_PLACE = 20;

    // ======== Internal enums ========

    /// @dev Implementation detail — not exposed in IPrediXExchange.
    enum FillSource {
        NONE,
        COMPLEMENTARY,
        SYNTHETIC
    }

    // ======== Storage ========

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

    // ======== Constructor ========

    constructor(address _diamond, address _usdc, address _feeRecipient) {
        diamond = _diamond;
        usdc = _usdc;
        feeRecipient = _feeRecipient;
    }

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

    /// @notice Decrement `userOrderCount` for `user` in `marketId`, saturating at zero.
    /// @dev Audit H-01: must be called whenever a maker order becomes fully filled
    ///      (in either path) and on cancel.
    function _decrementOrderCount(uint256 marketId, address user) internal {
        uint256 count = userOrderCount[marketId][user];
        if (count > 0) {
            userOrderCount[marketId][user] = count - 1;
        }
    }

    /// @notice Remove `orderId` from its FIFO queue and clear the bitmap bit if the queue
    ///         becomes empty.
    /// @dev Swap-and-pop. Called whenever an order reaches a terminal state
    ///      (cancelled, fully filled) so that `_peekBest` returns on iteration 0
    ///      in the well-behaved case (CLAUDE.md "Performance claims").
    function _removeFromQueue(uint256 marketId, IPrediXExchange.Side side, uint8 priceIdx, bytes32 orderId) internal {
        bytes32[] storage queue = _orderQueue[marketId][side][priceIdx];
        uint256 len = queue.length;
        for (uint256 i; i < len; ++i) {
            if (queue[i] == orderId) {
                if (i != len - 1) {
                    queue[i] = queue[len - 1];
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
    /// @dev Audit H-01 + M5: release the per-user slot AND swap-pop the queue (clearing
    ///      the bitmap bit if the queue empties). Called from both taker execution helpers
    ///      and maker-vs-maker matching helpers, so the discipline lives in one place.
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
}
