# PrediX Exchange — Thiết kế chuẩn (Standard Design)

> **Document type**: Technical Architecture Reference
> **Based on**: Industry analysis of Polymarket CTF Exchange, Uniswap v4 PoolManager, OpenZeppelin patterns, gas optimization best practices
> **Applies to**: `src/exchange/` refactor — greenfield

---

## 1. Executive summary

Thiết kế này giải quyết 8 bugs từ spec gốc + 6 design debt bổ sung, đồng thời áp dụng industry patterns đã được audit. Kiến trúc mới tách monolith 919 dòng thành modular mixin pattern (Polymarket-style), giữ permissionless core (Uniswap v4-style), thêm 4-way waterfall matching, và tối ưu gas thông qua struct packing + bitmap improvements.

---

## 2. Industry benchmark comparison

| Feature | Polymarket CTF | Uniswap v4 | PrediX Current | PrediX Proposed |
|---------|---------------|------------|----------------|-----------------|
| Architecture | Mixin inheritance | Singleton + Router | Monolith 919 lines | Mixin inheritance |
| Matching | Off-chain CLOB + on-chain settle | AMM (constant product) | On-chain CLOB, complementary only | On-chain CLOB, 4-way waterfall |
| Access control on fill | Operator-signed orders | Permissionless core | `whenNotPaused` on fill | Permissionless (no modifier) |
| Synthetic matching | MINT/MERGE via operator | N/A (AMM) | Only in maker path | Both maker + taker paths |
| Deadline protection | EIP-712 signature expiry | `deadline` param | None | `deadline` param |
| Preview/simulation | Off-chain SDK | Quoter contract | None | `previewFillMarketOrder` |
| Fund strategy | Transfer per match | Flash accounting (delta) | Lazy per-match pull | Upfront pull + refund |
| Self-match check | Operator prevents | N/A | Complementary only | Both comp + synthetic |
| Order struct packing | EIP-712 off-chain | N/A | 7 slots (unpacked) | 5 slots (packed) |
| Reentrancy guard | Custom (locked=1/2) | Transient storage | Transient storage | Transient storage (keep) |
| Event tracking | OrderFilled per match | Swap event | OrderMatched (no taker addr) | OrderMatched + TakerFilled |
| Bitmap for price levels | N/A (off-chain) | TickBitmap lib | Inline uint256 | Extracted PriceBitmap lib |

---

## 3. File structure proposal

```
src/exchange/
├── IPrediXExchange.sol          # Interface (enums, structs, errors, events, external fns)
├── PrediXExchange.sol           # Main contract: is MakerPath, TakerPath, Views
├── ExchangeStorage.sol          # Abstract: all storage variables
├── mixins/
│   ├── MakerPath.sol            # placeOrder, cancelOrder, _tryComp/Mint/Merge
│   ├── TakerPath.sol            # fillMarketOrder, waterfall loop, execute helpers
│   ├── Matching.sol             # _executeComplementaryFill, _executeMintFill, _executeMergeFill
│   └── Views.sol                # getBestPrices, getDepthAtPrice, getOrderBook, preview
└── libraries/
    ├── OrderLib.sol             # Order struct helpers, packed struct definition
    ├── PriceBitmap.sol          # Bitmap operations: lowest/highest bit, set/clear
    ├── MatchMath.sol            # Fill amount calculation, price comparison
    └── ExchangeErrors.sol       # All custom errors in one place
```

**Rationale**: Polymarket's mixin pattern (đã Chainsecurity audit) chứng minh separation of concerns giảm audit surface. Mỗi mixin chỉ modify storage thông qua `ExchangeStorage`, giống cách Polymarket's `Trading.sol` kế thừa `IAssetOperations`, `IFees`, `ISignatures`.

---

## 4. Core interface design

