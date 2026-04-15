# PREDIX HOOK V2 — IMPLEMENTATION SPEC
# Single Source of Truth
# Version: 1.0 | Date: 2026-04-14

## ====================================================================
## OPERATING RULES — READ BEFORE ANY CODE CHANGE
## ====================================================================

### Purpose
PrediXHookV2 and PrediXHookProxyV2 for the PrediX prediction market protocol on Uniswap v4 (Unichain). This is a SECURITY-CRITICAL rewrite based on an audit that found 6 CRITICAL, 5 HIGH, 7 MEDIUM issues in V1.

### Git Commit Format
```
feat(hook-v2): [PHASE-X.Y] short description

Fixes: C-XX / H-XX / M-XX (reference audit IDs)
```

### Exit Gates
Before marking any phase DONE:
1. `forge build` must succeed with zero errors
2. `forge test` must pass all existing + new tests
3. Storage layout slots 0–14 must NOT change (run `forge inspect PrediXHookV2 storage-layout`)
4. No compiler warnings

### Forbidden Patterns — INSTANT REJECT
- ❌ NEVER reorder storage variables in slots 0–14 (proxy will corrupt)
- ❌ NEVER use `abi.decode(hookData, (address))` for referrer — use `address(bytes20(hookData[:20]))`
- ❌ NEVER accumulate referral credits on-chain (was the root cause of V1 fund drain vulnerability)
- ❌ NEVER check slippage in `_beforeSwap` — it checks pre-swap price which is useless
- ❌ NEVER use `delta.amount0()` for USDC volume — amount0 is the YES token
- ❌ NEVER use SSTORE-based reentrancy guard — use EIP-1153 transient storage
- ❌ NEVER allow `poolManager.initialize()` for pools without pre-registered `poolToMarket` entry
- ❌ NEVER read anti-sandwich identity from hookData when sender is a trusted router — use committed storage
- ❌ NEVER have 2 `initialize()` overloads — V2 has exactly 1

### Required Patterns — ALWAYS USE
- ✅ ALWAYS use `FullMath.mulDiv()` from v4-core for sqrtPrice calculations
- ✅ ALWAYS check `isRegisteredOutcomeToken[token0]` to determine YES/USDC ordering before price calc
- ✅ ALWAYS emit events for admin state changes (pause, router, diamond)
- ✅ ALWAYS use `whenNotPaused` modifier on `_beforeSwap`, `_beforeAddLiquidity`, `_beforeDonate`
- ✅ ALWAYS allow `_beforeRemoveLiquidity` even when paused/resolved (LPs must exit)
- ✅ ALWAYS use `BaseHook.XXX.selector` as return value from hook callbacks
- ✅ ALWAYS clamp YES price to [0, 1_000_000] range (0% to 100%)

## ====================================================================
## PHASE 1: PrediXHookV2.sol — Implementation Contract
## ====================================================================

### 1.1 File Location
```
src/hooks/PrediXHookV2.sol
```

### 1.2 Imports
```solidity
import {BaseHook} from "@openzeppelin/uniswap-hooks/src/base/BaseHook.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {IPoolManager, SwapParams} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {BeforeSwapDelta, BeforeSwapDeltaLibrary} from "@uniswap/v4-core/src/types/BeforeSwapDelta.sol";
import {Currency, CurrencyLibrary} from "@uniswap/v4-core/src/types/Currency.sol";
import {LPFeeLibrary} from "@uniswap/v4-core/src/libraries/LPFeeLibrary.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";       // NEW in V2
import {IMarket, IMarketBase} from "../facets/market/IMarket.sol";
import {FEE_NORMAL, FEE_MEDIUM, FEE_HIGH, FEE_VERY_HIGH, TICK_SPACING} from "../Constants.sol";
```

### 1.3 Storage Layout — EXACT ORDER, DO NOT DEVIATE

