# PrediX V2 Smart Contracts — Developer Guide

## Dự án làm gì?

PrediX là **prediction market protocol** on-chain. User đặt cược vào kết quả sự kiện (BTC có vượt $100K không? Ai thắng bầu cử?). Mỗi market có 2 token: **YES** và **NO**. Giá YES + NO luôn = $1. Nếu kết quả là Yes → YES token = $1, NO = $0. Ngược lại.

Giao dịch qua **2 nguồn thanh khoản**: on-chain orderbook (CLOB) giống sàn CEX, và AMM pool trên Uniswap v4. Router tự động chọn nguồn tốt nhất cho user trong 1 transaction.

---

## Kiến trúc tổng quan

```
User
  ↓
Router (stateless, điều phối CLOB + AMM)
  ├── Exchange (on-chain orderbook — limit orders)
  ├── PoolManager (Uniswap v4 — AMM swap)
  │     └── Hook (custom logic: dynamic fee, anti-sandwich)
  └── Diamond (market engine — tạo market, mint/burn token, resolve)
        └── Oracle (báo kết quả: Manual hoặc Chainlink)
```

7 packages, tất cả Solidity 0.8.34:

| Package | Vai trò | Proxy? |
|---|---|---|
| **diamond** | Market engine — tạo/resolve market, mint/burn YES/NO, quản lý collateral | EIP-2535 Diamond |
| **hook** | Uniswap v4 hook — dynamic fee, anti-sandwich, pool binding | ERC-1967 proxy |
| **exchange** | On-chain CLOB — limit orders, matching engine | ERC-1967 proxy |
| **router** | User-facing aggregator — CLOB + AMM routing | Stateless (no proxy) |
| **oracle** | Báo kết quả market | Standalone |
| **shared** | Constants, interfaces, utilities | N/A |
| **paymaster** | Gas sponsorship cho smart account users | Standalone |

---

## Diamond — Market Engine

Diamond là trung tâm protocol, dùng **EIP-2535 Diamond proxy** — 1 address chứa nhiều "facets" (modules), mỗi facet chịu trách nhiệm 1 nhóm chức năng. Upgrade bằng cách thêm/bỏ/thay facets mà không đổi address.

### Facets

#### MarketFacet — Lifecycle của 1 market

```
createMarket("Will BTC hit $100K?", endTime, oracleAddress)
  → Deploy 2 ERC-20 tokens: YES + NO
  → marketId = auto-increment counter

splitPosition(marketId, 100 USDC)
  → User nạp 100 USDC, nhận 100 YES + 100 NO
  → Collateral locked trong Diamond

mergePositions(marketId, 50)
  → User burn 50 YES + 50 NO, nhận lại 50 USDC

resolveMarket(marketId)
  → Đọc kết quả từ Oracle
  → Set isResolved = true, outcome = true/false

redeem(marketId)
  → Nếu outcome = Yes: burn YES token, nhận USDC (trừ fee)
  → Nếu outcome = No: burn NO token, nhận USDC (trừ fee)
  → Token thua = worthless
```

Emergency paths:

- `emergencyResolve` — OPERATOR force-resolve khi oracle fail (phải chờ 7 ngày sau endTime)
- `enableRefundMode` — ADMIN bật refund khi oracle bị compromise → user rút collateral pro-rata
- `sweepUnclaimed` — ADMIN thu hồi collateral chưa claim sau 365 ngày

Admin config: fee recipient, market creation fee, per-market cap, oracle whitelist, redemption fee (max 15%, có snapshot protection — admin không thể tăng fee retroactive sau khi market tạo).

#### EventFacet — Multi-outcome markets

```
createEvent("Ai thắng bầu cử?", ["Trump", "Biden", "RFK"], endTime)
  → Tạo 1 event group + 3 child binary markets
  → Mỗi child = 1 market với YES/NO riêng

resolveEvent(eventId, winningIndex=0)
  → Child 0 (Trump): outcome = true
  → Child 1 (Biden): outcome = false
  → Child 2 (RFK): outcome = false
  → Atomic — tất cả resolve trong 1 tx
```