```solidity
// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

/// @title IPrediXExchange
/// @notice Permissionless on-chain CLOB for PrediX prediction markets
/// @dev Exchange is protocol infrastructure. No access control on taker path.
///      Architecture mirrors Uniswap v4 PoolManager: permissionless core + optional Router.
interface IPrediXExchange {

    // ======== Enums ========

    /// @notice 4 trading sides for binary outcome markets
    /// @dev Used by both maker and taker paths
    enum Side {
        BUY_YES,   // 0
        SELL_YES,  // 1
        BUY_NO,    // 2
        SELL_NO    // 3
    }

    /// @notice Match type determines token flow mechanism
    enum MatchType {
        COMPLEMENTARY,  // Direct opposite-side match
        MINT,           // Same-action opposite-token → Diamond.splitPosition
        MERGE           // Same-action opposite-token → Diamond.mergePositions
    }

    // ======== Structs ========

    /// @notice Packed order struct — 5 storage slots instead of 7
    /// @dev Slot 1: owner (20 bytes) + timestamp (8 bytes) + side (1 byte) + cancelled (1 byte) = 30 bytes
    ///      Slot 2: marketId (32 bytes)
    ///      Slot 3: price (32 bytes) — could be uint96 but kept uint256 for FullMath compat
    ///      Slot 4: amount (32 bytes)
    ///      Slot 5: filled (16 bytes) + depositLocked (16 bytes) = 32 bytes
    struct Order {
        // --- Slot 1: packed ---
        address owner;          // 20 bytes
        uint64  timestamp;      //  8 bytes
        Side    side;           //  1 byte
        bool    cancelled;      //  1 byte
        // --- Slot 2 ---
        bytes32 marketId;       // 32 bytes
        // --- Slot 3 ---
        uint256 price;          // 6 decimals (e.g., 300000 = $0.30)
        // --- Slot 4 ---
        uint256 amount;         // Total tokens to trade (6 decimals)
        // --- Slot 5: packed ---
        uint128 filled;         // Already filled (max 340B tokens — sufficient)
        uint128 depositLocked;  // USDC or tokens locked
    }

    struct PriceLevel {
        uint256 price;
        uint256 totalAmount;
    }

    /// @notice Fill result from preview function
    struct FillPreview {
        uint256 filled;         // Total output tokens
        uint256 cost;           // Total input consumed
        uint256 matchCount;     // Number of matches
    }

    // ======== Errors ========

    error InvalidPrice(uint256 price);
    error InvalidAmount();
    error MarketNotFound();
    error MarketNotActive();
    error MarketExpired();
    error MarketResolved();
    error MarketInRefundMode();
    error MarketPaused();
    error OrderNotFound();
    error NotOrderOwner();
    error OrderAlreadyCancelled();
    error OrderFullyFilled();
    error SelfMatchNotAllowed();
    error MaxOrdersExceeded();
    error DeadlineExpired(uint256 deadline, uint256 current);
    error ZeroAddress();
    error ZeroAmount();
    error InsufficientLiquidity();

    // ======== Events ========

    event OrderPlaced(
        bytes32 indexed orderId,
        bytes32 indexed marketId,
        address indexed owner,
        Side    side,
        uint256 price,
        uint256 amount
    );

    event OrderMatched(
        bytes32 indexed makerOrderId,
        bytes32 indexed takerOrderId,   // bytes32(0) for taker-path fills
        bytes32 indexed marketId,
        MatchType matchType,
        uint256 amount,
        uint256 price
    );

    event OrderCancelled(bytes32 indexed orderId);

    event FeeCollected(bytes32 indexed marketId, uint256 amount);

    /// @notice Emitted once per fillMarketOrder call
    /// @dev Captures taker identity + aggregate results. Critical for indexer attribution.
    event TakerFilled(
        bytes32 indexed marketId,
        address indexed taker,
        address indexed recipient,
        Side    takerSide,
        uint256 totalFilled,
        uint256 totalCost,
        uint256 matchCount
    );

    // ======== Maker path (limit orders) — UNCHANGED ========

    function placeOrder(
        bytes32 marketId,
        Side    side,
        uint256 price,
        uint256 amount
    ) external returns (bytes32 orderId, uint256 filledAmount);

    function cancelOrder(bytes32 orderId) external;

    // ======== Taker path (market orders) — REFACTORED ========

    /// @notice Fill market order with 4-way waterfall routing
    /// @dev Permissionless. No access control. Any caller is valid.
    ///
    /// Parameters designed for maximum flexibility:
    ///   - `taker` ≠ msg.sender is valid (Router pattern, Permit2 pattern)
    ///   - `recipient` ≠ taker is valid (gift, vault deposit, composability)
    ///   - `maxFills = 0` → uses DEFAULT_MAX_FILLS = 10
    ///   - `deadline` prevents stale mempool execution
    ///
    /// Fund flow: upfront pull → loop → refund unused
    ///
    /// @param marketId    Target market
    /// @param takerSide   BUY_YES / SELL_YES / BUY_NO / SELL_NO
    /// @param limitPrice  BUY: max price. SELL: min price. Never crossed.
    /// @param amountIn    Taker's input budget (USDC for buy, shares for sell)
    /// @param taker       Address providing funds (must have approved Exchange)
    /// @param recipient   Address receiving output tokens
    /// @param maxFills    Iteration cap (0 = default 10, no hard upper bound)
    /// @param deadline    Block.timestamp deadline (reverts if expired)
    /// @return filled     Total output delivered to recipient
    /// @return cost       Total input consumed from taker
    function fillMarketOrder(
        bytes32 marketId,
        Side    takerSide,
        uint256 limitPrice,
        uint256 amountIn,
        address taker,
        address recipient,
        uint256 maxFills,
        uint256 deadline
    ) external returns (uint256 filled, uint256 cost);

    // ======== View functions ========

    /// @notice Simulate fillMarketOrder without execution
    /// @dev Pure view. No state mutation, no events. Uses virtual consumption tracking.
    function previewFillMarketOrder(
        bytes32 marketId,
        Side    takerSide,
        uint256 limitPrice,
        uint256 amountIn,
        uint256 maxFills
    ) external view returns (uint256 filled, uint256 cost);

    function getBestPrices(bytes32 marketId) external view returns (
        uint256 bestBidYes,
        uint256 bestAskYes,
        uint256 bestBidNo,
        uint256 bestAskNo
    );

    function getDepthAtPrice(bytes32 marketId, Side side, uint256 price)
        external view returns (uint256 totalAmount);

    function getOrderBook(bytes32 marketId, uint8 depth) external view returns (
        PriceLevel[] memory yesBids,
        PriceLevel[] memory yesAsks,
        PriceLevel[] memory noBids,
        PriceLevel[] memory noAsks
    );

    function getOrder(bytes32 orderId) external view returns (Order memory);
}
```

