# PrediXExchange Refactor — Technical Specification

> **SINGLE SOURCE OF TRUTH** for refactoring `PrediXExchange` to become a complete, permissionless CLOB core with 4-way waterfall market order routing.
>
> **GREENFIELD REFACTOR.** No production migration. Delete, rename, restructure freely.
>
> **SCOPE:** This spec covers Exchange only. Router is specified separately in `ROUTER_REFACTOR_SPEC.md`. Router consumes Exchange's API but Exchange is fully usable standalone (any EOA, bot, contract, or aggregator).
>
> Source: `/Users/keyti/Sources/PrediX_Uni_V4/Smart_Contract_V2/src/exchange/`
> Parent spec: `PREDIX_SPEC.md`
> Related spec: `ROUTER_REFACTOR_SPEC.md`

---

## 0. OPERATING RULES

### 0.1 Golden Rules

1. **Spec is law.** Every function, error, event, algorithm is defined here.
2. **Permissionless core.** Exchange has NO access control beyond basic safety. Any caller is valid.
3. **Self-defending.** Exchange protects itself without trusting any caller.
4. **Minimal surface area.** Delete dead code. Single code path per concern.
5. **`forge build` must pass** after every file change.
6. **`forge test` must pass** before marking any phase ☑.
7. **Report honestly.** If a test fails, say so. Do NOT claim "done" if it's not.

### 0.2 NEVER Do These Things