Child markets không thể resolve riêng lẻ — phải qua `resolveEvent`.

#### AccessControlFacet — Role-based access

| Role | Ai | Quyền |
|---|---|---|
| DEFAULT_ADMIN | Deployer/Multisig | Grant/revoke mọi role |
| ADMIN | Operations team | Config fee, cap, oracle whitelist |
| OPERATOR | Operations team | Emergency resolve, resolve events |
| PAUSER | Operations team | Pause/unpause modules |
| CREATOR | Authorized creators | Tạo market/event |
| CUT_EXECUTOR | Timelock only | Upgrade Diamond facets |

CUT_EXECUTOR tự quản lý (self-administered) — DEFAULT_ADMIN không thể grant cho ai khác, chỉ Timelock contract mới có.

#### PausableFacet — 2 cấp pause

- Global pause: freeze toàn bộ
- Per-module: pause riêng MARKET hoặc DIAMOND
- **Quan trọng**: `redeem`, `refund`, `cancelOrder` bypass pause — user luôn rút được tiền

### Storage pattern

Diamond dùng **namespaced storage** — mỗi module có slot riêng (keccak256 hash), không conflict khi upgrade:

```solidity
keccak256("predix.storage.market.v1")  → marketCount, markets mapping
keccak256("predix.storage.config.v1")  → collateralToken, feeRecipient, fees, caps
keccak256("predix.storage.access.v1")  → roles mapping
keccak256("predix.storage.event.v1")   → eventCount, events mapping
```

Append-only — thêm field mới ở cuối struct, không bao giờ reorder hay xóa.

---

## Exchange — On-Chain CLOB

Orderbook trên chain, giống CEX nhưng non-custodial.

### 4 loại order (Side enum)

- `BUY_YES` — Mua YES bằng USDC
- `SELL_YES` — Bán YES lấy USDC
- `BUY_NO` — Mua NO bằng USDC
- `SELL_NO` — Bán NO lấy USDC

### Maker path — Đặt limit order

```solidity
placeOrder(marketId, BUY_YES, price=500000, amount=100e6)
  // "Tôi muốn mua 100 YES ở giá 50¢"
  // Lock 50 USDC (100 x 0.5)
  // Tự động match nếu có order đối diện
```

Matching engine có **3 loại fill**:

1. **COMPLEMENTARY** — Match trực tiếp với order ngược chiều (BUY_YES vs SELL_YES)
2. **MINT** — 2 order cùng chiều khác token (BUY_YES + BUY_NO) → mint YES+NO pair từ USDC
3. **MERGE** — 2 order bán khác token (SELL_YES + SELL_NO) → burn YES+NO pair, trả USDC

### Taker path — Market order

```solidity
fillMarketOrder(marketId, BUY_YES, limitPrice, usdcIn, taker, recipient, maxFills, deadline)
  // Sweep orderbook: fill từ giá tốt nhất
  // Waterfall: COMPLEMENTARY trước → MINT/MERGE sau
  // maxFills cap số orders match (gas protection)
```

### Cấu trúc orderbook

- Price levels: 1¢ → 99¢ (100 ticks, `PRICE_TICK = 10000`)
- `priceBitmap`: 1 bit per price level → O(1) tìm best price
- FIFO queue per price level (max 200 orders/level)
- Per-user limit: 50 open orders

### Pause behavior

Pause chặn `placeOrder` (maker), nhưng `fillMarketOrder` và `cancelOrder` luôn mở — user luôn exit được.

---

## Hook — Uniswap v4 Custom Logic

Hook gắn vào Uniswap v4 PoolManager, can thiệp vào mọi swap/LP action trên PrediX pools.

### Enabled callbacks