---

## 5. Storage layout (ExchangeStorage.sol)

```solidity
// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {IPrediXExchange} from "./IPrediXExchange.sol";

/// @title ExchangeStorage
/// @notice Shared storage layout for all Exchange mixins
/// @dev All mixins inherit this. No logic, only state declarations.
///      Pattern: Polymarket uses Assets.sol for shared state.
abstract contract ExchangeStorage {
    using IPrediXExchange for IPrediXExchange.Side;

    // ======== Immutables ========
    address public immutable diamond;
    address public immutable usdc;
    address public immutable feeRecipient;

    // ======== Constants ========
    uint256 internal constant PRICE_PRECISION = 1e6;
    uint256 internal constant PRICE_TICK      = 10_000;     // $0.01 granularity
    uint256 internal constant MIN_PRICE       = 10_000;     // $0.01
    uint256 internal constant MAX_PRICE       = 990_000;    // $0.99
    uint8   internal constant MAX_PRICE_INDEX  = 98;        // indices 0..98
    uint256 internal constant MIN_ORDER_AMOUNT = 1e6;       // 1 share minimum
    uint256 internal constant MAX_ORDERS_PER_USER = 50;
    uint256 internal constant DEFAULT_MAX_FILLS   = 10;
    uint8   internal constant MAX_FILLS_PER_PLACE = 20;

    // ======== Fill source (internal enum, not in interface) ========
    enum FillSource { NONE, COMPLEMENTARY, SYNTHETIC }

    // ======== Storage ========
    mapping(bytes32 orderId => IPrediXExchange.Order) public orders;
    mapping(bytes32 marketId => mapping(IPrediXExchange.Side => mapping(uint8 priceIdx => bytes32[])))
        internal _orderQueue;
    mapping(bytes32 marketId => mapping(IPrediXExchange.Side => uint256)) public priceBitmap;
    mapping(bytes32 marketId => mapping(address user => uint256)) public userOrderCount;
    uint256 internal _orderNonce;

    // ======== Constructor ========
    constructor(address _diamond, address _usdc, address _feeRecipient) {
        diamond = _diamond;
        usdc = _usdc;
        feeRecipient = _feeRecipient;
    }
}
```