```
// ===== FROZEN V1 SLOTS (0–14) — copy EXACTLY from V1 =====
// Slot 0
address public diamond;
// Slot 1
address public usdc;
// Slot 2
bool private initialized;
// Slot 3
mapping(PoolId => bytes32) public poolToMarket;
// Slot 4
mapping(address => bool) public isRegisteredOutcomeToken;
// Slot 5
mapping(bytes32 => uint256) public marketVolume;
// Slot 6 — FROZEN, unused
mapping(bytes32 => bytes32) private _deprecated_limitOrders;
// Slot 7 — FROZEN, unused
mapping(bytes32 => mapping(int24 => bytes32[])) private _deprecated_tickOrders;
// Slot 8 — FROZEN, was public in V1, now private
uint256 private _deprecated_orderNonce;
// Slot 9 — FROZEN, replaced by transient storage
uint256 private _deprecated_locked;
// Slot 10 — FROZEN
mapping(PoolId => int24) private _preSwapTick;
// Slot 11 — FROZEN, was `public referralCredits` in V1 → now private
mapping(address => uint256) private _deprecated_referralCredits;
// Slot 12
mapping(PoolId => int24) private tickLowerLast;
// Slot 13
mapping(bytes32 => uint256) private _lastSwapInfo;
// Slot 14
mapping(address => bool) public isTrustedRouter;

// ===== NEW V2 SLOTS (15+) — append only =====
// Slot 15
bool public paused;
// Slot 16
mapping(bytes32 => address) private _routerCommittedIdentity;
```

### 1.4 Hook Permissions — V2

```solidity
function getHookPermissions() public pure override returns (Hooks.Permissions memory) {
    return Hooks.Permissions({
        beforeInitialize: true,
        afterInitialize: true,
        beforeAddLiquidity: true,        // NEW V2
        afterAddLiquidity: false,
        beforeRemoveLiquidity: true,     // NEW V2
        afterRemoveLiquidity: false,
        beforeSwap: true,
        afterSwap: true,
        beforeDonate: true,              // NEW V2
        afterDonate: false,
        beforeSwapReturnDelta: false,
        afterSwapReturnDelta: false,
        afterAddLiquidityReturnDelta: false,
        afterRemoveLiquidityReturnDelta: false
    });
}
```

### 1.5 Functions — Complete List

#### Constructor + Initialize
| Function | Access | Notes |
|----------|--------|-------|
| `constructor(IPoolManager)` | deploy | Passes poolManager to BaseHook |
| `initialize(address _diamond, address _usdc)` | proxy admin | ONE overload only. Sets diamond, usdc, initialized=true. Does NOT set _deprecated_locked. |

#### Admin Functions
| Function | Access | Notes |
|----------|--------|-------|
| `registerMarketPool(bytes32 marketId, address yesToken, PoolKey key)` | onlyDiamond | Registers token + poolToMarket mapping. Emits PoolRegistered. |
| `setTrustedRouter(address router, bool trusted)` | onlyDiamond | Emits TrustedRouterUpdated. Validates router != address(0). |
| `setPaused(bool _paused)` | onlyAdmin | Emits PauseStatusChanged. |
| `setDiamond(address _diamond)` | onlyAdmin | Emits DiamondUpdated(old, new). |
| `commitSwapIdentity(address user, PoolId poolId)` | trusted router only | Router pre-commits real user. Key = keccak256(router, block.number, poolId). |

#### Hook Callbacks (override BaseHook internal functions)
| Function | Modifier | Logic |
|----------|----------|-------|
| `_beforeInitialize` | — | Validate token pair + require poolToMarket[poolId] != 0 |
| `_afterInitialize` | — | Set tickLowerLast |
| `_beforeAddLiquidity` | whenNotPaused | Validate market: not resolved, not expired |
| `_beforeRemoveLiquidity` | — | Validate poolToMarket exists only. NO pause check (LPs must exit). |
| `_beforeDonate` | whenNotPaused | Validate market: not resolved |
| `_beforeSwap` | whenNotPaused | Market checks + anti-sandwich + dynamic fee. NO slippage check here. |
| `_afterSwap` | — | Volume tracking (USDC) + tick update + price calc + slippage check + events + referral |

#### View Functions
| Function | Returns |
|----------|---------|
| `getMarketForPool(PoolId)` | bytes32 marketId |
| `isPaused()` | bool |
| `getCommittedIdentity(address router, PoolId poolId)` | address committed user |

### 1.6 hookData Format — PACKED (not abi.encoded)

```
Bytes [0:20]  = referrer address (20 bytes packed)
Bytes [20:40] = maxSqrtPriceX96 (uint160 = 20 bytes packed)
```

Decode referrer:
```solidity
address referrer = address(bytes20(hookData[:20]));
```

