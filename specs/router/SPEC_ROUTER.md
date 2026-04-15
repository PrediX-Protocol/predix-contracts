# PrediXRouter — implementation spec

> **Read first**: this spec is self-contained but you MUST also read
> `SC/CLAUDE.md` (hard rules for the entire smart-contract subtree) before
> writing a single line of code. Anything in `CLAUDE.md` overrides this spec.
>
> **Critical context**: there are **two pre-existing design documents** in
> `/Users/keyti/Sources/Final_Predix_V2/`:
> - `PREDIX_ROUTER_DESIGN.md`
> - `PREDIX_ROUTER_EDGE_CASES.md`
>
> They contain useful business logic and edge case analysis, **BUT they were
> written against legacy V1 interfaces** (`IMarket`, `IPausable`,
> `bytes32 marketId`, legacy hook trusted-router pattern). Do NOT port from
> them as-is. This spec REPLACES the parts of those docs that conflict with
> V2; everything in this spec wins. Use the legacy docs as a reference for
> business logic and edge case enumeration, not as a porting source.

---

## 0. What you are building

`PrediXRouter` is the **user-facing aggregator** for the PrediX protocol on
Unichain. It routes binary-prediction-market trades between two liquidity
sources:

1. **`PrediXExchange`** (on-chain CLOB, in `packages/exchange/`)
2. **Uniswap v4 pool** (one pool per market, registered with `PrediXHookV2`)

For each user trade, the router **quotes both sources, picks the cheaper
one, executes against it (CLOB first, AMM for the remainder), and refunds
unused input**.

The router is **stateless** — it holds no funds between transactions, no
state variables, only immutables. It is also **permissionless** — anyone
can call its public functions.

Target chain: **Unichain** (OP Stack L2, 1-second blocks, EIP-1153
transient storage available, full v4 PoolManager + Quoter deployed).

---

## 1. Hard rules (subset of `SC/CLAUDE.md`)

- **Toolchain**: Solidity `0.8.30`, `evm_version = cancun`, `via_ir = true`,
  `optimizer_runs = 200`. Do not change `foundry.toml`.
- **Boundary §2**: router lives in `packages/router/`. It MAY import from:
  - `@openzeppelin/contracts/`
  - `@uniswap/v4-core/`
  - `@uniswap/v4-periphery/`
  - `permit2/`
  - `@predix/shared/` ← **the only PrediX path allowed in `src/`**
  
  It MUST NOT import from `@predix/diamond/`, `@predix/oracle/`,
  `@predix/hook/`, or `@predix/exchange/` from `src/`. Cross-package symbols
  are accessed by interface (defined in `@predix/shared/`) plus address
  (passed to constructor as immutable).
- **Custom errors**, no `require(string)`. Errors declared in interface.
- **Events** declared in interface, indexed where helpful.
- **NatSpec** `@notice` on every external/public function, struct, event,
  error. Implementation contracts use `@inheritdoc`.
- **Reentrancy**: every state-changing public entry uses `nonReentrant`
  from `@predix/shared/utils/TransientReentrancyGuard.sol`.
- **SafeERC20 always** for ERC20 transfers.
- **No `tx.origin`**, no `block.timestamp` for randomness, no
  `selfdestruct`, no hardcoded mainnet addresses (Unichain addresses live in
  the deploy script, not in source).
- **Tests**: every public function gets ≥1 happy + ≥1 revert test; every
  custom error must be triggered; fuzz the math; integration test against
  the real deployed stack.
- **§5.5 scope discipline**: if you find something "would be nice" that's
  not in this spec, **stop and ask**.

---

## 2. What you can rely on (do not rebuild)

The following are already shipped, audited internally, and stable:

### From `@predix/shared/`
- `interfaces/IMarketFacet.sol` — diamond market lifecycle interface
  - `getMarket(uint256) returns (MarketView memory)` — full snapshot, expensive
  - **`getMarketStatus(uint256) returns (address yesToken, address noToken, uint256 endTime, bool isResolved, bool refundModeActive)`** — gas-optimised lightweight read. **Always use this on the hot path.**
  - `splitPosition(uint256, uint256)` — mint YES+NO from USDC
  - `mergePositions(uint256, uint256)` — burn YES+NO, return USDC
- `interfaces/IPausableFacet.sol`
  - `isModulePaused(bytes32 moduleId)` — combines global + module flag
- `interfaces/IAccessControlFacet.sol`
  - `hasRole(bytes32 role, address account)`
- `interfaces/IOutcomeToken.sol` — ERC20 + Permit + factory marker
- `constants/Modules.sol` — `Modules.MARKET = keccak256("predix.module.market")`
- `constants/Roles.sol` — `Roles.PAUSER_ROLE = keccak256("predix.role.pauser")`
- `utils/TransientReentrancyGuard.sol` — EIP-1153 guard

### From the deployed PrediX stack (read via address + interface, never imported from `src/`)
- **Diamond** at `address diamond` — implements `IMarketFacet`, `IPausableFacet`, `IAccessControlFacet`
- **Exchange** at `address exchange` — implements `IPrediXExchange` (interface lives in `packages/exchange/src/IPrediXExchange.sol`; **router needs its own copy of the interface in `src/interfaces/` because cross-package source imports are forbidden**)
- **Hook** at `address hook` — implements `IPrediXHook` (same situation; copy interface to `src/interfaces/`)

### From Uniswap
- `@uniswap/v4-core/src/interfaces/IPoolManager.sol`
- `@uniswap/v4-core/src/interfaces/callback/IUnlockCallback.sol`
- `@uniswap/v4-core/src/types/PoolKey.sol` / `PoolId.sol` / `Currency.sol` / `BalanceDelta.sol`
- `@uniswap/v4-core/src/libraries/StateLibrary.sol`
- **`@uniswap/v4-periphery/src/lens/V4Quoter.sol`** — quoter contract for accurate AMM quotes (resolves audit H-03)

### From Permit2
- `permit2/src/interfaces/IAllowanceTransfer.sol` — Permit2 standard interface

### About interface duplication
`IPrediXExchange.sol` and `IPrediXHook.sol` currently live in their own
packages, and `SC/CLAUDE.md §2` forbids importing from another package's
`src/`. **Copy** the minimal subset of those two interfaces into
`packages/router/src/interfaces/IPrediXExchangeView.sol` and
`packages/router/src/interfaces/IPrediXHookCommit.sol` — only the function
signatures, errors, and events the router actually calls.

This is a deliberate localised duplication, NOT a boundary violation: the
duplicated interfaces sit in `router/src/interfaces/`, are owned by the
router, and never include any implementation. They are local "I want to
talk to a contract that looks like this" stubs. Document the duplication
with a `@dev` block in each interface file pointing at the canonical
location.