| Callback | Làm gì |
|---|---|
| `beforeInitialize` | Validate pool key khớp market, init price trong ±5% quanh 50¢ |
| `beforeAddLiquidity` | Block LP vào market đã resolve/expired/refund |
| `beforeRemoveLiquidity` | Luôn cho phép — LP luôn rút được |
| `beforeSwap` | Check market active, resolve identity, detect sandwich, tính dynamic fee |
| `afterSwap` | Emit telemetry (volume, price, direction), ghi referral nếu có |
| `beforeDonate` | Block donate vào market đã resolve/expired |

### Dynamic fee — Phí swap tăng dần khi gần expiry

```
>7 ngày  → 0.5%  (FEE_NORMAL)
3-7 ngày → 1.0%  (FEE_MEDIUM)
1-3 ngày → 2.0%  (FEE_HIGH)
<1 ngày  → 5.0%  (FEE_VERY_HIGH)
```

Lý do: Gần expiry, trader biết outcome gần chắc chắn → exploit LP. Phí cao bù rủi ro cho LP.

### Anti-sandwich — Persistent storage tracking

```solidity
_lastSwap[keccak256(marketId, identity)] = { blockNumber, directionBits }
```

Nếu cùng identity swap **ngược chiều** trong cùng block → revert `Hook_SandwichDetected`. Chặn front-run/back-run.

### Identity commit — Router commit user identity trước swap

```solidity
// Router gọi trước khi unlock:
hook.commitSwapIdentity(userAddress, poolId)
  → Lưu vào transient storage (EIP-1153)
  → beforeSwap đọc identity từ transient slot
  → Chỉ trusted routers mới commit được
```

### Pool binding — 1 market ↔ 1 pool

```solidity
hook.registerMarketPool(marketId, poolKey)
  → Validate: market tồn tại trên Diamond
  → Validate: currency pair = (USDC, yesToken) hoặc ngược
  → Validate: fee + tickSpacing khớp canonical config
  → Lưu binding: poolId → (marketId, yesIsCurrency0)
```

Permissionless — ai cũng register được, nhưng pool key phải khớp market on-chain.

### Governance — 48h timelocked (sau bootstrap)

- `proposeDiamond` → 48h → `executeDiamondRotation`
- `proposeTrustedRouter` → 48h → `executeTrustedRouter`
- `proposeUnregisterMarketPool` → 48h → `executeUnregisterMarketPool`
- Admin rotation: `setAdmin` → 48h → `acceptAdmin`

### Proxy (PrediXHookProxyV2)

- ERC-1967 proxy, address salt-mined (hook permissions encoded trong address)
- Upgrade: 48h timelock, propose → execute
- Timelock duration: monotonic increase only (không giảm được)
- Admin rotation: 2-step, 48h delay

---

## Router — User-Facing Aggregator

Router là entry point cho user trade. **Stateless** — không hold fund giữa calls.

### 4 flows

`buyYes`, `sellYes`, `buyNo`, `sellNo` (+ Permit2 variants)

### Execution flow (ví dụ buyYes)

```
1. Lấy AMM spot price → dùng làm price cap cho CLOB
2. CLOB fill trước (try/catch — CLOB fail không block trade)
3. Nếu còn size → AMM fill phần còn lại
4. Check minOut
5. Transfer output cho recipient
6. Assert router balance = 0 (safety invariant)
```

### Virtual-NO — buyNo/sellNo không có NO pool trực tiếp

```
buyNo:
  1. Flash-sell YES trên AMM (nhận USDC)
  2. Dùng USDC proceeds + user input → splitPosition (mint YES+NO)
  3. Trả YES lại pool, giữ NO cho user

sellNo:
  1. Flash-buy YES trên AMM (mượn USDC)
  2. Merge YES + NO (burn pair, nhận USDC)
  3. Trả USDC lại pool, giữ lời cho user
```

### CLOB-only support

Nếu market không có AMM pool:

- `_hasPool(yesToken)` check slot0 từ PoolManager
- Pool không tồn tại → CLOB cap = permissive, skip AMM
- Trade chỉ fill từ orderbook