Decode slippage:
```solidity
uint160 maxSqrtPriceX96 = uint160(bytes20(hookData[20:40]));
```

Constants:
```solidity
uint256 constant HOOKDATA_REFERRER_LEN = 20;
uint256 constant HOOKDATA_SLIPPAGE_LEN = 40;
```

### 1.7 Anti-Sandwich — Committed Identity Pattern

**V1 problem:** Router sets identity in hookData → anyone can fake any address.

**V2 solution:**
1. Router calls `hook.commitSwapIdentity(msg.sender, poolId)` — stores in `_routerCommittedIdentity[key]`
2. Router calls `poolManager.swap(...)` — hook's `_beforeSwap` reads from committed storage
3. Key = `keccak256(abi.encode(routerAddress, block.number, poolId))` — scoped to this tx

```solidity
// In _beforeSwap:
if (isTrustedRouter[sender]) {
    bytes32 commitKey = keccak256(abi.encode(sender, block.number, key.toId()));
    address committed = _routerCommittedIdentity[commitKey];
    if (committed != address(0)) {
        sandwichIdentity = committed;
    }
    // else: fallback to sender (router address) — safe but less granular
}
```

Direction packing unchanged from V1:
```solidity
uint256 constant DIRECTION_BIT_SHIFT = 8;
uint256 constant DIRECTION_BITMASK = 0xFF;
// packed = (blockNumber << 8) | directionBits
// directionBits: 1 = zeroForOne, 2 = oneForZero, 3 = both (same direction OK)
```

### 1.8 Price Calculation — _sqrtPriceToPrice

```solidity
function _sqrtPriceToPrice(uint160 sqrtPriceX96, PoolKey calldata key)
    internal view returns (uint256)
{
    if (sqrtPriceX96 == 0) return 0;

    // Step 1: FullMath.mulDiv for overflow safety
    uint256 price = FullMath.mulDiv(
        uint256(sqrtPriceX96) * uint256(sqrtPriceX96),
        1e6,
        1 << 192
    );

    // Step 2: Check token order — YES must be currency0 for price to be correct
    address token0 = Currency.unwrap(key.currency0);
    bool yesIsCurrency0 = isRegisteredOutcomeToken[token0];

    // Step 3: Invert if YES is currency1
    if (!yesIsCurrency0) {
        if (price == 0) return 1e6;
        price = FullMath.mulDiv(1e6, 1e6, price);
    }

    // Step 4: Clamp to prediction market range
    if (price > 1e6) price = 1e6;

    return price;
}
```

### 1.9 Volume Tracking — USDC (amount1)

```solidity
// In _afterSwap:
int128 amount1 = delta.amount1();  // USDC is currency1
uint256 usdcVolume = amount1 > 0
    ? uint256(int256(amount1))
    : uint256(int256(-amount1));
marketVolume[marketId] += usdcVolume;

// Also get YES volume for event
int128 amount0 = delta.amount0();
uint256 yesVolume = amount0 > 0
    ? uint256(int256(amount0))
    : uint256(int256(-amount0));
```

### 1.10 Slippage Check — In afterSwap (NOT beforeSwap)

```solidity
// In _afterSwap, AFTER swap executed and sqrtPrice read:
if (hookData.length >= HOOKDATA_SLIPPAGE_LEN) {
    uint160 maxSqrtPriceX96 = uint160(bytes20(hookData[HOOKDATA_REFERRER_LEN:HOOKDATA_SLIPPAGE_LEN]));
    if (maxSqrtPriceX96 > 0) {
        if (params.zeroForOne && sqrtPrice < maxSqrtPriceX96) {
            revert MaxSlippageExceeded();
        }
        if (!params.zeroForOne && sqrtPrice > maxSqrtPriceX96) {
            revert MaxSlippageExceeded();
        }
    }
}
```

### 1.11 Dynamic Fee — Underflow Protected

```solidity
function _calculateDynamicFee(uint256 endTime) internal view returns (uint24) {
    if (block.timestamp >= endTime) return FEE_VERY_HIGH;  // Guard underflow
    uint256 timeToExpiry = endTime - block.timestamp;
    if (timeToExpiry > 7 days) return FEE_NORMAL;    // 50 bps
    if (timeToExpiry > 3 days) return FEE_MEDIUM;    // 100 bps
    if (timeToExpiry > 1 days) return FEE_HIGH;      // 200 bps
    return FEE_VERY_HIGH;                             // 500 bps
}
```