**Long-term cleanup** (Phase 2, NOT now): move the cross-package interface
subsets into `@predix/shared/interfaces/` so every package can import them.
Right now this is blocked because the exchange interface is still being
finalised in E2b/E2c.

---

## 3. Legacy → V2 interface mapping (must-read)

Anywhere `PREDIX_ROUTER_DESIGN.md` or `PREDIX_ROUTER_EDGE_CASES.md` says
"call `IMarket(diamond).X(...)`", replace with the V2 mapping below before
writing code:

| Legacy call | V2 call | Notes |
|---|---|---|
| `IMarket(diamond).getMarket(bytes32 marketId)` | `IMarketFacet(diamond).getMarketStatus(uint256 marketId)` | Use lightweight view; returns 5 fields, no `string question` allocation |
| `IMarket(diamond).isRefundMode(marketId)` | (read `refundModeActive` from `getMarketStatus`'s return tuple) | No separate getter |
| `IMarket(diamond).splitPosition(bytes32, uint256)` | `IMarketFacet(diamond).splitPosition(uint256, uint256)` | `bytes32 → uint256`, otherwise identical |
| `IMarket(diamond).mergePositions(bytes32, uint256)` | `IMarketFacet(diamond).mergePositions(uint256, uint256)` | same |
| `IPausable(diamond).paused(MARKET_MODULE)` where `MARKET_MODULE = keccak256("MARKET")` | `IPausableFacet(diamond).isModulePaused(Modules.MARKET)` from `@predix/shared/constants/Modules.sol` | **Hash mismatch is a silent security bug** — see exchange round 1. Always import `Modules.MARKET`, never define your own. |
| `bytes32 marketId` everywhere | `uint256 marketId` | Universal across V2 |
| Order side enum from legacy | `IPrediXExchange.Side { BUY_YES, SELL_YES, BUY_NO, SELL_NO }` | V2 exchange uses 4-side enum; legacy used a different shape |
| `exchange.fillMarketOrder(marketId, side, ...)` | `exchange.fillMarketOrder(marketId, takerSide, limitPrice, amountIn, taker, recipient, maxFills, deadline)` | **8 parameters**, not 6. `taker` and `recipient` are explicit |
| `hook.isTrustedRouters[router]` mapping checks | (no equivalent — see §6 for the V2 commit pattern) | V2 hook uses transient-storage commit |
| Pass `abi.encode(sender)` in hookData for sandwich detection | Call `hook.commitSwapIdentity(user, poolId)` BEFORE `poolManager.swap()` | Completely different mechanism |

**If you find a legacy code snippet in the design doc that uses any of
the left column patterns, it is wrong for V2**. Apply the right-column
mapping. Test that it compiles before writing more.

---

## 4. Architecture overview

```
                   user / wallet
                        │
                        │ buyYes / sellYes / buyNo / sellNo
                        ▼
                 ┌─────────────┐
                 │ PrediXRouter│  (stateless aggregator)
                 │             │
                 │ 1. validate │
                 │ 2. pull USDC│ ◄────── Permit2 (optional)
                 │    or token │
                 │ 3. quote    │ ◄────── V4Quoter (AMM exact preview)
                 │ 4. CLOB fill│ ◄────── Exchange.fillMarketOrder
                 │ 5. AMM fill │ ◄────── PoolManager.unlock + callback
                 │             │       (commit identity to Hook first)
                 │ 6. settle   │ ◄────── Diamond.split/mergePositions
                 │ 7. refund   │
                 │ 8. deliver  │
                 └─────────────┘
                        │
                        ▼
                   recipient
```

**Key design decisions, all locked**:

- **Stateless**: only immutables. No storage variables. `nonReentrant` via
  transient slot. Any token left in the contract after a call returns is
  lost forever (covered by the `_finalizeExactIn` invariant: the contract's
  USDC + outcome-token balance MUST be zero on exit).
- **Permissionless**: every entry function is public, no role checks. The
  only access-controlled function is `unlockCallback`, which checks
  `msg.sender == address(poolManager)`.
- **No router fee**: input fees come from Exchange (taker fee) and the v4
  pool (LP fee, dynamic via Hook). Router takes nothing.
- **Aggregator strategy**: CLOB first (try Exchange up to `maxFills`
  iterations), AMM for whatever's left (one v4 swap), refund unused input.
- **Quote source for AMM**: V4Quoter (NOT a constant-product approximation).
  This resolves audit H-03 from the legacy router.
- **Hook integration**: commit user identity via
  `hook.commitSwapIdentity(user, poolId)` immediately before
  `poolManager.unlock`. Hook stores the identity in transient storage and
  the anti-sandwich check uses it instead of the router address.

---

## 5. File structure

```
SC/packages/router/
├── src/
│   ├── PrediXRouter.sol               [main contract]
│   └── interfaces/
│       ├── IPrediXRouter.sol          [public router interface]
│       ├── IPrediXExchangeView.sol    [minimal local copy of exchange interface]
│       └── IPrediXHookCommit.sol      [minimal local copy of hook commit interface]
├── test/
│   ├── unit/
│   │   ├── PrediXRouter_BuyYes.t.sol
│   │   ├── PrediXRouter_SellYes.t.sol
│   │   ├── PrediXRouter_BuyNo.t.sol
│   │   ├── PrediXRouter_SellNo.t.sol
│   │   ├── PrediXRouter_Quotes.t.sol
│   │   └── PrediXRouter_Permit2.t.sol
│   ├── mocks/
│   │   ├── MockDiamond.sol
│   │   ├── MockExchange.sol
│   │   ├── MockHook.sol
│   │   ├── MockPoolManager.sol
│   │   ├── MockV4Quoter.sol
│   │   └── MockPermit2.sol
│   └── utils/
│       └── RouterFixture.sol
└── ...

SC/packages/diamond/
└── test/
    └── integration/
        └── RouterIntegration.t.sol    [full-stack: real diamond + real exchange + real hook + real router]
```

The integration test lives in `diamond/test/integration/` (per Q8). Add
`@predix/router/=../router/src/` to `diamond/remappings.txt` — **ask the
user before editing that file**. Same pattern as the oracle and exchange
integration tests.

---

## 6. Detailed design

### 6.1 Storage and immutables

```solidity
contract PrediXRouter is IPrediXRouter, IUnlockCallback, TransientReentrancyGuard {
    using SafeERC20 for IERC20;

    // ===== Immutables (set in constructor, never change) =====

    /// @notice Uniswap v4 PoolManager (also passed to the diamond + hook at deploy).
    IPoolManager public immutable poolManager;
    /// @notice PrediX diamond.
    address public immutable diamond;
    /// @notice USDC (the only collateral PrediX supports).
    address public immutable usdc;
    /// @notice PrediX hook (proxy address, not implementation).
    address public immutable hook;
    /// @notice PrediX exchange (CLOB).
    address public immutable exchange;
    /// @notice Uniswap v4 quoter — used for accurate AMM quotes (audit H-03 fix).
    IV4Quoter public immutable quoter;
    /// @notice Permit2 canonical address (`0x000000000022D473030F116dDEE9F6B43aC78BA3` on every OP Stack chain).
    IAllowanceTransfer public immutable permit2;
}
```

There is **no other storage**. No mappings, no counters, no arrays. This
is the contract's invariant: zero state means zero rent, zero corruption
surface, zero migration burden.

### 6.2 Constructor

```solidity
constructor(
    IPoolManager _poolManager,
    address _diamond,
    address _usdc,
    address _hook,
    address _exchange,
    IV4Quoter _quoter,
    IAllowanceTransfer _permit2
) {
    if (
        address(_poolManager) == address(0) || _diamond == address(0) || _usdc == address(0)
            || _hook == address(0) || _exchange == address(0) || address(_quoter) == address(0)
            || address(_permit2) == address(0)
    ) revert ZeroAddress();

    poolManager = _poolManager;
    diamond = _diamond;
    usdc = _usdc;
    hook = _hook;
    exchange = _exchange;
    quoter = _quoter;
    permit2 = _permit2;

    // Pre-approve diamond for splitPosition (USDC pull)
    IERC20(_usdc).forceApprove(_diamond, type(uint256).max);
    // Pre-approve exchange for fillMarketOrder USDC pulls
    IERC20(_usdc).forceApprove(_exchange, type(uint256).max);
}
```

YES/NO outcome token approvals are done lazily via `_ensureApproval` because
each market deploys its own pair.

### 6.3 Custom errors and events

In `IPrediXRouter.sol`:

```solidity
// ===== Errors =====
error ZeroAddress();
error ZeroAmount();
error DeadlineExpired(uint256 deadline, uint256 currentTime);
error InsufficientOutput(uint256 actual, uint256 minimum);
error ExactInUnfilled(uint256 amountIn);    // zero filled across both sources
error MarketNotFound();
error MarketResolved();
error MarketExpired();
error MarketInRefundMode();
error MarketModulePaused();
error InvalidRecipient();
error OnlyPoolManager();
error PoolNotInitialized();
error InsufficientLiquidity();

// ===== Events =====
event Trade(
    uint256 indexed marketId,
    address indexed trader,
    address indexed recipient,
    TradeType tradeType,
    uint256 amountIn,
    uint256 amountOut,
    uint256 clobFilled,
    uint256 ammFilled
);
event DustRefunded(address indexed recipient, address indexed token, uint256 amount);

enum TradeType { BUY_YES, SELL_YES, BUY_NO, SELL_NO }
```

Every error must have `@notice`. Every event must have `@notice`.

### 6.4 Public interface

```solidity
// All four entry functions follow the same shape:
//   exact-in input, minimum output, maxFills bound, deadline, recipient.
// Permit2 variants append (uint256 nonce, uint256 sigDeadline, bytes signature).

function buyYes(
    uint256 marketId,
    uint256 usdcIn,
    uint256 minYesOut,
    address recipient,
    uint256 maxFills,
    uint256 deadline
) external nonReentrant returns (uint256 yesOut, uint256 clobFilled, uint256 ammFilled);

function sellYes(
    uint256 marketId,
    uint256 yesIn,
    uint256 minUsdcOut,
    address recipient,
    uint256 maxFills,
    uint256 deadline
) external nonReentrant returns (uint256 usdcOut, uint256 clobFilled, uint256 ammFilled);

function buyNo(
    uint256 marketId,
    uint256 usdcIn,
    uint256 minNoOut,
    address recipient,
    uint256 maxFills,
    uint256 deadline
) external nonReentrant returns (uint256 noOut, uint256 clobFilled, uint256 ammFilled);

function sellNo(
    uint256 marketId,
    uint256 noIn,
    uint256 minUsdcOut,
    address recipient,
    uint256 maxFills,
    uint256 deadline
) external nonReentrant returns (uint256 usdcOut, uint256 clobFilled, uint256 ammFilled);
```

**Note that `buyNo` does NOT take a `mintAmount` parameter** — V2 router
auto-computes it via the V4Quoter (closes legacy bug M-06).

**Permit2 variants** (suffix `WithPermit`):

```solidity
function buyYesWithPermit(
    uint256 marketId,
    uint256 usdcIn,
    uint256 minYesOut,
    address recipient,
    uint256 maxFills,
    uint256 deadline,
    IAllowanceTransfer.PermitSingle calldata permitSingle,
    bytes calldata signature
) external nonReentrant returns (uint256 yesOut, uint256 clobFilled, uint256 ammFilled);
```

Same shape for `sellYesWithPermit`, `buyNoWithPermit`, `sellNoWithPermit`.
Inside the permit variant, after validation, call:
```solidity
permit2.permit(msg.sender, permitSingle, signature);
permit2.transferFrom(msg.sender, address(this), uint160(amountIn), tokenIn);
```
then continue identically to the non-permit path.

**Quote functions** (view, no state changes, no Permit2):

```solidity
function quoteBuyYes(uint256 marketId, uint256 usdcIn, uint256 maxFills)
    external view returns (uint256 expectedYesOut, uint256 clobPortion, uint256 ammPortion);

function quoteSellYes(uint256 marketId, uint256 yesIn, uint256 maxFills)
    external view returns (uint256 expectedUsdcOut, uint256 clobPortion, uint256 ammPortion);

function quoteBuyNo(uint256 marketId, uint256 usdcIn, uint256 maxFills)
    external view returns (uint256 expectedNoOut, uint256 clobPortion, uint256 ammPortion);

function quoteSellNo(uint256 marketId, uint256 noIn, uint256 maxFills)
    external view returns (uint256 expectedUsdcOut, uint256 clobPortion, uint256 ammPortion);
```

Implementation strategy: see §6.7.

### 6.5 Phase flow per execution

Every `buy*/sell*` follows this skeleton:

```solidity
function buyYes(uint256 marketId, uint256 usdcIn, uint256 minYesOut, address recipient, uint256 maxFills, uint256 deadline)
    external nonReentrant returns (uint256 yesOut, uint256 clobFilled, uint256 ammFilled)
{
    // Phase 1: Validate
    _checkDeadline(deadline);
    if (usdcIn == 0) revert ZeroAmount();
    if (recipient == address(0) || recipient == address(this)) revert InvalidRecipient();
    (address yesToken, address noToken, , ,) = _validateMarket(marketId);  // reverts if not tradeable

    // Phase 2: Pull
    IERC20(usdc).safeTransferFrom(msg.sender, address(this), usdcIn);

    // Phase 3: CLOB fill (try, fall back to AMM if it reverts)
    uint256 usdcRemaining = usdcIn;
    (clobFilled, usdcRemaining) = _tryClobBuy(
        marketId, IPrediXExchange.Side.BUY_YES, /*limitPrice=*/ _ammSpotCapForBuy(marketId, yesToken), usdcRemaining, maxFills, deadline
    );

    // Phase 4: AMM fill (the rest)
    if (usdcRemaining > 0) {
        ammFilled = _executeAmmBuyYes(marketId, yesToken, usdcRemaining, msg.sender);
        usdcRemaining = 0;  // _executeAmmBuyYes consumes all input or reverts
    }

    yesOut = clobFilled + ammFilled;

    // Phase 5: Finalize
    if (yesOut == 0) revert ExactInUnfilled(usdcIn);
    if (yesOut < minYesOut) revert InsufficientOutput(yesOut, minYesOut);
    IERC20(yesToken).safeTransfer(recipient, yesOut);
    _refundAndAssertZero(usdc);  // refund any USDC dust to msg.sender, assert balance == 0

    emit Trade(marketId, msg.sender, recipient, TradeType.BUY_YES, usdcIn, yesOut, clobFilled, ammFilled);
}
```

The `sellYes` flow is symmetric: pull YES, try CLOB sell, AMM swap YES→USDC for remainder, refund unspent YES, deliver USDC.

The `buyNo` and `sellNo` flows are the **virtual NO** path, which is more
complex — see §6.8.

### 6.6 Market validation (single read, full caching)

```solidity
function _validateMarket(uint256 marketId)
    private view
    returns (address yesToken, address noToken, uint256 endTime, bool isResolved, bool refundModeActive)
{
    if (IPausableFacet(diamond).isModulePaused(Modules.MARKET)) revert MarketModulePaused();

    (yesToken, noToken, endTime, isResolved, refundModeActive)
        = IMarketFacet(diamond).getMarketStatus(marketId);

    if (yesToken == address(0)) revert MarketNotFound();
    if (isResolved) revert MarketResolved();
    if (refundModeActive) revert MarketInRefundMode();
    if (block.timestamp >= endTime) revert MarketExpired();
}
```

This is the **only** call to `getMarketStatus` per `fillMarketOrder`. All
downstream helpers receive the cached `(yesToken, noToken)` addresses,
**not** the marketId, so they don't re-read.

### 6.7 Quote functions — V4Quoter integration

This is the H-03 fix. Instead of approximating with constant-product math,
the router calls Uniswap's V4 Quoter contract for AMM quotes.

```solidity
function quoteBuyYes(uint256 marketId, uint256 usdcIn, uint256 maxFills)
    external view returns (uint256 expectedYesOut, uint256 clobPortion, uint256 ammPortion)
{
    (address yesToken, address noToken, uint256 endTime, bool isResolved, bool refundModeActive)
        = IMarketFacet(diamond).getMarketStatus(marketId);
    if (yesToken == address(0) || isResolved || refundModeActive || block.timestamp >= endTime) {
        return (0, 0, 0);  // quote views return 0 on bad state, never revert
    }

    // 1) AMM marginal spot — used as the CLOB price cap
    PoolKey memory key = _buildPoolKey(yesToken);
    uint256 ammSpot = _ammSpotPriceForBuy(yesToken);  // raw $ per YES token, 6 decimals, fee-adjusted

    // 2) Quote CLOB at the cap — exchange returns both filled and cost in a single call.
    uint256 clobCost;
    (clobPortion, clobCost) = IPrediXExchange(exchange).previewFillMarketOrder(
        marketId, IPrediXExchange.Side.BUY_YES, ammSpot, usdcIn, maxFills
    );

    // 3) Quote AMM for whatever USDC the CLOB didn't consume.
    uint256 usdcLeft = usdcIn - clobCost;
    if (usdcLeft > 0) {
        IV4Quoter.QuoteExactSingleParams memory params = IV4Quoter.QuoteExactSingleParams({
            poolKey: key,
            zeroForOne: usdc < yesToken ? true : false,
            exactAmount: uint128(usdcLeft),
            hookData: ""
        });
        (uint256 amountOut, ) = quoter.quoteExactInputSingle(params);
        ammPortion = amountOut;
    }

    expectedYesOut = clobPortion + ammPortion;
}
```

**Important caveats**:

- `IV4Quoter.quoteExactInputSingle` is a `view` function in v4-periphery. It
  internally simulates the swap by reverting and decoding the revert data.
  Solidity's `view` modifier permits this pattern. If you have any doubt,
  check `v4-periphery/src/lens/V4Quoter.sol` source before relying on the
  signature.
- **Quoter does NOT account for the hook's dynamic fee override.** The hook
  applies its dynamic fee in `_beforeSwap` via the `OVERRIDE_FEE_FLAG`. The
  Quoter calls into the same hook and should pick up the same fee, so in
  theory this is correct. **Verify this empirically in the integration
  test** before declaring the H-03 fix done. If the Quoter ignores the
  override flag, you must apply the dynamic fee manually post-quote (see
  edge case E5 in `PREDIX_ROUTER_EDGE_CASES.md`).
- The `hookData` you pass to the quoter must match what you pass at execute
  time. Currently the router does NOT pack a referrer or a slippage cap
  into hookData, so the empty bytes are correct. If a future feature adds
  hookData, update the quoter call to match.

### 6.8 `buyNo` and `sellNo` — virtual NO path

The legacy router uses a binary search to compute `mintAmount` for `buyNo`.
With the V4 Quoter, this collapses to a single quote + a single division.

**`buyNo` algorithm**:

```
INPUT: usdcIn (user budget)
GOAL:  maximise NO tokens delivered

The economics:
  splitPosition(mintAmount USDC) yields mintAmount YES + mintAmount NO
  swapping mintAmount YES → USDC at AMM yields some USDC back
  net cost to mint mintAmount NO = mintAmount - (USDC from YES swap)

We want net cost ≤ usdcIn, maximised.

Algorithm:
  1. Quote AMM: how much USDC does swapping `usdcIn` worth of YES yield?
     → Actually this needs a different shape. We want to find mintAmount such that
       mintAmount - quoteSwapYesToUsdc(mintAmount) ≈ usdcIn
  2. Closed-form approximation: ammYesPrice = quoteSwapYesToUsdc(1 unit) per unit
     mintAmount = usdcIn / (1 - ammYesPrice)
  3. Apply 3% safety margin: mintAmount *= 0.97
  4. Re-quote at mintAmount to confirm; if still feasible, execute
```

**Even simpler alternative** (recommended for v1):

```
1. Quote AMM exact: quoter.quoteExactOutputSingle for YES → USDC swap, target = usdcIn.
   This gives us YES amount needed to produce usdcIn USDC at AMM.
2. mintAmount = max(usdcIn, ammYesAmount) — pick the larger so split has enough collateral.
3. Actually no — simpler: compute via spot price ratio.
```

I'm going to **stop pseudo-coding the buyNo math here** and ask you to
implement it as follows, with explicit instructions:

1. Read the legacy `buyNo` from `PrediX_Uni_V4/.../PrediXRouter.sol` to
   understand the economic intent (NOT the binary search math).
2. Read [PREDIX_ROUTER_EDGE_CASES.md] sections E10a–E10c, E13, E18 for
   edge case context.
3. Implement V2 `buyNo` using V4Quoter:
   - Get spot price of YES via `quoter.quoteExactInputSingle(1e6 USDC → YES)`.
   - Compute `noPriceSpot = 1e6 - yesPriceSpot` (the binary identity).
   - Compute target NO via `noOutTarget = usdcIn * 1e6 / noPriceSpot`.
   - Apply 3% safety margin: `mintAmount = noOutTarget * 970 / 1000`.
   - Inside `unlockCallback`, swap `mintAmount` YES → USDC (exact-in YES),
     verify the resulting USDC ≥ `mintAmount - usdcIn`, split, settle.
4. **Stop and ask** if you discover that the math doesn't close cleanly
   under V4 concentrated liquidity. The reviewer accepts that the 3% margin
   may be insufficient for whale trades; document the edge cases you hit
   and propose a per-trade cap (`perTradeCap`) check.

**`sellNo` is symmetric**: user provides NO tokens, router needs to
mergePositions to get USDC, but mergePositions requires equal YES + NO.
Router has zero YES at start. So:

1. Buy YES from AMM equal to `noIn` (using USDC borrowed via flash from
   the AMM unlock callback).
2. Call `diamond.mergePositions(marketId, noIn)` — burns equal YES + NO,
   returns `noIn` USDC.
3. Settle the USDC borrowed from AMM.
4. Net USDC delta is paid to recipient.

Same Quoter-based pricing as `buyNo`. Same 3% safety margin. Same edge
case caveats.

### 6.9 CLOB fill helper

```solidity
function _tryClobBuy(
    uint256 marketId,
    IPrediXExchange.Side side,
    uint256 limitPrice,
    uint256 amountIn,
    uint256 maxFills,
    uint256 deadline
) private returns (uint256 filled, uint256 amountInRemaining) {
    try IPrediXExchange(exchange).fillMarketOrder(
        marketId,
        side,
        limitPrice,
        amountIn,
        /*taker=*/ address(this),
        /*recipient=*/ address(this),
        maxFills,
        deadline
    ) returns (uint256 _filled, uint256 _cost) {
        filled = _filled;
        amountInRemaining = amountIn - _cost;
    } catch {
        // Exchange revert (paused, expired, etc.) → fall back to 100% AMM
        filled = 0;
        amountInRemaining = amountIn;
    }
}
```

The try/catch fallback is **deliberate**. Edge case E14 in the legacy doc
covers it: if the exchange is paused but the AMM pool is still tradeable
(market not yet expired), the router should NOT propagate the exchange
pause to the user — they should still be able to swap on the AMM.

Sell paths (`_tryClobSell`) are symmetric but pre-approve the YES/NO token
to the exchange via lazy `_ensureApproval` before calling.

### 6.10 AMM execution helpers — Hook commit pattern

**This is the V2-specific bit that the design doc gets wrong.** The router
must commit the user identity to the hook via transient storage **before**
calling `poolManager.unlock`, otherwise the hook's anti-sandwich detector
will see `msg.sender == router` for every swap and false-positive on the
second user that trades through the router in the same block.

```solidity
function _executeAmmBuyYes(uint256 marketId, address yesToken, uint256 usdcIn, address user)
    private returns (uint256 yesOut)
{
    PoolKey memory key = _buildPoolKey(yesToken);
    PoolId poolId = key.toId();

    // ===== Hook anti-sandwich commit =====
    // Must happen BEFORE unlock; hook stores in transient storage scoped to (router, poolId).
    IPrediXHookCommit(hook).commitSwapIdentity(user, poolId);

    // ===== Unlock + swap =====
    bytes memory data = abi.encode(
        AmmAction.BUY_YES,
        AmmCtx({key: key, marketId: marketId, yesToken: yesToken, amountIn: usdcIn, recipient: address(this)})
    );
    bytes memory result = poolManager.unlock(data);
    yesOut = abi.decode(result, (uint256));
}

function unlockCallback(bytes calldata data) external override returns (bytes memory) {
    if (msg.sender != address(poolManager)) revert OnlyPoolManager();

    (AmmAction action, AmmCtx memory ctx) = abi.decode(data, (AmmAction, AmmCtx));

    if (action == AmmAction.BUY_YES)  return abi.encode(_callbackBuyYes(ctx));
    if (action == AmmAction.SELL_YES) return abi.encode(_callbackSellYes(ctx));
    if (action == AmmAction.BUY_NO)   return abi.encode(_callbackBuyNo(ctx));
    return abi.encode(_callbackSellNo(ctx));
}
```

The exact `_callbackBuyYes` flow:

```solidity
function _callbackBuyYes(AmmCtx memory ctx) private returns (uint256 yesOut) {
    bool zeroForOne = usdc < ctx.yesToken;  // USDC → YES

    // Swap exact-in USDC
    BalanceDelta delta = poolManager.swap(
        ctx.key,
        IPoolManager.SwapParams({
            zeroForOne: zeroForOne,
            amountSpecified: -int256(ctx.amountIn),  // negative = exact-in
            sqrtPriceLimitX96: zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
        }),
        ""  // hookData empty for v1 — no referrer, no slippage cap
    );

    int128 usdcDelta = zeroForOne ? delta.amount0() : delta.amount1();    // negative
    int128 yesDelta  = zeroForOne ? delta.amount1() : delta.amount0();    // positive

    // Settle: pay USDC owed to pool, take YES owed to us
    _settleToken(usdc, uint256(uint128(-usdcDelta)));
    _takeToken(ctx.yesToken, uint256(uint128(yesDelta)));

    yesOut = uint256(uint128(yesDelta));
}
```

`_settleToken` and `_takeToken` follow the standard v4 flash-accounting
pattern — see `v4-periphery/src/base/DeltaResolver.sol` for reference (do
NOT inherit it; copy the minimal helper logic and inline it).

### 6.11 Permit2 helpers

```solidity
function _consumePermit(IAllowanceTransfer.PermitSingle calldata permitSingle, bytes calldata signature, uint160 amount, address token)
    private
{
    if (permitSingle.details.token != token) revert InvalidPermitToken();
    if (permitSingle.details.amount < amount) revert InsufficientPermitAllowance();
    permit2.permit(msg.sender, permitSingle, signature);
    permit2.transferFrom(msg.sender, address(this), amount, token);
}
```

Used inside the four `*WithPermit` variants. The non-permit variants stay
on `safeTransferFrom`.

### 6.12 Finalize / dust handling

```solidity
function _refundAndAssertZero(address token) private {
    uint256 bal = IERC20(token).balanceOf(address(this));
    if (bal > 0) {
        IERC20(token).safeTransfer(msg.sender, bal);
        emit DustRefunded(msg.sender, token, bal);
    }
    // Invariant: balance MUST be zero here. Anything left is a bug.
    if (IERC20(token).balanceOf(address(this)) != 0) revert FinalizeBalanceNonZero();
}
```

Add `error FinalizeBalanceNonZero()` to the interface. This is a defensive
assertion — it should never fire under normal operation. If it does, it
means the router's accounting is broken and we want a hard revert, not
silent token loss.

---

## 7. Edge cases — port from `PREDIX_ROUTER_EDGE_CASES.md` with V2 adaptations

The legacy edge case doc enumerates 19 cases (E1–E19). Most still apply.
Adapt them as follows:

| Edge case | V2 status |
|---|---|
| **E1** Min trade amount | Apply: `if (amountIn < MIN_TRADE_AMOUNT) revert ZeroAmount()`. Set `MIN_TRADE_AMOUNT = 1000` (`$0.001` USDC). |
| **E2** Recipient blocking | Apply: block `address(this)`, `address(0)`, **and** `diamond`/`exchange`/`hook`/`poolManager`/`quoter`/`permit2`. Add an `_isBannedRecipient(address)` helper. |
| **E3** YES near $1 / NO near $0 | Frontend warning; router does not block but quote may show very large slippage. |
| **E4** YES near $0.01 | Same as E3, opposite direction. |
| **E5** Fee denomination | **Aligned in V2**: everywhere uses 1e6 = 100% (Uniswap pip units). Hook's dynamic fee is in pip units. Router's `PRICE_PRECISION = 1e6`. No mismatch. |
| **E6** CLOB fills 100% | Skip AMM step. Router still emits `Trade` with `ammFilled = 0`. |
| **E7** `maxFills = 0` | Convert to `DEFAULT_MAX_FILLS = 10` inside `_tryClobBuy` / `_tryClobSell`. |
| **E8** Exchange paused | Try/catch absorbs. Router falls back to AMM. Test required. |
| **E9** Pool zero liquidity | Quoter returns 0; router skips AMM step; if CLOB also 0 → `ExactInUnfilled`. |
| **E10a** Binary search convergence | **N/A in V2** — Quoter eliminates the binary search. |
| **E10b** Binary search precision | **N/A in V2**. |
| **E10c** Simulation 7-18% error | **Mostly resolved by Quoter**. Apply 3% safety margin in `buyNo`/`sellNo` virtual paths. Document in NatSpec. |
| **E11** sellNo exact-output rounding | Apply tolerance: `if (yesNeeded > noIn + MAX_DUST_SHARES) revert InsufficientLiquidity()`. |
| **E12** Hook anti-sandwich false positive | **Resolved by `commitSwapIdentity` pattern (§6.10)**. Verify in integration test that two consecutive trades from the same router (different end users) succeed in the same block. |
| **E13** Dust accumulation | `_refundAndAssertZero` invariant catches it. Set `MAX_DUST_USDC = 100` (≤ $0.0001) as soft warning; hard limit is "balance must be zero". |
| **E14** CLOB unhealthy fallback | Try/catch handles. |
| **E15** Diamond MARKET module paused | Apply `IPausableFacet.isModulePaused(Modules.MARKET)` check in `_validateMarket`. |
| **E16** Fee tier crossing during execution | Hook applies fee at execute time; quoter applies fee at quote time. Slippage bound (`minOut`) protects user. |
| **E17** Quoter availability | Confirmed available on Unichain. Use it. |
| **E18** `perTradeCap` interaction with `buyNo` | Read `perTradeCap` from `getMarket` (full call, not `getMarketStatus`) ONLY in `buyNo`/`sellNo` virtual paths where `splitPosition` is involved. Cap `mintAmount`. |
| **E19** Refund mode | `_validateMarket` checks `refundModeActive` and reverts. |

The edge case doc has more verbose discussion. **Read it once**, internalise
the business logic, then implement against THIS spec, not against that
doc.

---

## 8. Tests

### 8.1 Mocks (in `test/mocks/`)

Build minimal mocks for everything the router calls:

- **`MockDiamond`** — implements `IMarketFacet.getMarketStatus`, `splitPosition`, `mergePositions`, `IPausableFacet.isModulePaused`. Lets tests set status / pause / per-trade-cap.
- **`MockExchange`** — implements `IPrediXExchange.fillMarketOrder` (returns canned `(filled, cost)` per call, can be configured to revert).
- **`MockHook`** — implements `IPrediXHook.commitSwapIdentity` (records every commit; tests assert it was called).
- **`MockPoolManager`** — implements `IPoolManager.unlock` (calls back into router) and `swap` (returns canned `BalanceDelta`).
- **`MockV4Quoter`** — returns canned quote results.
- **`MockPermit2`** — accepts any `permit` + `transferFrom`, records calls.
- **`MockERC20`** + **`MockOutcomeToken`** — standard mintable test tokens.

### 8.2 Unit tests — required cases

For **each of the 4 trade primitives** (`buyYes`, `sellYes`, `buyNo`,
`sellNo`):

- `test_HappyPath_ClobOnly` — CLOB has full liquidity, AMM untouched
- `test_HappyPath_AmmOnly` — CLOB empty, AMM fills everything
- `test_HappyPath_Split` — CLOB fills 60%, AMM fills 40%
- `test_HappyPath_RecipientDifferentFromCaller` — Permit2 + router pattern
- `test_Refund_ExcessUsdc` — partial fill, dust refunded, `DustRefunded` event
- `test_Revert_ZeroAmount`
- `test_Revert_DeadlineExpired`
- `test_Revert_InvalidRecipient_Self` (router)
- `test_Revert_InvalidRecipient_Diamond`
- `test_Revert_InsufficientOutput` (filled < minOut)
- `test_Revert_ExactInUnfilled` (zero filled across both sources)
- `test_Revert_MarketNotFound`
- `test_Revert_MarketResolved`
- `test_Revert_MarketExpired`
- `test_Revert_MarketInRefundMode`
- `test_Revert_MarketModulePaused`
- `test_HookCommit_CalledBeforeUnlock` — assert mock hook saw the commit before mock pool manager saw the unlock

For **`buyNo`/`sellNo` specifically** (the virtual NO path):

- `test_VirtualPath_BuyNo_AmmOnly_Quoter`
- `test_VirtualPath_SellNo_AmmOnly_Quoter`
- `test_VirtualPath_BuyNo_RespectsPerTradeCap`
- `test_Revert_BuyNo_QuoteOutsideSafetyMargin` — re-quote after split says we're under-collateralised

For **Permit2 variants**:

- `test_Permit2_BuyYes_HappyPath`
- `test_Revert_Permit2_InvalidSignature`
- `test_Revert_Permit2_TokenMismatch`
- `test_Revert_Permit2_InsufficientAllowance`
- `test_Revert_Permit2_PermitDeadlineExpired`

For **quote functions**:

- `test_QuoteBuyYes_MatchesExecuted` — quote then execute, assert |actual − quoted| ≤ 1%
- Same for `quoteSellYes`, `quoteBuyNo`, `quoteSellNo`
- `test_Quote_NotFoundReturnsZero` — quote on bad market returns `(0, 0, 0)` (does NOT revert)

### 8.3 Fuzz tests

- `testFuzz_BuyYes_AmountIn_AlwaysRefundsDust` — fuzz `usdcIn ∈ [MIN_TRADE_AMOUNT, 1e12]`, assert router balance == 0 after every call.
- `testFuzz_BuyNo_QuoterMatchesExecution` — fuzz `usdcIn`, assert quoted vs executed within tolerance.
- `testFuzz_PriceCap_NeverCrossed` — fuzz, assert CLOB fill price ≤ quote cap.

### 8.4 Invariant tests

Build a `RouterHandler` that randomly calls `buyYes` / `sellYes` / `buyNo`
/ `sellNo` with bounded amounts. Invariants:

- `invariant_RouterUsdcBalanceIsZero` — after every call, `usdc.balanceOf(router) == 0`
- `invariant_RouterYesBalanceIsZero` — same for every YES token in scope
- `invariant_RouterNoBalanceIsZero` — same for every NO token in scope
- `invariant_DepositedFundsAccountedFor` — sum of inputs from users == sum of outputs to recipients + dust refunded

### 8.5 Integration test — full stack

`SC/packages/diamond/test/integration/RouterIntegration.t.sol`. **Ask the
user before adding `@predix/router/=../router/src/` to
`diamond/remappings.txt`.**

Build the full stack inside the test:

1. Deploy diamond from `MarketFixture` (you already know how).
2. Deploy `OutcomeToken` factory bits via the existing `MarketFacet`.
3. Deploy `ChainlinkOracle` from `packages/oracle/src/`, approve it on the diamond.
4. Deploy a real Uniswap v4 `PoolManager` using `v4-core/test/utils/Deployers.sol`.
5. Deploy `PrediXHookV2` via `HookMiner` (the proxy + impl pattern from the hook package).
6. Deploy `PrediXExchange` from `packages/exchange/src/`.
7. Deploy a real `V4Quoter` from `v4-periphery/src/lens/V4Quoter.sol`.
8. Deploy the canonical Permit2 (or use the deterministic deployment fixture).
9. Deploy `PrediXRouter`, wire all addresses.
10. Trust the router on the hook (so the hook accepts `commitSwapIdentity` calls).
11. Create a market, seed it with liquidity (split positions, place CLOB orders, add v4 LP).
12. Run end-to-end scenarios: buyYes, sellYes, buyNo, sellNo via router → assert balances.

If steps 4–8 are too painful, **stop and ask** before splitting the
integration test into multiple files or skipping pieces.

---

## 9. Definition of done

Run from `SC/packages/router/`:

- [ ] `forge build` — green, no warnings.
- [ ] `forge test` — green, all unit + fuzz + invariant tests pass.
- [ ] `forge fmt --check` — clean.
- [ ] Every public function has ≥1 happy + ≥1 revert test.
- [ ] Every custom error has a test that triggers it.
- [ ] Hook commit pattern verified: `MockHook.commitCalls.length` increments before each AMM call.
- [ ] Router USDC + YES + NO balance invariants pass under 256×500 fuzz handler stress.
- [ ] Integration test in `diamond/test/integration/` passes (full stack).
- [ ] No imports outside `@openzeppelin/`, `@uniswap/`, `permit2/`, `@predix/shared/`, local. Grep `src/` to confirm.
- [ ] `IPrediXExchangeView.sol` and `IPrediXHookCommit.sol` are minimal — they expose ONLY the symbols the router calls. Each has a `@dev` block pointing at the canonical location.
- [ ] Constructor reverts on any zero address.
- [ ] V4Quoter integration empirically confirmed to apply the hook's dynamic fee (verified in integration test).
- [ ] Report written in `CLAUDE.md §10.4` format with `Requirement → Evidence` mapping for every numbered section in this spec.

---

## 10. Execution phases

Build incrementally; run `forge build && forge test` after every step.

### Phase R1 — Interfaces and storage (Day 1)

1. Create `src/interfaces/IPrediXRouter.sol` (errors, events, function signatures).
2. Create `src/interfaces/IPrediXExchangeView.sol` (minimal local copy — only `fillMarketOrder` + `previewFillMarketOrder` + relevant types).
3. Create `src/interfaces/IPrediXHookCommit.sol` (just `commitSwapIdentity(address, PoolId)`).
4. Create `src/PrediXRouter.sol` skeleton: constructor, immutables, modifier `_checkDeadline`, no logic yet.
5. `forge build` — must compile.

### Phase R2 — Validation + helpers (Day 1)

6. Implement `_validateMarket`, `_isBannedRecipient`, `_buildPoolKey`, `_ensureApproval`, `_settleToken`, `_takeToken`, `_refundAndAssertZero`.
7. Add minimal mock infrastructure (`MockDiamond`, `MockERC20`, `MockOutcomeToken`).
8. Unit-test the helpers in isolation if possible.

### Phase R3 — `buyYes` end to end (Day 2)

9. Implement `_tryClobBuy`, `_executeAmmBuyYes`, `_callbackBuyYes`, `unlockCallback` action dispatch.
10. Implement `buyYes` external function.
11. Mock all dependencies; write the 17 required `buyYes` unit tests from §8.2.
12. `forge test --match-contract PrediXRouter_BuyYes` — green.

### Phase R4 — `sellYes`, `buyNo`, `sellNo` (Day 3)

13. Symmetric implementation. The buyNo/sellNo virtual paths are the
    hardest part — re-read §6.8 carefully and ASK if the math doesn't
    close.
14. Write the 4 trade primitives' tests in parallel.
15. `forge test --match-contract "PrediXRouter_*"` — green.

### Phase R5 — Quote functions (Day 3)

16. Implement `quoteBuyYes`, `quoteSellYes`, `quoteBuyNo`, `quoteSellNo` using the V4Quoter.
17. Write the 4 quote-vs-execute parity tests.

### Phase R6 — Permit2 variants (Day 4)

18. Implement the 4 `*WithPermit` variants.
19. Write Permit2 unit tests with `MockPermit2`.

### Phase R7 — Fuzz + invariants (Day 4)

20. Build `RouterHandler` for invariant tests.
21. Write the 4 invariants.
22. Run `forge test --fuzz-runs 256` to confirm.

### Phase R8 — Integration test (Day 5)

23. **Ask the user** before editing `diamond/remappings.txt`.
24. Build `RouterIntegration.t.sol` in `diamond/test/integration/`.
25. Run end-to-end scenarios. Verify the V4Quoter actually applies the
    hook's dynamic fee (this is the empirical check on the H-03 fix).

### Phase R9 — Final verification

26. `forge fmt`, `forge build`, `forge test` everywhere.
27. Write the report per `CLAUDE.md §10.4`.

---

## 11. Out of scope for this round

- **Multi-hop routing** (e.g. swap YES_marketA → USDC → YES_marketB in one tx). Locked NO.
- **Router fee**. Router takes nothing on top of exchange + AMM fees. Locked.
- **Storage / state variables**. Router is stateless. Locked.
- **Permit2 mandatory mode**. Permit2 is OPTIONAL — the non-permit variants stay. Locked.
- **Real-time MEV protection beyond hook commit**. We rely on Hook + Unichain sequencer. No router-level MEV mitigation.
- **Deploy script with hardcoded Unichain addresses**. The deploy script lives in `script/`, NOT in `src/`. Source code stays chain-agnostic.
- **Cross-event routing** (trading across an EventFacet's child markets in one tx). Each market is a separate router call.
- **Touching `shared/`, `diamond/`, `oracle/`, `hook/`, `exchange/` source**. Router is a pure consumer.
- **Adding new symbols to `@predix/shared/`**. If you find one missing, STOP and ask.

---

## 12. Locked decisions (don't re-open)

The reviewer and user pre-confirmed these. Do NOT change them without
explicit go-ahead:

1. **Aggregator architecture** (CLOB first, AMM remainder) — locked R1=A.
2. **Permit2 optional support** — locked R2 (Mức B in the discussion).
3. **No multi-hop** — locked R3.
4. **Partial fill + refund** with `ExactInUnfilled` only on zero filled — locked R4 / Q1.
5. **No router fee** — locked R5.
6. **Stateless router** — locked R6.
7. **Unichain target, V4Quoter available** — locked R7.
8. **V2 interfaces (`IMarketFacet`, `IPausableFacet`, `Modules.MARKET`)** — locked Q2.
9. **Hook commit pattern via `commitSwapIdentity`** — locked Q3.
10. **Hybrid Quoter (quote with V4Quoter, execute with real swap + slippage bound)** — locked Q4.
11. **Simplified `buyNo` via Quoter, no binary search** — locked Q5.
12. **Permit2 optional, both `*` and `*WithPermit` variants** — locked Q6.
13. **Spec written assuming exchange is done first** — locked Q7. If exchange
    interface drifts before router code starts, this spec must be revisited
    BEFORE coding.
14. **Integration test in `diamond/test/integration/RouterIntegration.t.sol`** — locked Q8.
15. **Quoter address as immutable; deploy script provides actual address** — locked Q9.

---

## 13. Things to pause and ask about

If you hit any of these, **stop and ask the reviewer**:

1. V4Quoter on Unichain does not respect the hook's `OVERRIDE_FEE_FLAG`. The H-03 fix needs a different approach.
2. `buyNo` / `sellNo` math doesn't close cleanly under V4 concentrated liquidity even with a 3% safety margin. A whale-sized trade reverts at quote re-check.
3. Permit2's deterministic address is NOT deployed on Unichain. (It should be — every OP Stack chain has it. But verify.)
4. You discover that the hook commit pattern doesn't actually work the way the hook agent's code suggests. Re-read [PrediXHookV2.sol](../hook/src/hooks/PrediXHookV2.sol) `_resolveIdentity` and the surrounding code before raising.
5. You find a missing symbol in `@predix/shared/`. Adding to shared is a separate, prior commit — do not do it inline with router work.
6. Any test in `shared/`, `diamond/`, `oracle/`, `hook/`, or `exchange/`
   regresses because of router changes. (It shouldn't, since you're only
   adding files, not modifying existing ones — but if it happens, stop.)
7. Exchange agent finishes Phase E4-E5 (full unit/fuzz/invariant tests) and
   discovers a bug that requires changing `IPrediXExchange.fillMarketOrder` or
   `previewFillMarketOrder` signature. Both signatures are confirmed stable
   as of E2c (10/10 smoke tests across all 3 mixins), but if E4-E5 forces a
   change, router must adapt.

---

## 14. Report format

After you finish, write the report per `SC/CLAUDE.md §10.4`:

```
## Summary
## Requirement → Evidence
  - §3 V2 interface mapping → file:line for each replaced call
  - §6.1 Storage → file:line
  - §6.2 Constructor → file:line
  - §6.5 buyYes phase flow → file:line
  - §6.7 Quote functions → file:line + Quoter address used in test
  - §6.8 buyNo/sellNo virtual path → file:line + safety margin value
  - §6.10 Hook commit pattern → file:line + integration test name
  - §6.11 Permit2 helpers → file:line + 4 variant function lines
  - §7 Edge cases (E1–E19 status) → table mapping each E to handling location
  - §8 Tests → unit / fuzz / invariant counts, integration test name
## Files
  - Added: ...
  - Modified: (should be empty — router only adds files)
## Tests
  - Unit: count
  - Fuzz: count
  - Invariant: list
  - Integration: list
## Deviations from spec
  - Anywhere you diverged with written justification
## Out-of-scope findings (NOT fixed)
## Open questions
## Checklist §10.3 (A–F)
```

Push back on anything in this spec that looks wrong once you're back in
the code. The spec author is another agent with limited context — you
have the full picture after building it. Just document the disagreement.