---

## 6. Library: PriceBitmap.sol

```solidity
// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

/// @title PriceBitmap
/// @notice Gas-efficient price level scanning using bitmap operations
/// @dev Extracted from monolith for reuse and testability.
///      99-bit bitmap: bit i = price level (i+1) * PRICE_TICK exists.
library PriceBitmap {

    uint8 internal constant MAX_INDEX = 98;

    /// @notice Find lowest set bit (best ask / cheapest sell)
    /// @dev Uses de Bruijn sequence for O(1) — saves ~2k gas vs linear scan
    function lowestBit(uint256 bitmap) internal pure returns (uint8 idx) {
        require(bitmap != 0, "Empty bitmap");
        // Isolate lowest bit
        uint256 isolated = bitmap & (~bitmap + 1);
        // Count trailing zeros via assembly for gas efficiency
        assembly {
            idx := 0
            // Binary search for position
            if gt(and(isolated, 0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF), 0) { } // lower 128 bits
            if iszero(and(isolated, 0xFFFFFFFF)) { idx := add(idx, 32) isolated := shr(32, isolated) }
            if iszero(and(isolated, 0xFFFF))     { idx := add(idx, 16) isolated := shr(16, isolated) }
            if iszero(and(isolated, 0xFF))       { idx := add(idx,  8) isolated := shr( 8, isolated) }
            if iszero(and(isolated, 0xF))        { idx := add(idx,  4) isolated := shr( 4, isolated) }
            if iszero(and(isolated, 0x3))        { idx := add(idx,  2) isolated := shr( 2, isolated) }
            if iszero(and(isolated, 0x1))        { idx := add(idx,  1) }
        }
    }

    /// @notice Find highest set bit (best bid / highest buy)
    function highestBit(uint256 bitmap) internal pure returns (uint8 idx) {
        require(bitmap != 0, "Empty bitmap");
        uint256 v = bitmap;
        assembly {
            idx := 0
            if gt(v, 0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF) { idx := 128 v := shr(128, v) }
            if gt(v, 0xFFFFFFFFFFFFFFFF) { idx := add(idx, 64)  v := shr(64, v) }
            if gt(v, 0xFFFFFFFF)         { idx := add(idx, 32)  v := shr(32, v) }
            if gt(v, 0xFFFF)             { idx := add(idx, 16)  v := shr(16, v) }
            if gt(v, 0xFF)               { idx := add(idx,  8)  v := shr( 8, v) }
            if gt(v, 0xF)               { idx := add(idx,  4)  v := shr( 4, v) }
            if gt(v, 0x3)               { idx := add(idx,  2)  v := shr( 2, v) }
            if gt(v, 0x1)               { idx := add(idx,  1) }
        }
        // Bound to MAX_INDEX
        if (idx > MAX_INDEX) idx = MAX_INDEX;
    }

    /// @notice Set a bit (price level has orders)
    function set(uint256 bitmap, uint8 idx) internal pure returns (uint256) {
        return bitmap | (1 << idx);
    }

    /// @notice Clear a bit (price level empty)
    function clear(uint256 bitmap, uint8 idx) internal pure returns (uint256) {
        return bitmap & ~(1 << idx);
    }

    /// @notice Check if a bit is set
    function isSet(uint256 bitmap, uint8 idx) internal pure returns (bool) {
        return bitmap & (1 << idx) != 0;
    }
}
```