### 1.12 Reentrancy Guard — EIP-1153 Transient Storage

```solidity
bytes32 private constant _REENTRANCY_SLOT =
    0x8e94fed44239eb2314ab7a406345e6c5a8f0ccedf3b600de3d004e672c33abf4;

modifier nonReentrant() {
    assembly {
        if tload(_REENTRANCY_SLOT) {
            mstore(0x00, 0x3ee5aeb5)
            revert(0x1c, 0x04)
        }
        tstore(_REENTRANCY_SLOT, 1)
    }
    _;
    assembly {
        tstore(_REENTRANCY_SLOT, 0)
    }
}
```

### 1.13 Events — Complete List

```solidity
event MarketTraded(
    bytes32 indexed marketId,
    address indexed trader,
    bool isBuy,
    uint256 usdcVolume,    // CHANGED from V1: was `amount` (YES token)
    uint256 yesVolume,     // CHANGED from V1: was `cost` (always 0)
    uint8 side,
    uint256 yesPrice
);

event PoolRegistered(bytes32 indexed marketId, PoolId indexed poolId, address yesToken, address usdcToken);
event ReferralCredited(bytes32 indexed marketId, address indexed referrer, address indexed trader, uint256 usdcVolume);
event TrustedRouterUpdated(address indexed router, bool trusted);     // NEW V2
event PauseStatusChanged(bool paused);                                 // NEW V2
event DiamondUpdated(address indexed oldDiamond, address indexed newDiamond);  // NEW V2
```

### 1.14 Errors — Complete List

```solidity
error MarketNotFound();
error MarketResolved();
error MarketExpired();
error InvalidPool();
error AlreadyInitialized();
error OnlyAdmin();
error ZeroAddress();
error OnlyDiamond();
error SandwichDetected();
error MaxSlippageExceeded();
error HookPaused();          // NEW V2
error IdentityMismatch();    // NEW V2
```

## ====================================================================
## PHASE 2: PrediXHookProxyV2.sol — Proxy Contract
## ====================================================================

### 2.1 File Location
```
src/hooks/PrediXHookProxyV2.sol
```

### 2.2 Key Changes from V1 Proxy
| Feature | V1 | V2 |
|---------|----|----|
| Upgrade | `upgradeImplementation()` instant | `proposeUpgrade()` → 48h wait → `executeUpgrade()` |
| Timelock | None | 48h default, 24h minimum, configurable |
| Cancel | None | `cancelUpgrade()` |
| Hook perms | 4 hooks | 7 hooks (add liquidity, remove liquidity, donate) |
| Admin transfer | Two-step | Two-step (same) |
| ETH receive | None | None (prevent locked ETH) |

### 2.3 Additional ERC1967 Slots (custom)

```solidity
// Standard ERC1967
bytes32 constant IMPLEMENTATION_SLOT = 0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc;
bytes32 constant ADMIN_SLOT = 0xb53127684a568b3173ae13b9f8a6016e243e63b6e8ee1178d6a717850b5d6103;
bytes32 constant PENDING_ADMIN_SLOT = 0xb26bffe953738c6c8b42bc396cdca09736861f1dd9d1dd951f1218e77edbc4f0;

// Custom upgrade timelock slots
bytes32 constant PENDING_IMPL_SLOT = keccak256("predix.hook.proxy.pending.implementation");
bytes32 constant UPGRADE_TIMESTAMP_SLOT = keccak256("predix.hook.proxy.upgrade.timestamp");
bytes32 constant TIMELOCK_DURATION_SLOT = keccak256("predix.hook.proxy.timelock.duration");
```

### 2.4 Proxy Functions

| Function | Access | Notes |
|----------|--------|-------|
| `constructor(IPoolManager, address impl, address admin)` | deploy | Sets impl + admin + default 48h timelock |
| `proposeUpgrade(address newImpl)` | admin | Validate code.length > 0. Set pending + timestamp. |
| `executeUpgrade()` | admin | Require timestamp passed. Re-validate code.length. Update implementation. |
| `cancelUpgrade()` | admin | Clear pending + timestamp. |
| `setTimelockDuration(uint256)` | admin | Min 24h. |
| `changeAdmin(address)` | admin | Set pending admin. |
| `acceptAdmin()` | pending admin | Complete transfer. |
| `implementation()` | view | Current implementation. |
| `admin()` | view | Current admin. |
| `pendingAdmin()` | view | Pending admin. |
| `pendingImplementation()` | view | Pending upgrade target. |
| `upgradeReadyAt()` | view | Timestamp when upgrade executable. |
| `timelockDuration()` | view | Current timelock setting. |