### Safety

- `_finalizeAndAssertAllZero` — cuối mỗi trade assert YES/NO/USDC balance trong router = 0
- `ClobSkipped` event khi CLOB revert (log selector cho debug)
- `nonReentrant` trên mọi entry point

---

## MarketFactory — Batch Helper

Gom các bước **cần atomic ordering với hook registration** vào 1 tx:

```solidity
factory.createMarketWithPool(question, endTime, oracle, usdcBudget)
  // 1. createMarket trên Diamond
  // 2. registerMarketPool trên Hook (bind poolKey ↔ marketId)
  // 3. PoolManager.initialize(poolKey, sqrtPriceMid)
  // → emit MarketCreatedWithPool(marketId, creator)

factory.createEventWithPools(name, questions[], endTime, oracle, usdcBudget)
  // Tương tự nhưng cho event + N child markets
  // → emit EventCreatedWithPools(eventId, marketIds, creator)
```

Access: Caller phải có **CREATOR_ROLE** trên Diamond. Factory tự có CREATOR_ROLE riêng.

`usdcBudget` chỉ để pass-through cho `marketCreationFee` (diamond pull từ factory).
Phần dư được refund đồng bộ trong cùng tx; factory không giữ funds giữa các call.

### LP provisioning — bước riêng (không nằm trong factory)

Audit M-05 (pass-2) đã loại bỏ LP code khỏi factory. Lý do: factory cũ gọi
`PoolModifyLiquidityTest` (v4-core test harness — không có NFT position, không
Permit2, không transferable receipt). Mainnet routing đi qua canonical v4
**PositionManager** (`@uniswap/v4-periphery`).

Flow chuẩn để tạo market kèm LP:

```text
1. factory.createMarketWithPool(...)
     → emit MarketCreatedWithPool(marketId, creator)
     → off-chain tooling reconstruct poolKey từ marketId (deterministic)
2. diamond.splitPosition(marketId, usdcAmount)
     → mint YES + NO tokens cho creator
3. permit2.approve(YES, positionManager, ...)
   permit2.approve(USDC, positionManager, ...)
4. positionManager.modifyLiquidities(...) — multicall encoded:
     - MINT_POSITION với poolKey + tickRange + liquidityDelta
     - SETTLE_PAIR cho YES + USDC
     - SWEEP để refund dust
```

Sepolia smoke-test vẫn dùng `PoolModifyLiquidityTest` qua
`scripts/testnet/80_phase3_pool.sh` (bypass factory) — chỉ cho testnet, không
phải mainnet path.

---

## Oracle — Report Kết Quả

### ManualOracle — Operator báo kết quả

```solidity
oracle.report(marketId, outcome=true)   // REPORTER_ROLE
  → Chỉ gọi được sau market.endTime
  → 1 lần duy nhất per market

oracle.revoke(marketId)                 // DEFAULT_ADMIN
  → Xóa kết quả, freeze slot (không report lại được)
  → Admin phải bật refundMode trên Diamond
```

### ChainlinkOracle — Tự động từ price feed

```solidity
oracle.register(marketId, feedAddress, threshold=100000e8, gte=true, snapshotAt)
  // "Nếu BTC >= $100K tại thời điểm snapshotAt → Yes"

oracle.resolve(marketId, roundIdHint, prevRoundIdHint)
  // Permissionless — ai cũng gọi được sau snapshotAt
  // Verify round brackets snapshotAt (chống manipulation)
  // L2 sequencer health check
```

Cả 2 implement chung interface `IOracle`:

```solidity
interface IOracle {
    function isResolved(uint256 marketId) external view returns (bool);
    function outcome(uint256 marketId) external view returns (bool);
}
```

Diamond gọi interface này khi `resolveMarket` → pluggable, thêm oracle mới bất cứ lúc nào.

---

## Outcome Token