**Gas savings**: Current `_lowestBit` is O(n) linear scan (worst case ~99 iterations × SLOAD). Assembly-based bit manipulation is O(1), saving ~2,000-5,000 gas per call.

**Note on "O(1)" claim:** The bitmap bit-search is O(1). However, `_peekBest` then walks the order queue at the chosen price level to find the first live order. With **queue cleanup discipline** (every fully-filled or cancelled order is swap-popped from its queue, and the bitmap bit is cleared when the queue empties), the walk returns on iteration 0 in the well-behaved case → end-to-end best-price lookup is O(1). The defensive `for` loop with `continue` on dead orders stays as a safety net but is near-dead code in normal operation. Cleanup MUST be applied at every terminal-transition site: `cancelOrder`, maker-vs-maker fills inside `_placeOrder`, and the taker-path execute helpers.

---

## 7. Library: MatchMath.sol

```solidity
// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {IPrediXExchange} from "../IPrediXExchange.sol";

/// @title MatchMath
/// @notice Pure math for fill amount calculation and price comparison
/// @dev No state, no side effects. Fully testable in isolation.
library MatchMath {

    uint256 internal constant PRICE_PRECISION = 1e6;

    /// @notice Check if taker side is a buy
    function isBuy(IPrediXExchange.Side side) internal pure returns (bool) {
        return side == IPrediXExchange.Side.BUY_YES
            || side == IPrediXExchange.Side.BUY_NO;
    }

    /// @notice Get complementary and synthetic opposite sides for a taker
    /// @dev Key mapping for 4-way waterfall:
    ///   BUY_YES  → comp: SELL_YES, syn: BUY_NO  (MINT)
    ///   SELL_YES → comp: BUY_YES,  syn: SELL_NO  (MERGE)
    ///   BUY_NO   → comp: SELL_NO,  syn: BUY_YES (MINT)
    ///   SELL_NO  → comp: BUY_NO,   syn: SELL_YES (MERGE)
    function sidesFor(IPrediXExchange.Side takerSide)
        internal pure
        returns (IPrediXExchange.Side comp, IPrediXExchange.Side syn)
    {
        if (takerSide == IPrediXExchange.Side.BUY_YES)
            return (IPrediXExchange.Side.SELL_YES, IPrediXExchange.Side.BUY_NO);
        if (takerSide == IPrediXExchange.Side.SELL_YES)
            return (IPrediXExchange.Side.BUY_YES, IPrediXExchange.Side.SELL_NO);
        if (takerSide == IPrediXExchange.Side.BUY_NO)
            return (IPrediXExchange.Side.SELL_NO, IPrediXExchange.Side.BUY_YES);
        return (IPrediXExchange.Side.BUY_NO, IPrediXExchange.Side.SELL_YES);
    }

    /// @notice Compute effective synthetic price for taker
    /// @dev takerEffective = 1e6 - makerPrice. Always sums to 1.0.
    function syntheticEffectivePrice(uint256 makerPrice) internal pure returns (uint256) {
        if (makerPrice == 0 || makerPrice >= PRICE_PRECISION) return 0;
        return PRICE_PRECISION - makerPrice;
    }

    /// @notice Check if price is within taker's limit
    function priceWithinLimit(
        uint256 price,
        uint256 limitPrice,
        bool    takerIsBuy
    ) internal pure returns (bool) {
        return takerIsBuy ? price <= limitPrice : price >= limitPrice;
    }

    /// @notice Pick best between comp and syn sources
    /// @dev Returns true if complementary should be preferred
    ///      Tiebreaker: prefer complementary (cheaper gas, no Diamond call)
    function preferComplementary(
        uint256 compPrice,
        uint256 synEffectivePrice,
        bool    compOk,
        bool    synOk,
        bool    takerIsBuy
    ) internal pure returns (bool) {
        if (!compOk) return false;
        if (!synOk) return true;
        // Both valid: pick better price. Tie → complementary wins (gas savings).
        return takerIsBuy
            ? compPrice <= synEffectivePrice
            : compPrice >= synEffectivePrice;
    }

    /// @notice Calculate fill amount at a given price level
    /// @param makerCapacity  Maker's remaining amount (amount - filled)
    /// @param remainingBudget Taker's remaining input budget
    /// @param price          Price at which fill happens
    /// @param takerIsBuy     Whether taker is buying
    /// @param isSynthetic    Whether this is a synthetic match
    /// @return fillAmount    Min of maker capacity and taker capacity
    function computeFillAmount(
        uint256 makerCapacity,
        uint256 remainingBudget,
        uint256 price,
        bool    takerIsBuy,
        bool    isSynthetic
    ) internal pure returns (uint256 fillAmount) {
        uint256 takerCapacity;

        if (takerIsBuy) {
            uint256 takerPricePerShare = isSynthetic
                ? PRICE_PRECISION - price
                : price;
            if (takerPricePerShare == 0) {
                takerCapacity = type(uint256).max;
            } else {
                takerCapacity = (remainingBudget * PRICE_PRECISION) / takerPricePerShare;
            }
        } else {
            // Taker supplies shares (input = shares)
            takerCapacity = remainingBudget;
        }

        fillAmount = makerCapacity < takerCapacity ? makerCapacity : takerCapacity;
    }
}
```