### 2.5 Delegation — Must Delegate ALL 7 Hook Callbacks

```solidity
function _beforeInitialize(...) internal override returns (bytes4) { _delegateRaw(); }
function _afterInitialize(...) internal override returns (bytes4) { _delegateRaw(); }
function _beforeAddLiquidity(...) internal override returns (bytes4) { _delegateRaw(); }      // NEW V2
function _beforeRemoveLiquidity(...) internal override returns (bytes4) { _delegateRaw(); }   // NEW V2
function _beforeSwap(...) internal override returns (bytes4, BeforeSwapDelta, uint24) { _delegateRaw(); }
function _afterSwap(...) internal override returns (bytes4, int128) { _delegateRaw(); }
function _beforeDonate(...) internal override returns (bytes4) { _delegateRaw(); }             // NEW V2
```

Plus `fallback() external payable` for all other calls (registerMarketPool, setTrustedRouter, etc.)

## ====================================================================
## PHASE 3: Update PrediXRouter — commitSwapIdentity Integration
## ====================================================================

The Router must call `hook.commitSwapIdentity(msg.sender, poolId)` BEFORE every swap.

```solidity
// In PrediXRouter.swap() or equivalent:
IPrediXHookV2(hookAddress).commitSwapIdentity(msg.sender, key.toId());
poolManager.swap(key, params, hookData);
```

## ====================================================================
## PHASE 4: Tests
## ====================================================================

### 4.1 Required Test Cases

**Storage compatibility:**
- `test_V2StorageLayout_SlotsMatch` — forge inspect both contracts, compare slots 0–14

**beforeInitialize (C-02):**
- `test_beforeInitialize_RevertsUnregisteredPool` — call poolManager.initialize() directly without registerMarketPool → revert MarketNotFound
- `test_beforeInitialize_PassesRegisteredPool` — Diamond creates market (calls registerMarketPool + initialize) → success

**Liquidity hooks (C-04):**
- `test_beforeAddLiquidity_RevertsResolvedMarket` — add liquidity to resolved market → revert
- `test_beforeAddLiquidity_RevertsExpiredMarket` — add liquidity after endTime → revert
- `test_beforeAddLiquidity_RevertsPaused` — add liquidity when paused → revert HookPaused
- `test_beforeRemoveLiquidity_AllowsResolvedMarket` — remove liquidity from resolved market → success
- `test_beforeRemoveLiquidity_AllowsPaused` — remove liquidity when paused → success

**Anti-sandwich (C-03):**
- `test_antiSandwich_DirectSwap_BothDirectionsSameBlock_Reverts` — swap buy then sell in same block → revert SandwichDetected
- `test_antiSandwich_DirectSwap_SameDirectionSameBlock_Succeeds` — two buys in same block → success
- `test_antiSandwich_Router_CommittedIdentity_DetectsSandwich` — router commits same user, swaps both directions → revert
- `test_antiSandwich_Router_NoCommit_FallsBackToRouter` — router swaps without commit → uses router address

**Price calculation (C-05):**
- `test_sqrtPriceToPrice_YES_Currency0` — YES < USDC address → direct price
- `test_sqrtPriceToPrice_YES_Currency1` — YES > USDC address → inverted price
- `test_sqrtPriceToPrice_ClampToMax` — sqrtPrice representing > $1 → returns 1_000_000
- `test_sqrtPriceToPrice_Zero` — sqrtPrice = 0 → returns 0

**Slippage (H-05):**
- `test_slippageCheck_AfterSwap_Reverts` — large swap exceeding maxSqrtPriceX96 → revert MaxSlippageExceeded
- `test_slippageCheck_AfterSwap_Passes` — swap within tolerance → success
- `test_slippageCheck_NoHookData_NoPriceCheck` — empty hookData → no slippage check

**Volume (H-02):**
- `test_volumeTracking_USDC` — swap and verify marketVolume increased by USDC amount (amount1), not YES amount