Mỗi market deploy 2 **ERC-20** token (YES + NO):

```solidity
contract OutcomeToken is ERC20, ERC20Permit {
    address immutable factory;  // = Diamond address
    uint256 immutable marketId;
    bool    immutable isYes;
    uint8   constant decimals = 6;  // khớp USDC

    function mint(to, amount) external onlyFactory { ... }
    function burn(from, amount) external onlyFactory { ... }
}
```

- Chỉ Diamond mint/burn được (qua `splitPosition`/`mergePositions`/`redeem`)
- Standard ERC-20 → transfer/approve/LP bình thường
- EIP-2612 permit support

---

## Security Model

### Reentrancy

`TransientReentrancyGuard` (EIP-1153) — tload/tstore, auto-clear cuối tx, rẻ hơn storage slot. Trên mọi external entry point của Diamond, Exchange, Router.

### Token safety

`SafeERC20.safeTransfer/safeTransferFrom` toàn bộ. Outcome tokens là standard ERC-20 (mint chỉ bởi Diamond), USDC assumed 6-decimal no-fee.

### Upgrade safety

- Diamond: CUT_EXECUTOR_ROLE → chỉ Timelock (48h delay)
- Hook proxy: 48h upgrade timelock, monotonic increase
- Exchange proxy: 48h upgrade timelock
- Storage: append-only, không reorder

### Admin safety

- Admin rotation: 2-step, 48h delay (chống instant takeover)
- Fee snapshot: per-market fee override bounded by default tại lúc tạo market (chống retroactive fee hike)
- Redemption/refund bypass pause (user luôn exit)
- Emergency resolve: 7 ngày delay sau endTime
- Sweep unclaimed: 365 ngày grace period

### Anti-MEV

- Anti-sandwich: persistent storage per-(marketId, identity), block opposite-direction same-block
- Dynamic fee: phí cao gần expiry, giảm incentive exploit LP
- Identity commit: transient storage, chỉ trusted routers

---

## Data Flow — User mua YES

```
1. User gọi Router.buyYes(marketId, 100 USDC, minOut=180 YES)
2. Router pull 100 USDC từ user
3. Router query AMM spot price → 52¢ → dùng làm CLOB cap
4. Router gọi Exchange.fillMarketOrder(BUY_YES, cap=52¢, 100 USDC)
   → Exchange match 60 USDC x 2 orders @ 50¢ → 120 YES
   → Trả 120 YES + 40 USDC unused về Router
5. Router còn 40 USDC → gọi PoolManager.unlock()
   → Hook.commitSwapIdentity(user, poolId)
   → AMM swap: 40 USDC → 74 YES
6. Total: 120 + 74 = 194 YES >= minOut(180)
7. Router transfer 194 YES cho user
8. Router assert balance = 0
```

---

## Deployed Contracts (Unichain Sepolia)

| Contract | Address | Type |
|---|---|---|
| Diamond | `0x2904bca87379ff3acf3203acea54955c1898b8a3` | EIP-2535 proxy |
| Hook | `0x861e5140b6ce266f9f46a9ef90951b9d83452ae0` | ERC-1967 proxy (salt-mined) |
| Exchange | `0x82159e6605621611ebfcfd81cb7bf22db7e5a0d3` | ERC-1967 proxy |
| Router | `0xb88c45b0f76c7ddab49d1d0733807f2b847a7caa` | Stateless |
| MarketFactory | `0xbcebeb35cbf73ba1ff5da96417670dcd51f66293` | Stateless |
| ManualOracle | `0xfcadc037237e66a38733ab0b71d057b7171f6a66` | Standalone |
| Timelock | `0x48ad90990a1ae213e3510376f13b8d2d65ae8a40` | TimelockController |
| USDC | `0x5a9153c368946b5b252c32921ebb3c16c692d7d4` | TestUSDC |
| Faucet | `0x76c951b6185a2b44e44c98e7a0e9ee59b08760da` | FaucetRelayedV2 |