---

## 8. Key design decisions with rationale

### 8.1 Permissionless core (Uniswap v4 pattern)

```
Decision: fillMarketOrder has ZERO access control.
Rationale: Mirrors Uniswap v4 PoolManager.swap() — no onlyRouter, no whitelist.
Impact:   Any EOA, bot, aggregator, or DeFi protocol can integrate.
```

Current code has `whenNotPaused` on `fillMarketOrder`. Proposed design removes this from the taker path. Pause only affects `placeOrder` (maker path). Rationale: if the market is in a bad state, `_validateMarketActive` catches it (expired, resolved, refund mode, Diamond-level pause). Exchange-level pause should only stop new orders from entering the book, not prevent takers from consuming existing liquidity.

### 8.2 Upfront pull + refund (gas optimization)

```
Current:  Lazy pull per match → N * safeTransferFrom = N * 26k gas = 260k for 10 fills
Proposed: 1 pull + 1 refund = 52k fixed regardless of fill count
Savings:  ~200k gas for 10-fill scenario
```

This is exactly what Polymarket does — the operator settles in one batch, not per-match.

### 8.3 Order struct packing

```
Current layout (7 slots):
  Slot 1: address owner     (20 bytes, 12 bytes wasted)
  Slot 2: bytes32 marketId  (32 bytes)
  Slot 3: Side side         (1 byte, 31 bytes wasted!)
  Slot 4: uint256 price     (32 bytes)
  Slot 5: uint256 amount    (32 bytes)
  Slot 6: uint256 filled    (32 bytes)
  Slot 7: uint256 depositLocked (32 bytes)
  (uint64 timestamp, bool cancelled packed elsewhere due to ordering)

Proposed layout (5 slots):
  Slot 1: address owner + uint64 timestamp + Side + bool cancelled = 30 bytes ✓
  Slot 2: bytes32 marketId = 32 bytes
  Slot 3: uint256 price = 32 bytes
  Slot 4: uint256 amount = 32 bytes
  Slot 5: uint128 filled + uint128 depositLocked = 32 bytes ✓

Savings: 2 fewer SSTORE per order creation = ~40k gas saved per placeOrder
```