- ❌ Add access control to public taker path (no `onlyRouter`, `onlyBot`, etc.)
- ❌ Trust callers to do security checks (reentrancy, caps, validations)
- ❌ Keep legacy `fillMarketOrder` alongside new one — replace in place
- ❌ Add storage for taker-path state (stateless between fills)
- ❌ Add off-chain hints / solver inputs
- ❌ Leak funds (taker's unused input MUST be refunded)
- ❌ Allow self-match in any path (complementary or synthetic)
- ❌ Execute without market validity check
- ❌ Change Diamond `splitPosition` / `mergePositions` interface

---

## 1. Problem Statement

### 1.1 Bug 1 — MINT/MERGE synthetic liquidity unreachable for market takers

Current `fillMarketOrder` only performs **COMPLEMENTARY** matches (direct taker↔maker opposite sides). It cannot match against same-side opposite-token makers via MINT/MERGE synthetic matching, even though this is a valid liquidity source.

**Consequence:** Market-order takers miss liquidity. Example:

```
Orderbook:
  SELL_YES: (empty)
  BUY_NO @ $0.70 × 50 shares
  BUY_NO @ $0.65 × 30 shares

User wants to buy YES at market (budget $100).

Current Exchange:
  fillMarketOrder(BUY_YES, ...) → scans SELL_YES → empty
  Returns (0, 0)
  User gets nothing from CLOB.

Optimal (with synthetic):
  MINT match BUY_NO @ $0.70 (taker effective price $0.30) → 50 YES at $15 USDC
  MINT match BUY_NO @ $0.65 (taker effective price $0.35) → 30 YES at $10.50 USDC
  User gets 80 YES for $25.50 USDC.
```

The liquidity was there. Exchange failed to use it.

### 1.2 Bug 2 — `maxPrice` semantics hidden behind caller discipline

Current `fillMarketOrder` takes a `maxPrice` parameter but:
- For BUY sides: it's a price **cap** (max willing to pay)
- For SELL sides: it's interpreted as `0` in some call sites and... unclear

Caller must know which semantic applies. Error-prone.

### 1.3 Bug 3 — No deadline protection

Current `fillMarketOrder` has no `deadline` parameter. Stale transactions in mempool can execute at unexpected prices if orderbook moves. Industry standard for trading functions is to include deadline.

### 1.4 Bug 4 — Taker event tracking gap

`OrderMatched` event has fields for maker order ID and (optionally) taker order ID. For taker-path fills, there is no taker order, so the event doesn't capture `taker` address. Indexers cannot attribute fills to the caller.

### 1.5 Bug 5 — Inadequate market state validation

Taker path currently checks `endTime` and `isResolved`. Missing checks:
- Market is in refund mode (trading should be frozen)
- Market module is paused via `PausableFacet`

### 1.6 Bug 6 — No preview / simulation function

External users (bots, aggregators, UIs) need to estimate fill results before execution. Current view functions (`getBestPrices`, `getDepthAtPrice`) give raw state but not the waterfall computation. Each caller must reimplement the matching logic to simulate.

### 1.7 Bug 7 — Self-match risk in synthetic path

Existing `SelfMatchNotAllowed` check exists for complementary fills. Synthetic MINT/MERGE via taker path has no equivalent check. A user could match against their own resting BUY_NO order via BUY_YES taker call, creating a roundabout self-trade.

### 1.8 Bug 8 — Ambiguous fund handling

Current `fillMarketOrder` pulls funds lazily per complementary match. When refactoring to include synthetic matches and a loop structure, pull strategy becomes unclear. Lazy pull wastes gas on repeated `transferFrom`. Upfront pull requires explicit refund of unused input. The spec must define one strategy and stick to it.

---

## 2. Design Principles

### 2.1 Permissionless Core

Exchange is protocol infrastructure. `fillMarketOrder` has **no access control**. Valid callers include:
- End users (EOA) calling directly
- PrediX Router (optional FE helper)
- Third-party routers / aggregators (1inch, Cow Swap, Odos, etc.)
- Arbitrage bots
- Other DeFi protocols composing PrediX liquidity

Architecture mirrors Uniswap v4: `PoolManager` is permissionless core, `Router` is optional helper.

### 2.2 4-Way Waterfall Matching

For each market order, Exchange considers **4 liquidity sources** and picks the cheapest:

| Taker wants | Complementary source | Synthetic source |
|-------------|---------------------|------------------|
| BUY_YES | SELL_YES orders | BUY_NO orders (MINT) |
| SELL_YES | BUY_YES orders | SELL_NO orders (MERGE) |
| BUY_NO | SELL_NO orders | BUY_YES orders (MINT) |
| SELL_NO | BUY_NO orders | SELL_YES orders (MERGE) |

**Synthetic effective price** (for taker): `takerEffective = 1e6 - makerPrice`.

At each iteration, Exchange picks whichever source has the best price (cheaper for buy, higher for sell) and fills one match. Loop continues until:
- `maxFills` iterations reached, OR
- Both sources exhausted or above caller's limit, OR
- `amountIn` consumed, OR
- `deadline` passed (checked at entry)

### 2.3 Self-Defending Exchange

Exchange provides security guarantees regardless of caller behavior:

| Guarantee | How |
|-----------|-----|
| **Reentrancy safe** | `nonReentrant` modifier |
| **Respects `limitPrice`** | Never fills above cap (or below floor) |
| **Safe fund pulls** | `safeTransferFrom(taker, ...)` — reverts if not approved |
| **No trapped funds** | Upfront pull + refund unused at exit |
| **Maker integrity** | Cannot over-fill a maker beyond their locked deposit |
| **Market validity** | Checks endTime, isResolved, refundMode, paused |
| **Self-match prevention** | Blocked in both complementary and synthetic paths |
| **Deadline honored** | Reverts if `block.timestamp > deadline` |

Exchange does NOT do:
- ❌ `minOut` slippage check (caller's responsibility)
- ❌ AMM fallback (caller's responsibility)
- ❌ Dust refund to end user beyond refunding `taker` (caller handles end-user UX)

### 2.4 Upfront Pull + Refund Model

**Fund flow:**

```
1. Exchange pulls `amountIn` from `taker` via safeTransferFrom (1 call)
2. Loop executes fills using internal balance accounting
3. At exit, Exchange refunds unused input (amountIn - cost) back to `taker` (1 call)
```

**Rationale:** Single pull + single refund = ~100k gas. Lazy per-iteration pull = ~500k gas worst case.

**Invariant:** Exchange's balance of `taker`'s input token is zero at both function entry and exit. No residual between calls.

### 2.5 Dynamic `maxFills` Cap

Iteration cap is caller-supplied. No hard upper bound — natural gas limit is the ceiling.

```
maxFills = 0     → Exchange uses DEFAULT_MAX_FILLS = 10
maxFills = N > 0 → Exchange iterates up to N times
```

Caller controls gas budget vs routing depth.

### 2.6 Deadline Protection

Every `fillMarketOrder` call requires a `deadline` timestamp. Exchange reverts if `block.timestamp > deadline`. Prevents stale mempool execution.

---

## 3. External API

### 3.1 Interface — `IPrediXExchange.sol`

```solidity
interface IPrediXExchange {
    // ============ Enums ============
    
    enum Side {
        BUY_YES,
        SELL_YES,
        BUY_NO,
        SELL_NO
    }
    
    enum MatchType {
        COMPLEMENTARY,
        MINT,
        MERGE
    }
    
    // ============ Structs ============
    
    struct Order {
        address owner;
        bytes32 marketId;
        Side side;
        uint256 price;          // 6 decimals
        uint256 amount;         // total tokens to trade
        uint256 filled;         // already filled
        uint256 depositLocked;  // USDC (buy) or tokens (sell) locked
        uint64 timestamp;
        bool cancelled;
    }
    
    struct PriceLevel {
        uint256 price;
        uint256 totalAmount;
    }
    
    // ============ Errors ============
    
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
    
    // ============ Events ============
    
    event OrderPlaced(
        bytes32 indexed orderId,
        bytes32 indexed marketId,
        address indexed owner,
        Side side,
        uint256 price,
        uint256 amount
    );
    
    event OrderMatched(
        bytes32 indexed makerOrderId,
        bytes32 indexed takerOrderId,  // bytes32(0) for taker-path fills
        bytes32 indexed marketId,
        MatchType matchType,
        uint256 amount,
        uint256 price
    );
    
    event OrderCancelled(bytes32 indexed orderId);
    
    event FeeCollected(bytes32 indexed marketId, uint256 amount);
    
    /// @notice Emitted once per `fillMarketOrder` call at the end.
    /// @dev Captures the taker identity and aggregate results for analytics.
    event TakerFilled(
        bytes32 indexed marketId,
        address indexed taker,
        address indexed recipient,
        Side takerSide,
        uint256 totalFilled,   // total output received
        uint256 totalCost,     // total input consumed
        uint256 matchCount     // number of fills in this call
    );
    
    // ============ Maker Path (limit orders) ============
    
    /// @notice Place a limit order. Auto-matches COMPLEMENTARY + MINT + MERGE.
    /// @dev Maker path. Not affected by this refactor.
    function placeOrder(
        bytes32 marketId,
        Side side,
        uint256 price,
        uint256 amount
    ) external returns (bytes32 orderId, uint256 filledAmount);
    
    /// @notice Cancel resting order.
    function cancelOrder(bytes32 orderId) external;
    
    // ============ Taker Path (market orders) ============
    
    /// @notice Fill a market order with 4-way waterfall routing.
    ///
    ///         Iterates through resting orderbook up to `maxFills` times.
    ///         Each iteration picks the cheapest of:
    ///           - COMPLEMENTARY (opposite-side direct match)
    ///           - SYNTHETIC (same-action opposite-token, via MINT or MERGE)
    ///
    ///         Stops when:
    ///           - orderbook exhausted on both sides, OR
    ///           - next best price violates `limitPrice`, OR
    ///           - `amountIn` budget consumed, OR
    ///           - `maxFills` iterations reached.
    ///
    /// @param marketId Target market
    /// @param takerSide BUY_YES / SELL_YES / BUY_NO / SELL_NO
    /// @param limitPrice For BUY sides: MAX price per share taker will pay.
    ///                   For SELL sides: MIN price per share taker will accept.
    ///                   Exchange never crosses this limit.
    /// @param amountIn Taker's input: USDC for buy, shares for sell
    /// @param taker Address providing input funds (must have approved Exchange)
    /// @param recipient Address receiving output tokens
    /// @param maxFills Max iterations (0 = DEFAULT_MAX_FILLS = 10)
    /// @param deadline Transaction deadline (revert if expired)
    /// @return filled Total output delivered to recipient
    /// @return cost Total input consumed from taker
    /// @dev Exchange pulls `amountIn` upfront, refunds `(amountIn - cost)` to taker at end.
    ///      Reverts on: invalid market, self-match, deadline, transferFrom failure.
    function fillMarketOrder(
        bytes32 marketId,
        Side takerSide,
        uint256 limitPrice,
        uint256 amountIn,
        address taker,
        address recipient,
        uint256 maxFills,
        uint256 deadline
    ) external returns (uint256 filled, uint256 cost);
    
    // ============ View Functions ============
    
    /// @notice Simulate a `fillMarketOrder` call without executing.
    /// @dev Pure view. Applies same waterfall logic.
    ///      Does NOT mutate state or emit events.
    function previewFillMarketOrder(
        bytes32 marketId,
        Side takerSide,
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

### 3.2 Key Design Points

1. **`limitPrice` replaces `maxPrice`** — neutral name, semantic explained in NatSpec (cap for buy, floor for sell).
2. **`deadline` added** — industry standard safety.
3. **`maxFills` added** — dynamic iteration cap.
4. **`TakerFilled` event added** — captures taker identity for indexers.
5. **`previewFillMarketOrder` added** — callers can simulate without implementing waterfall themselves.

---

## 4. Implementation Details

### 4.1 Constants

```solidity
// In PrediXExchange.sol
uint256 internal constant DEFAULT_MAX_FILLS = 10;
uint256 internal constant PRICE_PRECISION = 1e6;
uint256 internal constant MIN_PRICE = 10_000;        // $0.01
uint256 internal constant MAX_PRICE = 990_000;       // $0.99
uint256 internal constant MIN_ORDER_AMOUNT = 1e6;    // 1 share (maker path only)
uint256 internal constant MAX_ORDERS_PER_USER = 50;
uint256 internal constant FEE_RECIPIENT_SLOT = 0; // use existing storage

enum FillSource { NONE, COMPLEMENTARY, SYNTHETIC }
```

### 4.2 `fillMarketOrder` Entry Function

```solidity
function fillMarketOrder(
    bytes32 marketId,
    Side takerSide,
    uint256 limitPrice,
    uint256 amountIn,
    address taker,
    address recipient,
    uint256 maxFills,
    uint256 deadline
) external nonReentrant returns (uint256 filled, uint256 cost) {
    // ===== Validation =====
    if (block.timestamp > deadline) revert DeadlineExpired(deadline, block.timestamp);
    if (amountIn == 0) return (0, 0);
    if (taker == address(0)) revert ZeroAddress();
    if (recipient == address(0)) revert ZeroAddress();
    
    _validateMarketActive(marketId);
    
    // ===== Upfront pull =====
    address inputToken = _inputTokenFor(marketId, takerSide);
    IERC20(inputToken).safeTransferFrom(taker, address(this), amountIn);
    
    // ===== Resolve max iterations =====
    uint256 effectiveMaxFills = maxFills == 0 ? DEFAULT_MAX_FILLS : maxFills;
    
    // ===== Waterfall loop =====
    uint256 remaining = amountIn;
    uint256 matchCount;
    
    for (uint256 i; i < effectiveMaxFills; ++i) {
        if (remaining == 0) break;
        
        (FillSource source, uint256 makerPrice, bytes32 makerOrderId, uint256 fillAmount) =
            _pickBestSource(marketId, takerSide, limitPrice, remaining);
        
        if (source == FillSource.NONE || fillAmount == 0) break;
        
        uint256 outDelta;
        uint256 inDelta;
        
        if (source == FillSource.COMPLEMENTARY) {
            (outDelta, inDelta) = _executeComplementaryTakerFill(
                marketId, takerSide, makerPrice, makerOrderId, fillAmount, taker, recipient
            );
        } else {
            (outDelta, inDelta) = _executeSyntheticTakerFill(
                marketId, takerSide, makerPrice, makerOrderId, fillAmount, taker, recipient
            );
        }
        
        if (outDelta == 0) break;  // nothing progressed, bail
        
        filled += outDelta;
        cost += inDelta;
        remaining = amountIn > cost ? amountIn - cost : 0;
        matchCount++;
    }
    
    // ===== Deliver output =====
    // (Note: output tokens are transferred to recipient INSIDE _execute* helpers
    //  to support MINT/MERGE which mint outputs directly.)
    
    // ===== Refund unused input =====
    uint256 unused = amountIn - cost;
    if (unused > 0) {
        IERC20(inputToken).safeTransfer(taker, unused);
    }
    
    emit TakerFilled(marketId, taker, recipient, takerSide, filled, cost, matchCount);
}
```

### 4.3 `_pickBestSource` — 4-Way Waterfall Core

```solidity
/// @dev Returns the best available source at this iteration.
///      Considers COMPLEMENTARY and SYNTHETIC. Picks cheapest for buy, highest for sell.
///      Returns NONE if both sources exhausted or outside limitPrice.
function _pickBestSource(
    bytes32 marketId,
    Side takerSide,
    uint256 limitPrice,
    uint256 remainingBudget
) internal view returns (
    FillSource source,
    uint256 makerPrice,
    bytes32 makerOrderId,
    uint256 fillAmount
) {
    // Determine COMPLEMENTARY and SYNTHETIC opposite sides
    (Side compSide, Side synSide) = _sidesFor(takerSide);
    
    // Get best price on each side
    (uint256 compBest, bytes32 compOrderId) = _peekBest(marketId, compSide);
    (uint256 synBestMaker, bytes32 synOrderId) = _peekBest(marketId, synSide);
    
    // Compute effective synthetic price for taker
    uint256 synBestEffective = synBestMaker > 0 && synBestMaker < PRICE_PRECISION
        ? (PRICE_PRECISION - synBestMaker)
        : 0;
    
    // Apply limit price check
    bool isBuy = (takerSide == Side.BUY_YES || takerSide == Side.BUY_NO);
    bool compOk = compBest > 0 && (isBuy ? compBest <= limitPrice : compBest >= limitPrice);
    bool synOk = synBestEffective > 0 && (isBuy ? synBestEffective <= limitPrice : synBestEffective >= limitPrice);
    
    // MERGE-specific constraint: for SELL sides, synthetic requires sum ≤ 1.0
    // i.e., makerPrice + takerPrice ≤ 1. But takerPrice = 1 - makerPrice, so always ≤ 1. Auto-satisfied.
    // No extra check needed.
    
    // MINT-specific constraint: for BUY sides, sum ≥ 1.0. Same math — always = 1. Auto-satisfied.
    
    if (!compOk && !synOk) {
        return (FillSource.NONE, 0, bytes32(0), 0);
    }
    
    // Pick cheaper (buy) or higher (sell)
    bool pickComp;
    if (compOk && synOk) {
        pickComp = isBuy ? (compBest <= synBestEffective) : (compBest >= synBestEffective);
    } else {
        pickComp = compOk;
    }
    
    if (pickComp) {
        source = FillSource.COMPLEMENTARY;
        makerPrice = compBest;
        makerOrderId = compOrderId;
        fillAmount = _computeFillAmount(marketId, compSide, compBest, remainingBudget, takerSide);
    } else {
        source = FillSource.SYNTHETIC;
        makerPrice = synBestMaker;  // raw maker price, NOT effective
        makerOrderId = synOrderId;
        fillAmount = _computeFillAmount(marketId, synSide, synBestMaker, remainingBudget, takerSide);
    }
}

/// @dev Maps taker side → (complementary opposite, synthetic opposite)
function _sidesFor(Side takerSide) internal pure returns (Side comp, Side syn) {
    if (takerSide == Side.BUY_YES) return (Side.SELL_YES, Side.BUY_NO);
    if (takerSide == Side.SELL_YES) return (Side.BUY_YES, Side.SELL_NO);
    if (takerSide == Side.BUY_NO) return (Side.SELL_NO, Side.BUY_YES);
    return (Side.BUY_NO, Side.SELL_YES);  // SELL_NO
}

/// @dev Peek at best order on a side without mutating state.
function _peekBest(bytes32 marketId, Side side) internal view returns (uint256 price, bytes32 orderId) {
    uint256 bitmap = priceBitmap[marketId][side];
    if (bitmap == 0) return (0, bytes32(0));
    
    uint256 priceIdx = _findBestPriceIdx(bitmap, side);
    bytes32[] storage queue = _orderQueue[marketId][side][priceIdx];
    
    // Find first non-cancelled, non-fully-filled order
    for (uint256 i; i < queue.length; ++i) {
        Order storage order = orders[queue[i]];
        if (order.cancelled) continue;
        if (order.filled >= order.amount) continue;
        if (order.depositLocked == 0) continue;  // defensive
        
        return (order.price, queue[i]);
    }
    
    return (0, bytes32(0));  // all orders at this level are dead
}
```

### 4.4 `_computeFillAmount` — How much to fill at this level

```solidity
function _computeFillAmount(
    bytes32 marketId,
    Side makerSide,
    uint256 price,
    uint256 remainingBudget,
    Side takerSide
) internal view returns (uint256 fillAmount) {
    // Maker order's remaining capacity
    (, bytes32 orderId) = _peekBest(marketId, makerSide);
    Order storage order = orders[orderId];
    uint256 makerCapacity = order.amount - order.filled;
    
    // Taker's capacity from their budget
    uint256 takerCapacity;
    bool takerIsBuy = (takerSide == Side.BUY_YES || takerSide == Side.BUY_NO);
    bool isSynthetic = (makerSide != _complementOf(takerSide));
    
    if (takerIsBuy) {
        // Taker pays input per share
        uint256 takerPricePerShare = isSynthetic ? (PRICE_PRECISION - price) : price;
        if (takerPricePerShare == 0) takerCapacity = type(uint256).max;
        else takerCapacity = (remainingBudget * PRICE_PRECISION) / takerPricePerShare;
    } else {
        // Taker supplies shares (input = shares, 1 share ≈ 1 share)
        takerCapacity = remainingBudget;
    }
    
    fillAmount = makerCapacity < takerCapacity ? makerCapacity : takerCapacity;
}
```

### 4.5 `_executeComplementaryTakerFill`

```solidity
/// @dev Direct match: taker and maker on opposite sides of the same token.
///      Example: taker BUY_YES vs maker SELL_YES
///      Transfers tokens/USDC directly between Exchange's internal accounting
///      (taker's funds already pulled upfront, maker's lock already in Exchange).
function _executeComplementaryTakerFill(
    bytes32 marketId,
    Side takerSide,
    uint256 price,
    bytes32 makerOrderId,
    uint256 matchAmount,
    address taker,
    address recipient
) internal returns (uint256 outDelta, uint256 inDelta) {
    Order storage makerOrder = orders[makerOrderId];
    
    // Self-match prevention
    if (makerOrder.owner == taker) revert SelfMatchNotAllowed();
    
    bool takerIsBuy = (takerSide == Side.BUY_YES || takerSide == Side.BUY_NO);
    uint256 usdcAmount = (matchAmount * price) / PRICE_PRECISION;
    
    if (takerIsBuy) {
        // Taker buys tokens from maker
        // - Maker's locked tokens → recipient
        // - Exchange-held taker USDC → maker
        address token = _outputTokenFor(marketId, takerSide);
        IERC20(token).safeTransfer(recipient, matchAmount);
        IERC20(usdc).safeTransfer(makerOrder.owner, usdcAmount);
        
        // Update maker state: tokens delivered, USDC received
        makerOrder.filled += matchAmount;
        makerOrder.depositLocked -= matchAmount;  // tokens locked = filled
        
        outDelta = matchAmount;
        inDelta = usdcAmount;
    } else {
        // Taker sells tokens to maker
        // - Exchange-held taker tokens → maker
        // - Maker's locked USDC → recipient
        address token = _inputTokenFor(marketId, takerSide);
        IERC20(token).safeTransfer(makerOrder.owner, matchAmount);
        IERC20(usdc).safeTransfer(recipient, usdcAmount);
        
        makerOrder.filled += matchAmount;
        makerOrder.depositLocked -= usdcAmount;
        
        outDelta = usdcAmount;
        inDelta = matchAmount;
    }
    
    emit OrderMatched(makerOrderId, bytes32(0), marketId, MatchType.COMPLEMENTARY, matchAmount, price);
}
```

### 4.6 `_executeSyntheticTakerFill` — MINT or MERGE from taker

```solidity
/// @dev Synthetic match: taker and maker on same action (both BUY or both SELL) but opposite tokens.
///      Example: taker BUY_YES vs maker BUY_NO → MINT
///               taker SELL_YES vs maker SELL_NO → MERGE
///
///      For MINT: Exchange calls Diamond.splitPosition, distributes YES to one side, NO to other.
///      For MERGE: Exchange calls Diamond.mergePositions, distributes USDC proceeds between both.
///
///      Economic property: takerEffective + makerPrice = 1.0 always.
///      No surplus is generated (taker's price is derived from maker's).
function _executeSyntheticTakerFill(
    bytes32 marketId,
    Side takerSide,
    uint256 makerPrice,
    bytes32 makerOrderId,
    uint256 matchAmount,
    address taker,
    address recipient
) internal returns (uint256 outDelta, uint256 inDelta) {
    Order storage makerOrder = orders[makerOrderId];
    
    // Self-match prevention
    if (makerOrder.owner == taker) revert SelfMatchNotAllowed();
    
    bool takerIsBuy = (takerSide == Side.BUY_YES || takerSide == Side.BUY_NO);
    
    if (takerIsBuy) {
        // MINT case: both taker and maker are BUY
        // Required: matchAmount USDC for splitPosition
        // Maker contributes: matchAmount * makerPrice / 1e6 (from depositLocked)
        // Taker contributes: matchAmount * (1 - makerPrice) / 1e6 (from pulled funds)
        
        uint256 makerUsdc = (matchAmount * makerPrice) / PRICE_PRECISION;
        uint256 takerUsdc = matchAmount - makerUsdc;  // ensures exact sum
        
        // Verify maker has enough locked
        if (makerOrder.depositLocked < makerUsdc) revert InsufficientLiquidity();
        
        // Split via Diamond (Exchange has taker USDC from upfront pull + maker USDC from lock)
        _ensureDiamondApproval(usdc);
        IMarket(diamond).splitPosition(marketId, matchAmount);
        
        // Diamond minted matchAmount YES + matchAmount NO to Exchange
        // Distribute based on taker side
        address takerOutToken;
        address makerOutToken;
        if (takerSide == Side.BUY_YES) {
            takerOutToken = _yesToken(marketId);
            makerOutToken = _noToken(marketId);
        } else {
            takerOutToken = _noToken(marketId);
            makerOutToken = _yesToken(marketId);
        }
        
        IERC20(takerOutToken).safeTransfer(recipient, matchAmount);
        IERC20(makerOutToken).safeTransfer(makerOrder.owner, matchAmount);
        
        // Update maker state
        makerOrder.filled += matchAmount;
        makerOrder.depositLocked -= makerUsdc;
        
        outDelta = matchAmount;
        inDelta = takerUsdc;
        
        emit OrderMatched(makerOrderId, bytes32(0), marketId, MatchType.MINT, matchAmount, makerPrice);
    } else {
        // MERGE case: both taker and maker are SELL
        // Required: matchAmount of taker token (already in Exchange from upfront pull)
        //           + matchAmount of maker token (from maker's depositLocked)
        // Exchange mergePositions → receives matchAmount USDC
        // Distribute: taker gets (1 - makerPrice) portion, maker gets makerPrice portion
        
        uint256 makerUsdcShare = (matchAmount * makerPrice) / PRICE_PRECISION;
        uint256 takerUsdcShare = matchAmount - makerUsdcShare;  // exact sum
        
        if (makerOrder.depositLocked < matchAmount) revert InsufficientLiquidity();
        
        // Merge via Diamond
        _ensureDiamondApproval(_yesToken(marketId));
        _ensureDiamondApproval(_noToken(marketId));
        IMarket(diamond).mergePositions(marketId, matchAmount);
        
        // Distribute USDC
        IERC20(usdc).safeTransfer(recipient, takerUsdcShare);
        IERC20(usdc).safeTransfer(makerOrder.owner, makerUsdcShare);
        
        makerOrder.filled += matchAmount;
        makerOrder.depositLocked -= matchAmount;  // tokens consumed
        
        outDelta = takerUsdcShare;
        inDelta = matchAmount;
        
        emit OrderMatched(makerOrderId, bytes32(0), marketId, MatchType.MERGE, matchAmount, makerPrice);
    }
}
```

**Key properties verified:**
- **Zero surplus**: `takerPortion + makerPortion = matchAmount` exactly (integer math guaranteed).
- **Self-match blocked** at entry.
- **Maker integrity**: `depositLocked >= required` check before execution.
- **Diamond interaction**: `splitPosition` / `mergePositions` called with exact amounts.

### 4.7 `_validateMarketActive` — Expanded

```solidity
function _validateMarketActive(bytes32 marketId) internal view {
    IMarketBase.MarketData memory market = IMarket(diamond).getMarket(marketId);
    
    if (market.endTime == 0) revert MarketNotFound();
    if (block.timestamp >= market.endTime) revert MarketExpired();
    if (market.isResolved) revert MarketResolved();
    
    // Check refund mode (Diamond-side flag)
    if (IMarket(diamond).isRefundMode(marketId)) revert MarketInRefundMode();
    
    // Check pause state (PausableFacet)
    // Assumes a MARKET_MODULE constant shared between Diamond and Exchange
    if (IPausable(diamond).paused(MARKET_MODULE)) revert MarketPaused();
}
```

### 4.8 `previewFillMarketOrder` — Simulation

```solidity
function previewFillMarketOrder(
    bytes32 marketId,
    Side takerSide,
    uint256 limitPrice,
    uint256 amountIn,
    uint256 maxFills
) external view returns (uint256 filled, uint256 cost) {
    if (amountIn == 0) return (0, 0);
    
    uint256 effectiveMaxFills = maxFills == 0 ? DEFAULT_MAX_FILLS : maxFills;
    uint256 remaining = amountIn;
    
    // Simulate loop without state mutation
    // Uses _peekBest + _computeFillAmount in read-only way
    // Cannot call _execute* (they mutate state)
    
    // For each iteration, compute hypothetical fill:
    //   - Pick source (compute price)
    //   - Compute fill amount (same logic)
    //   - Accumulate filled/cost
    //   - Virtually "consume" the order for next iteration
    //
    // Since we can't mutate orders, we track consumed amounts in memory.
    
    uint256[] memory consumedPerOrder = new uint256[](effectiveMaxFills);
    bytes32[] memory visitedOrderIds = new bytes32[](effectiveMaxFills);
    uint256 visited;
    
    for (uint256 i; i < effectiveMaxFills; ++i) {
        if (remaining == 0) break;
        
        (FillSource source, uint256 makerPrice, bytes32 makerOrderId, uint256 fillAmount) =
            _pickBestSourceVirtual(marketId, takerSide, limitPrice, remaining, visitedOrderIds, consumedPerOrder, visited);
        
        if (source == FillSource.NONE || fillAmount == 0) break;
        
        // Compute hypothetical output/cost
        bool takerIsBuy = (takerSide == Side.BUY_YES || takerSide == Side.BUY_NO);
        uint256 outDelta;
        uint256 inDelta;
        
        if (source == FillSource.COMPLEMENTARY) {
            uint256 usdcAmount = (fillAmount * makerPrice) / PRICE_PRECISION;
            if (takerIsBuy) { outDelta = fillAmount; inDelta = usdcAmount; }
            else { outDelta = usdcAmount; inDelta = fillAmount; }
        } else {
            // SYNTHETIC
            uint256 takerPortion = fillAmount - (fillAmount * makerPrice) / PRICE_PRECISION;
            if (takerIsBuy) { outDelta = fillAmount; inDelta = takerPortion; }
            else { outDelta = takerPortion; inDelta = fillAmount; }
        }
        
        filled += outDelta;
        cost += inDelta;
        remaining = amountIn > cost ? amountIn - cost : 0;
        
        // Track virtual consumption
        visitedOrderIds[visited] = makerOrderId;
        consumedPerOrder[visited] = fillAmount;
        visited++;
    }
}
```

**Note:** Preview must track virtual consumption to avoid re-picking the same order in subsequent iterations. Implementation uses a bounded array (max = `effectiveMaxFills`).

### 4.9 `_ensureDiamondApproval` — Lazy approval

```solidity
function _ensureDiamondApproval(address token) internal {
    if (IERC20(token).allowance(address(this), diamond) < type(uint128).max) {
        IERC20(token).forceApprove(diamond, type(uint256).max);
    }
}
```

Called once per token type on first synthetic fill. Subsequent fills reuse the infinite approval.

### 4.10 Helper: `_inputTokenFor` / `_outputTokenFor`

```solidity
function _inputTokenFor(bytes32 marketId, Side takerSide) internal view returns (address) {
    if (takerSide == Side.BUY_YES || takerSide == Side.BUY_NO) return usdc;
    if (takerSide == Side.SELL_YES) return _yesToken(marketId);
    return _noToken(marketId);
}

function _outputTokenFor(bytes32 marketId, Side takerSide) internal view returns (address) {
    if (takerSide == Side.BUY_YES) return _yesToken(marketId);
    if (takerSide == Side.BUY_NO) return _noToken(marketId);
    return usdc;  // SELL sides
}
```

---

## 5. Edge Cases Handled

| # | Edge case | Behavior |
|---|-----------|----------|
| 1 | CLOB empty both sides | Return `(0, 0)`, refund all `amountIn` |
| 2 | All orders above `limitPrice` | Return `(0, 0)`, refund all |
| 3 | `maxFills = 0` | Use `DEFAULT_MAX_FILLS = 10` |
| 4 | `maxFills = type(uint256).max` | Natural gas limit caps execution |
| 5 | `amountIn = 0` | Early return `(0, 0)`, no revert |
| 6 | `amountIn` exceeds total orderbook depth | Fill what exists, refund rest |
| 7 | `deadline` passed | Revert `DeadlineExpired` |
| 8 | Taker not approved | Revert at `safeTransferFrom` |
| 9 | Taker balance insufficient | Revert at `safeTransferFrom` |
| 10 | Market not found | Revert `MarketNotFound` |
| 11 | Market expired | Revert `MarketExpired` |
| 12 | Market resolved | Revert `MarketResolved` |
| 13 | Market in refund mode | Revert `MarketInRefundMode` |
| 14 | Market paused | Revert `MarketPaused` |
| 15 | Self-match (complementary) | Revert `SelfMatchNotAllowed` |
| 16 | Self-match (synthetic) | Revert `SelfMatchNotAllowed` |
| 17 | Maker order cancelled mid-loop | Skip, continue |
| 18 | Maker order fully filled mid-loop | Skip, continue |
| 19 | Corrupt maker order (`depositLocked = 0`) | Skip, continue |
| 20 | Tie: complementary price == synthetic effective price | Prefer complementary (gas cheaper) |
| 21 | Rounding produces `fillAmount = 0` | Break loop naturally |
| 22 | Diamond `splitPosition` reverts (safety cap) | Bubble up, tx reverts |
| 23 | Reentrancy attempt | Blocked by `nonReentrant` |
| 24 | Non-EOA caller (contract) | Supported — Exchange doesn't care about caller type |
| 25 | `recipient` is contract that rejects tokens | Transfer reverts, tx reverts atomically |
| 26 | Partial fill at exactly order depth | Fully fills that order, removes from book |
| 27 | Multiple orders at same price level | Each iteration picks one (1 iter = 1 order) |
| 28 | Dust in fund refund (sub-wei) | Not possible — integer math exact |
| 29 | Overflow in `matchAmount * price` | Solidity 0.8+ auto-reverts |
| 30 | Zero best price | `_peekBest` returns 0, source marked empty |

---

## 6. Security Invariants

### 6.1 State Invariants

| Invariant | Description |
|-----------|-------------|
| **I1: Exchange USDC balance** | `balanceOf(exchange) == sum(orders.depositLocked where side is BUY) + accumulated fees` |
| **I2: Exchange token balance** | `balanceOf(exchange, yesToken) == sum(orders.depositLocked where side is SELL_YES)` (same for NO) |
| **I3: No taker residuals** | After `fillMarketOrder` returns, no `taker` funds remain in Exchange |
| **I4: Maker filled monotonic** | `orders[id].filled` only increases, never decreases |
| **I5: Maker depositLocked monotonic** | `orders[id].depositLocked` only decreases, never increases (except at placeOrder) |
| **I6: Collateral invariant** | `YES.totalSupply == NO.totalSupply == market.totalCollateral` (preserved through MINT/MERGE) |

### 6.2 Transaction Invariants

| Invariant | Description |
|-----------|-------------|
| **T1: Atomic** | `fillMarketOrder` either fully succeeds or reverts completely |
| **T2: Deadline** | `block.timestamp <= deadline` at execution |
| **T3: Exact refund** | `taker` receives `amountIn - cost` input back |
| **T4: Limit respected** | No fill occurs above `limitPrice` (buy) or below `limitPrice` (sell) |
| **T5: Cost ≤ amountIn** | Exchange never consumes more than pulled |
| **T6: Filled ≥ 0** | Output amount is non-negative |

### 6.3 Attack Resistance

| Attack | Defense |
|--------|---------|
| **Reentrancy via token callback** | `nonReentrant` modifier |
| **Malicious `taker` param (spend victim's funds)** | `safeTransferFrom` fails if victim hasn't approved Exchange |
| **Flash loan attack on orderbook** | No — CLOB state is discrete, not susceptible to flash price manipulation |
| **MEV sandwich (front/back-run)** | Mitigated by `limitPrice` caller-supplied cap; additional MEV protection in Hook layer (for AMM path, not Exchange) |
| **Griefing via dust order spam** | Bounded by `maxFills` — attacker wastes their own gas placing orders |
| **Deadline bypass** | Strict `block.timestamp > deadline` check |
| **Self-trade wash** | `SelfMatchNotAllowed` in both complementary and synthetic paths |
| **Corrupt order state exploit** | Defensive skip (`depositLocked == 0`, `cancelled`, `filled >= amount`) |

---

## 7. File Changes

| File | Change Type | Lines Affected (approx) |
|------|-------------|-------------------------|
| `src/exchange/IPrediXExchange.sol` | MODIFY | ~60 lines: new error types, `TakerFilled` event, new function sigs |
| `src/exchange/PrediXExchange.sol` | REFACTOR | ~400 lines: new taker path, preview fn, helpers; maker path unchanged |
| `test/exchange/PrediXExchangeTaker.t.sol` | NEW | ~900 lines: taker path tests |
| `test/exchange/PrediXExchangePreview.t.sol` | NEW | ~300 lines: preview simulation tests |
| `test/exchange/PrediXExchangeFuzz.t.sol` | NEW | ~400 lines: fuzz + invariants |
| `script/DeployExchange.s.sol` | NEW | ~80 lines |

**Untouched:**
- Maker path (`placeOrder`, `cancelOrder`, `_tryComplementary`, `_tryMint`, `_tryMerge`)
- Storage layout (orders, queues, bitmap, userOrderCount)
- View functions except `previewFillMarketOrder`

---

## 8. Testing Requirements

### 8.1 Taker Path Unit Tests — `test/exchange/PrediXExchangeTaker.t.sol`

| # | Test | Assertion |
|---|------|-----------|
| 1 | `test_fillMarketOrder_complementaryOnly` | Matches direct SELL_YES, no synthetic |
| 2 | `test_fillMarketOrder_syntheticMintOnly` | Only BUY_NO makers, uses MINT |
| 3 | `test_fillMarketOrder_syntheticMergeOnly` | Only SELL_NO makers, uses MERGE |
| 4 | `test_fillMarketOrder_mixedWaterfall` | Both sources present, cheapest picked first |
| 5 | `test_fillMarketOrder_tieBreaker_prefersComplementary` | Equal price → complementary wins (gas) |
| 6 | `test_fillMarketOrder_limitPriceRespected_buy` | No fill above cap |
| 7 | `test_fillMarketOrder_limitPriceRespected_sell` | No fill below floor |
| 8 | `test_fillMarketOrder_maxFills_bounded` | `maxFills=3` limits iterations |
| 9 | `test_fillMarketOrder_maxFills_zero_uses_default` | `0` → 10 iterations |
| 10 | `test_fillMarketOrder_deadline_expired` | Revert `DeadlineExpired` |
| 11 | `test_fillMarketOrder_refunds_unused` | Exact refund of `amountIn - cost` |
| 12 | `test_fillMarketOrder_empty_clob` | Return `(0, 0)`, refund all |
| 13 | `test_fillMarketOrder_self_match_complementary_reverts` | |
| 14 | `test_fillMarketOrder_self_match_synthetic_reverts` | |
| 15 | `test_fillMarketOrder_taker_not_approved_reverts` | |
| 16 | `test_fillMarketOrder_market_expired_reverts` | |
| 17 | `test_fillMarketOrder_market_resolved_reverts` | |
| 18 | `test_fillMarketOrder_market_paused_reverts` | |
| 19 | `test_fillMarketOrder_market_refund_mode_reverts` | |
| 20 | `test_fillMarketOrder_takerFilled_event_emitted` | Event captures taker, recipient, totals |
| 21 | `test_fillMarketOrder_orderMatched_event_per_fill` | One per match |
| 22 | `test_fillMarketOrder_recipient_different_from_taker` | Output goes to recipient, refund to taker |
| 23 | `test_fillMarketOrder_multi_level_waterfall` | 5 price levels, correct fill order |
| 24 | `test_fillMarketOrder_stops_when_budget_exhausted` | |
| 25 | `test_fillMarketOrder_synthetic_collateral_invariant` | After MINT: `YES.supply == NO.supply == totalCollateral` |

### 8.2 Preview Tests — `test/exchange/PrediXExchangePreview.t.sol`

| # | Test | Assertion |
|---|------|-----------|
| 1 | `test_preview_matches_actualFill` | `preview(...) == fill(...)` for same inputs |
| 2 | `test_preview_no_state_mutation` | State unchanged after preview |
| 3 | `test_preview_no_events_emitted` | Zero events |
| 4 | `test_preview_empty_clob` | Returns `(0, 0)` |
| 5 | `test_preview_virtual_consumption_tracking` | Multi-iteration doesn't re-pick same order |

### 8.3 Fuzz + Invariant Tests

```solidity
function testFuzz_fillMarketOrder_refundExact(
    uint256 amountIn,
    uint8 orderCount,
    uint256 seed
) public {
    amountIn = bound(amountIn, 1e6, 10000e6);
    orderCount = uint8(bound(orderCount, 0, 20));
    _populateOrderbook(orderCount, seed);
    
    uint256 balanceBefore = IERC20(usdc).balanceOf(taker);
    IERC20(usdc).approve(address(exchange), amountIn);
    
    (uint256 filled, uint256 cost) = exchange.fillMarketOrder(
        marketId, Side.BUY_YES, 500000, amountIn, taker, taker, 10, block.timestamp + 1
    );
    
    uint256 balanceAfter = IERC20(usdc).balanceOf(taker);
    uint256 spent = balanceBefore - balanceAfter;
    
    assertEq(spent, cost, "refund must be exact");
    assertLe(cost, amountIn, "cost cannot exceed input");
}

function invariant_exchange_usdc_balance_matches_maker_locks() public {
    uint256 balance = IERC20(usdc).balanceOf(address(exchange));
    uint256 totalLocked = _sumLockedUSDCFromAllOrders();
    uint256 feeBalance = _protocolFeeBalance();
    assertEq(balance, totalLocked + feeBalance);
}

function invariant_taker_no_residual() public {
    // After any taker handler action, taker's token balances don't grow
    // (this is tricky because external transfers can happen; use delta tracking)
}

function invariant_collateral_preserved() public {
    IMarketBase.MarketData memory m = diamond.getMarket(marketId);
    assertEq(IERC20(m.yesToken).totalSupply(), IERC20(m.noToken).totalSupply());
    assertEq(IERC20(m.yesToken).totalSupply(), m.totalCollateral);
}
```

### 8.4 Gas Budget (post-audit amendment)

| Function | Scenario | Target (max) |
|----------|----------|--------------|
| `fillMarketOrder` | CLOB empty | ≤ 80k gas |
| `fillMarketOrder` | 1 complementary fill | ≤ 260k gas |
| `fillMarketOrder` | 1 synthetic MINT fill | ≤ 260k gas |
| `fillMarketOrder` | 1 synthetic MERGE fill | ≤ 260k gas |
| `fillMarketOrder` | 3 fills mixed | ≤ 700k gas |
| `fillMarketOrder` | 10 fills (max default cap) | ≤ 1.8M gas |
| `previewFillMarketOrder` | 3 fills | ≤ 80k gas (view) |
| `placeOrder` | baseline | ~260k gas |
| `cancelOrder` | baseline | ~100k gas |

#### Gas budget rationale (post-audit amendment)

Targets updated after audit fix implementation in E2-E5. The original budget was
written from a pre-audit baseline of ~120k per fully-filled maker. Each audit fix
mandated by `REVIEW_EXCHANGE.md` adds correctness-critical overhead:

| Audit fix | Cost | Required by |
|---|---|---|
| H-01 (M1) `_decrementOrderCount` on full fill | +5–22k per fill | review §M1 |
| M5 `_removeFromQueue` swap-pop + bitmap clear | +10–25k per fill | review §M5 |
| Option 4 dust filter in execute helpers | +0–5k per call (skipped fills) | E5 reviewer |
| Option 4 dust sweep on terminal-state cleanup | +0–22k per terminal | E5 reviewer |

Total audit overhead: ~30–50k per fully-filled maker. Pre-audit `120k × 10 fills = 1.2M`
plus audit overhead `~480k` ⇒ realistic post-audit max ~**1.68M** for 10-fill default-cap
scenario. New target **1.8M** provides ~7% margin above observed worst case.

These fixes are correctness-mandatory (audit H-01 / H-02 / solvency invariant) and
cannot be removed for a gas refund.

**Economic context:** Unichain (target chain) at typical L2 pricing → 1.68M gas ≈
~$0.0003 per worst-case 10-fill call. Median observed 165k/fill (typical 1–3 fill
trades) → ~$0.00003 per call. Well within retail prediction-market trader cost
envelopes.

**Scenario annotation** (worst-case test):
`test_fillMarketOrder_maxFills_zero_uses_default` exercises 12 maker orders placed
1-share each at distinct ascending tick prices ($0.50–$0.61), then a single
`fillMarketOrder(BUY_YES)` consumes the first 10 via pure complementary matching
(no synthetic MINT/MERGE). Each fill: peek best bit, walk queue (1 entry post-M5),
execute helper with effects + safeTransfer × 2, M5 cleanup (queue swap-pop + bitmap
clear because the level becomes empty), M1 decrement, dust sweep. 100% complementary,
0% synthetic — represents the cleanest per-fill cost; mixed-source workloads sit
slightly lower because the loop can break earlier on `limitPrice`.

---

## 9. Task Tracker

### ☐ Phase E1 — Interface Update (Day 1)

**Tasks:**
- E1.1 In `IPrediXExchange.sol`:
  - Update `fillMarketOrder` signature: rename `maxPrice` → `limitPrice`, add `maxFills`, add `deadline`
  - Add `TakerFilled` event
  - Add `previewFillMarketOrder` view function
  - Add new errors: `DeadlineExpired`, `MarketInRefundMode`, `MarketPaused`, `ZeroAmount`
- E1.2 Delete old taker-path error references if any

**Exit Gate:**
```bash
cd Smart_Contract_V2
forge build 2>&1 | tail -5
grep -c "limitPrice\|maxFills\|deadline" src/exchange/IPrediXExchange.sol  # must show new fields
grep "event TakerFilled" src/exchange/IPrediXExchange.sol
grep "function previewFillMarketOrder" src/exchange/IPrediXExchange.sol
```

### ☐ Phase E2 — Taker Path Core (Day 2-4)

**Tasks:**
- E2.1 Add constants: `DEFAULT_MAX_FILLS`, `FillSource` enum
- E2.2 Implement `_validateMarketActive` (expanded with refund mode + pause check)
- E2.3 Implement `_sidesFor(takerSide)` helper
- E2.4 Implement `_peekBest(marketId, side)` helper (read-only, skips dead orders)
- E2.5 Implement `_computeFillAmount(...)` helper
- E2.6 Implement `_pickBestSource(...)` (4-way waterfall comparator)
- E2.7 Rewrite `fillMarketOrder` with upfront pull + loop + refund
- E2.8 Implement `_executeComplementaryTakerFill` (extract from existing if possible)
- E2.9 Implement `_executeSyntheticTakerFill` with MINT and MERGE cases
- E2.10 Add `_ensureDiamondApproval` + `_inputTokenFor` / `_outputTokenFor` helpers

**Exit Gate:**
```bash
forge build 2>&1 | tail -5
forge test --match-test "test_fillMarketOrder_complementaryOnly|test_fillMarketOrder_syntheticMintOnly|test_fillMarketOrder_syntheticMergeOnly" -vv
```

### ☐ Phase E3 — Preview Function (Day 5)

**Tasks:**
- E3.1 Implement `previewFillMarketOrder` as pure view
- E3.2 Implement `_pickBestSourceVirtual` helper that tracks virtual consumption
- E3.3 Ensure no state mutation, no events

**Exit Gate:**
```bash
forge test --match-path "test/exchange/PrediXExchangePreview.t.sol" -vv
```

### ☐ Phase E4 — Unit Tests (Day 6-7)

**Tasks:**
- E4.1 Write all 25 tests in `PrediXExchangeTaker.t.sol`
- E4.2 Write all 5 tests in `PrediXExchangePreview.t.sol`

**Exit Gate:**
```bash
forge test --match-path "test/exchange/*" -vv
```

All pass.

### ☐ Phase E5 — Fuzz + Invariant (Day 8)

**Tasks:**
- E5.1 Implement fuzz tests per §8.3
- E5.2 Implement invariant tests
- E5.3 Run `--fuzz-runs 10000` + `--invariant-runs 256`

**Exit Gate:**
```bash
forge test --match-test "testFuzz_|invariant_" --fuzz-runs 10000
```

### ☐ Phase E6 — Gas Benchmark (Day 9)

**Tasks:**
- E6.1 Record gas via `forge snapshot`
- E6.2 Assert each scenario within target (§8.4)
- E6.3 Commit `.gas-snapshot`

**Exit Gate:**
```bash
forge snapshot --check .gas-snapshot
```

### ☐ Phase E7 — Deploy (Day 10)

**Tasks:**
- E7.1 Write `script/DeployExchange.s.sol`
- E7.2 Deploy to Unichain Sepolia
- E7.3 Verify on `sepolia.uniscan.xyz`
- E7.4 Update `DEPLOYED_ADDRESSES.md`
- E7.5 Smoke test: `placeOrder`, `cancelOrder`, `fillMarketOrder` each on testnet

**Exit Gate:**
- Contract verified
- Smoke tests succeed

---

## 10. Verification Commands

```bash
cd /Users/keyti/Sources/PrediX_Uni_V4/Smart_Contract_V2

# Build
forge build 2>&1 | tail -5

# All exchange tests
forge test --match-path "test/exchange/*" -vv

# Gas snapshot
forge snapshot --check .gas-snapshot

# Fuzz + invariant
forge test --match-test "testFuzz_|invariant_" --fuzz-runs 10000 --invariant-runs 256

# Slither
slither src/exchange/PrediXExchange.sol --exclude-informational
```

---

## 11. Decision Log

| # | Question | Decision | Rationale |
|---|----------|----------|-----------|
| Q1 | Access control on `fillMarketOrder`? | **None — permissionless** | Core protocol philosophy. Any caller welcome. |
| Q2 | Rename `maxPrice` → ? | **`limitPrice`** | Neutral for buy and sell semantics |
| Q3 | Add `deadline` parameter? | **Yes** | Industry standard. Protects stale mempool tx. |
| Q4 | Add `maxFills` parameter? | **Yes, dynamic, 0 = default 10** | Caller controls gas budget |
| Q5 | Hard upper cap on `maxFills`? | **No** | Natural gas limit is the ceiling |
| Q6 | Pull strategy: lazy or upfront? | **Upfront + refund unused** | Saves ~400k gas |
| Q7 | Dust handling | **Exact refund** (integer math ensures no sub-wei dust) | Simplest |
| Q8 | Preview function? | **Yes — `previewFillMarketOrder`** | Callers simulate without reimplementing waterfall |
| Q9 | `TakerFilled` event? | **Yes** | Indexer attribution for taker |
| Q10 | Self-match in synthetic path? | **Blocked** | Consistent with complementary path |
| Q11 | Surplus in taker synthetic? | **None possible** | Taker effective price = 1 - makerPrice (always sums to 1) |
| Q12 | Expand `_validateMarketActive`? | **Yes** — add refund mode + paused checks | Completeness |
| Q13 | 1 iteration = 1 order or 1 price level? | **1 order** | Simpler, gas predictable |
| Q14 | Legacy `fillMarketOrder` alongside new? | **No — replace in place** | Dead code = audit surface |
| Q15 | Preview gas cost vs accuracy | **Accept preview cost** (~80k) for 3 fills | Caller uses off-chain `eth_call` (free) |
| Q16 | `MARKET_MODULE` constant location | **Shared in Constants.sol** | Cross-contract reference |

---

## 12. Non-Goals

- ❌ Access control on taker path
- ❌ AMM integration (Exchange is CLOB only)
- ❌ `minOut` slippage check (caller responsibility)
- ❌ Multi-market atomic fills (one marketId per call)
- ❌ Dynamic fee schedule for taker path (handled by Hook for AMM path only)
- ❌ Gasless execution / meta-transactions
- ❌ Maker path changes (`placeOrder` unchanged)
- ❌ Storage layout changes
- ❌ New maker matching phases

---

## 13. Dependencies

- **Diamond (MarketFacet)**: `splitPosition`, `mergePositions`, `getMarket`, `isRefundMode` — unchanged
- **PausableFacet**: `paused(module)` — unchanged
- **IERC20**: standard OpenZeppelin — unchanged
- **OutcomeToken**: standard ERC-20 minted by Diamond — unchanged

No dependencies on Router or any other contract. Exchange is fully self-contained.

---

*Created: 2026-04-14*
*Status: READY FOR IMPLEMENTATION*
*Estimated effort: 10 days (1 developer)*
*Greenfield — no migration, no back-compat constraints.*