**Pause (M-05):**
- `test_pause_BlocksSwaps` — setPaused(true) → swap reverts HookPaused
- `test_pause_AllowsRemoveLiquidity` — paused → remove liquidity succeeds
- `test_unpause_Resumes` — setPaused(false) → swap succeeds

**Proxy timelock (C-01):**
- `test_proxy_ProposeAndExecuteUpgrade` — propose → warp 48h → execute → implementation changed
- `test_proxy_ExecuteBeforeTimelock_Reverts` — propose → execute immediately → revert UpgradeNotReady
- `test_proxy_CancelUpgrade` — propose → cancel → execute reverts NoPendingUpgrade
- `test_proxy_OnlyAdmin` — non-admin propose → revert OnlyAdmin

**Referral:**
- `test_referral_EmitsEvent_NoCreditsAccumulation` — swap with referrer hookData → event emitted, no storage change

**Dynamic fee:**
- `test_dynamicFee_Boundaries` — test all 4 fee tiers at exact boundary timestamps

## ====================================================================
## PHASE 5: Update Constants.sol — Remove Dead Code
## ====================================================================

Remove unused constant:
```solidity
// DELETE THIS LINE:
uint256 constant TRADING_CUTOFF = 1 hours;
```

## ====================================================================
## VERIFICATION CHECKLIST — RUN AFTER ALL PHASES
## ====================================================================

```bash
# 1. Build
forge build

# 2. All tests pass
forge test -vvv

# 3. Storage layout verification
forge inspect PrediXHookV2 storage-layout > v2_layout.json
# Manually verify slots 0–14 match V1

# 4. Gas snapshot
forge snapshot

# 5. Slither static analysis (if available)
slither src/hooks/PrediXHookV2.sol
slither src/hooks/PrediXHookProxyV2.sol
```

## ====================================================================
## REFERENCE FILES — DO NOT MODIFY THESE (read-only context)
## ====================================================================

The following files are provided as REFERENCE. You should READ them to understand the system
but the spec above takes priority if there's any conflict:

- `src/hooks/PrediXHookV1.sol` — the current V1 implementation (source of bugs)
- `src/hooks/PrediXHookProxy.sol` — the current V1 proxy (being replaced)
- `src/facets/market/IMarket.sol` — IMarketBase.MarketData struct
- `src/facets/market/MarketBase.sol` — _setupPool() flow (calls registerMarketPool → initialize)
- `src/tokens/OutcomeToken.sol` — ERC-20 outcome tokens
- `src/oracle/ChainlinkAdapter.sol` — Oracle adapter
- `src/Constants.sol` — Fee constants, tick spacing
- `src/utils/TransientReentrancyGuard.sol` — EIP-1153 pattern reference

## ====================================================================
## AUDIT ISSUE CROSS-REFERENCE
## ====================================================================

| ID | Severity | What Was Wrong in V1 | Where V2 Fixes It |
|----|----------|---------------------|-------------------|
| C-01 | CRITICAL | Custom proxy, no timelock | PrediXHookProxyV2: proposeUpgrade + 48h delay |
| C-02 | CRITICAL | _beforeInitialize accepts any pool | _beforeInitialize: require poolToMarket != 0 |
| C-03 | CRITICAL | hookData identity spoofable | commitSwapIdentity() + read from storage |
| C-04 | CRITICAL | No liquidity hooks → JIT attack | beforeAddLiquidity + beforeRemoveLiquidity enabled |
| C-05 | CRITICAL | sqrtPrice overflow + no inversion | FullMath.mulDiv + token order check + clamp |
| C-06 | CRITICAL | 2 initialize overloads, unused admin | Single initialize(diamond, usdc) |
| H-01 | HIGH | Multi-EOA sandwich bypass | Documented limitation, infra-level recommendation |
| H-02 | HIGH | Volume tracks YES not USDC | delta.amount1() for USDC volume |
| H-03 | HIGH | referralCredits public after deprecation | Changed to private |
| H-04 | HIGH | SSTORE reentrancy (5000 gas) | EIP-1153 transient storage (100 gas) |
| H-05 | HIGH | Slippage check on pre-swap price | Moved to _afterSwap (post-execution) |
| M-01 | MEDIUM | _calculateDynamicFee underflow | Added block.timestamp >= endTime guard |
| M-05 | MEDIUM | No emergency pause | paused flag + whenNotPaused modifier |