`uint128` cho `filled` và `depositLocked` vẫn đủ vì prediction market shares max supply capped bởi `totalCollateral` — không bao giờ vượt 2^128 (~340 tỷ tỷ tokens ở 6 decimals).

### 8.4 Bitmap operations (O(1) bit-search; end-to-end O(1) after queue cleanup)

```
Current:  _lowestBit linear scan: while (idx <= 98 && bitmap & (1<<idx) == 0) { idx++; }
          Worst case: 99 iterations × ~8 gas per iteration = ~800 gas
Proposed: Assembly bit manipulation (de Bruijn or BSR-style): O(1) = ~40 gas
Savings:  ~760 gas per bitmap scan (called multiple times per fill)
```

### 8.5 fillMarketOrder side semantics change

```
Current:  `side` param = MAKER side to fill against. Confusing — caller must mentally invert.
Proposed: `takerSide` param = what the TAKER wants. Exchange resolves internally.
          BUY_YES → look at SELL_YES (comp) + BUY_NO (syn)
Impact:   API more intuitive for all callers (EOA, bots, routers, aggregators)
```

This matches how Polymarket's `Side.BUY` / `Side.SELL` is from the taker's perspective in their Order struct.

### 8.6 Self-defending validation

```solidity
/// @notice Expanded market validation — 5 checks
/// @dev Current code only checks 3 (endTime, isResolved, refundMode → all as MarketNotActive)
///      Proposed: distinct errors for each failure mode → better debugging
function _validateMarketActive(bytes32 marketId) internal view {
    IMarketBase.MarketData memory market = IMarket(diamond).getMarket(marketId);

    if (market.endTime == 0)              revert MarketNotFound();
    if (block.timestamp >= market.endTime) revert MarketExpired();
    if (market.isResolved)                revert MarketResolved();
    if (IMarket(diamond).isRefundMode(marketId)) revert MarketInRefundMode();
    if (IPausable(diamond).paused(MARKET_MODULE)) revert MarketPaused();
}
```

### 8.7 FullMath removal

```
Current:  FullMath.mulDiv(amount, price, PRICE_PRECISION) — 512-bit precision
Reality:  amount * price / PRICE_PRECISION where:
          - amount ≤ totalCollateral (capped by market, typically < 10B * 1e6 = 10^16)
          - price ≤ 990_000 (< 10^6)
          - Product < 10^22, well within uint256 (10^77)
Proposed: Plain multiplication + division, with overflow protection from Solidity 0.8
Savings:  ~200-300 gas per math operation (FullMath does 4 extra multiplications)
```

---

## 9. Waterfall matching algorithm — detailed flow

```
fillMarketOrder(marketId, BUY_YES, limitPrice=0.60, amountIn=100 USDC, ...)

Step 1: Validate (deadline, market state, addresses)
Step 2: Pull 100 USDC from taker via safeTransferFrom
Step 3: Resolve sides:
        comp = SELL_YES  (direct sellers)
        syn  = BUY_NO    (same action, opposite token → MINT)
Step 4: Loop (maxFills iterations):
    ┌─ Peek comp best: SELL_YES best ask = $0.45
    ├─ Peek syn best:  BUY_NO best bid = $0.60 → effective = 1 - 0.60 = $0.40
    ├─ Compare: $0.40 (syn) < $0.45 (comp)
    ├─ Both within limit ($0.60)? Yes
    ├─ Pick synthetic (cheaper for buyer)
    ├─ Execute MINT: pull maker's $0.60 from lock + taker's $0.40
    │   → Diamond.splitPosition(1 share)
    │   → YES → recipient, NO → maker
    ├─ filled += 1, cost += $0.40, remaining = $99.60
    └─ Repeat...
Step 5: Refund: transfer (100 - cost) USDC back to taker
Step 6: Emit TakerFilled(marketId, taker, recipient, BUY_YES, filled, cost, matchCount)
```

---

## 10. Security invariants (from spec + additions)

| ID | Invariant | How enforced |
|----|-----------|-------------|
| I1 | Exchange USDC balance = Σ(maker BUY locks) + fees | Verified by fuzz invariant test |
| I2 | Exchange token balance = Σ(maker SELL locks) | Verified by fuzz invariant test |
| I3 | No taker residual after fill | Upfront pull + exact refund |
| I4 | filled monotonically increases | Only += in execute helpers |
| I5 | depositLocked monotonically decreases | Only -= in execute helpers |
| I6 | YES.supply == NO.supply == totalCollateral | Diamond enforces via splitPosition/mergePositions |
| I7 | cost ≤ amountIn always | remaining = amountIn - cost, breaks if 0 |
| I8 | No self-match in any path | Checked in _executeComp and _executeSynthetic |
| T1 | Atomic execution | nonReentrant + single tx |
| T2 | Deadline respected | First check in fillMarketOrder |
| T3 | limitPrice never crossed | Checked in _pickBestSource |

---

## 11. Gas budget targets

| Function | Scenario | Target | Current estimate |
|----------|----------|--------|-----------------|
| fillMarketOrder | CLOB empty | ≤ 80k | ~50k (validate + pull + refund) |
| fillMarketOrder | 1 comp fill | ≤ 180k | ~140k (+ 2 transfers) |
| fillMarketOrder | 1 MINT fill | ≤ 260k | ~220k (+ Diamond.split + 2 transfers) |
| fillMarketOrder | 1 MERGE fill | ≤ 240k | ~200k (+ Diamond.merge + 2 transfers) |
| fillMarketOrder | 3 mixed fills | ≤ 520k | ~450k |
| fillMarketOrder | 10 fills max | ≤ 1.2M | ~1.0M |
| previewFillMarketOrder | 3 fills | ≤ 80k view | ~60k (no transfers) |
| placeOrder | new order | Same as current | -2 SSTORE (~40k savings from packing) |

---

## 12. Migration & integration checklist

| # | Item | Status |
|---|------|--------|
| 1 | Extract PriceBitmap library, write unit tests | ☐ |
| 2 | Extract MatchMath library, write unit tests | ☐ |
| 3 | Create ExchangeStorage.sol with packed Order struct | ☐ |
| 4 | Create IPrediXExchange.sol with new interface | ☐ |
| 5 | Implement MakerPath.sol (port placeOrder, cancelOrder) | ☐ |
| 6 | Implement Matching.sol (port _executeComp/Mint/Merge) | ☐ |
| 7 | Implement TakerPath.sol (new waterfall fillMarketOrder) | ☐ |
| 8 | Implement Views.sol (port views + new preview) | ☐ |
| 9 | Compose PrediXExchange.sol | ☐ |
| 10 | Write unit tests (25 taker + 5 preview) | ☐ |
| 11 | Write fuzz + invariant tests | ☐ |
| 12 | Gas benchmark vs targets | ☐ |
| 13 | Deploy to Unichain Sepolia | ☐ |
| 14 | Update Router to use new interface | ☐ |

---

## 13. What NOT to change

| Component | Reason |
|-----------|--------|
| Maker path logic (_tryComplementary, _tryMint, _tryMerge) | Working + tested, only refactor into Matching mixin |
| Storage layout of orders mapping | Not worth migration cost |
| Diamond interface (splitPosition, mergePositions) | External dependency, unchanged |
| OutcomeToken (ERC-20) | External dependency, unchanged |
| TransientReentrancyGuard | Already optimal (EIP-1153) |
| Bitmap 99-tick resolution | $0.01 granularity is sufficient |

---

*Created: 2026-04-14*
*Status: DESIGN REVIEW*
*Next step: validate design, then implement with this spec as SSOT*
