# PrediX V2 — External Security Audit Specification

**Status:** Draft for external auditor engagement
**Target chain:** Unichain (OP Stack L2, Cancun EVM)
**Solidity:** 0.8.30, via_ir, optimizer 200, bytecode_hash none
**Scope:** 6 Foundry packages — `shared`, `oracle`, `diamond`, `hook`, `exchange`, `router`
**Prepared by:** PrediX core team
**Version:** 1.0 (2026-04-14)

This document is the single source of truth for scoping, methodology, deliverables, and acceptance criteria of the external security audit of the PrediX V2 smart contract system. It is written to be handed verbatim to an auditing firm (Spearbit, Trail of Bits, OpenZeppelin, Zellic, Cantina, ChainSecurity, Halborn, Sigma Prime, Code4rena, Sherlock, etc.) as the engagement brief.

---

## 0. Executive summary

PrediX V2 is a binary prediction market protocol built on Uniswap v4 with a diamond (EIP-2535) core, a companion CLOB exchange, a custom v4 hook for dynamic-fee AMM pricing, a stateless aggregator router, and a manual + Chainlink oracle adapter layer. The protocol locks ERC20 collateral (USDC, 6 decimals) and issues complement pairs of YES/NO ERC20 outcome tokens at 1:1 ratio. Users can trade against an AMM (v4 pool + hook) or a CLOB (exchange), with routing arbitrated by a stateless router contract. Resolution is permissioned via an approved-oracle whitelist; redemption pays the winning leg 1:1 minus a configurable protocol fee capped at 15%.

**Critical invariants to audit:**

1. **Collateral solvency (diamond):** for every unresolved market, `YES.totalSupply == NO.totalSupply == market.totalCollateral`.
2. **Exchange solvency:** `sum(order.depositLocked) == USDC.balanceOf(exchange) + sum(outcomeToken.balanceOf(exchange))` at all times.
3. **Router non-custody:** `USDC.balanceOf(router) == 0 && outcomeToken.balanceOf(router) == 0` after every external call.
4. **Redemption fee bound:** effective redemption fee ≤ `MAX_REDEMPTION_FEE_BPS = 1500` (15%) in every code path.
5. **Hook identity commit:** beforeSwap pricing can only execute if the router has committed caller identity in the same transaction via EIP-1153 transient storage.
6. **Oracle monotonicity:** once a market is resolved, outcome and `resolvedAt` are immutable; refund mode cannot be enabled after resolution.

---

## 1. Protocol overview (for the auditor)

### 1.1 Architecture diagram

```
                    ┌──────────────┐
                    │   Router     │ (stateless, Permit2, quote + execute)
                    └──────┬───────┘
          ┌────────────────┼────────────────┐
          │                │                │
          ▼                ▼                ▼
     ┌────────┐      ┌──────────┐     ┌─────────┐
     │Exchange│      │ v4 Pool  │────▶│  Hook   │ (ERC1967 proxy, dynamic fee)
     │ (CLOB) │      │ (v4-core)│     └─────────┘
     └────┬───┘      └─────┬────┘          │
          │                │               │
          └────────┬───────┴───────────────┘
                   ▼
            ┌─────────────┐
            │   Diamond   │ (EIP-2535)
            │  ┌────────┐ │
            │  │ Market │ │── LibMarket, LibConfigStorage
            │  │ Event  │ │── LibEventStorage (multi-outcome)
            │  │ Access │ │── LibAccessControlStorage
            │  │ Pause  │ │── LibPausableStorage
            │  │ Loupe  │ │
            │  │  Cut   │ │── LibDiamondStorage (facet map)
            │  └────────┘ │
            └──────┬──────┘
                   │
                   ▼
            ┌─────────────┐           ┌─────────────┐
            │OutcomeToken │           │  Oracle     │
            │ (ERC20+P)   │           │ Manual /    │
            │ factory-mint│           │ Chainlink   │
            └─────────────┘           └─────────────┘
```

### 1.2 Monorepo boundary (hard rule, SC/CLAUDE.md §2)

```
shared ← oracle ← diamond ← hook, exchange, router
                                  ↑
                            router ↔ exchange, hook (via interface)
```

- Cross-package imports **only** via `@predix/shared/interfaces/` or `@predix/shared/` libs.
- No package imports another package's `src/...` directly.
- All shared types (structs, events, errors, constants) live in `packages/shared/src/`.

### 1.3 Business flow

1. **Admin** approves oracle via `MarketFacet.approveOracle`.
2. **Creator** calls `createMarket(question, endTime, oracle)`, which deploys a complement pair of `OutcomeToken` (YES/NO) and assigns `marketId` (monotonic).
3. **Trader** deposits `X` USDC via `splitPosition(marketId, X)` → receives `X` YES + `X` NO.
4. **Trader** sells one leg on:
   - **CLOB** (exchange) — limit orders, price range `(0, 1e6)`, complement pair matching.
   - **AMM** (v4 pool + hook) — dynamic-fee swap; hook prices both legs.
5. **Router** aggregates CLOB + AMM liquidity via `V4Quoter` (revert-and-decode), splits the order, and executes with Permit2 signature or pre-approval.
6. At `endTime`, **anyone** calls `resolveMarket(marketId)` — pulls outcome from the market's oracle (must have been approved at creation time and still approved is not required — existing markets keep their oracle).
7. Winners call `redeem(marketId)` → burns both legs, pays winning leg 1:1 minus redemption fee (`defaultRedemptionFeeBps` or per-market override).
8. **Fallbacks:**
   - `emergencyResolve` after `endTime + EMERGENCY_DELAY` (7 days) — `OPERATOR_ROLE`.
   - `enableRefundMode` on unresolved ended markets — `ADMIN_ROLE`, bypasses pause.
   - `sweepUnclaimed` after `GRACE_PERIOD` (365 days) post-finalization — `ADMIN_ROLE`.

### 1.4 Trust assumptions

- **Admin (multisig):** fully trusted — can approve/revoke oracles, set fees, enable refund mode, upgrade diamond facets, sweep unclaimed.
- **Operator:** trusted only for `emergencyResolve` after 7-day stall.
- **Approved oracle:** trusted to report correct outcome; bad oracle can destroy a market but cannot affect other markets or drain collateral.
- **Router:** untrusted (stateless, no custody).
- **Hook proxy admin:** separate 2-step timelock (48h); distinct from diamond admin for blast-radius isolation.
- **USDC:** assumed standard 6-decimals, no fee-on-transfer, no rebasing, no blacklist effects on protocol contracts.
- **Chainlink feed:** assumed honest + live; sequencer uptime feed guards L2 downtime (`SEQUENCER_GRACE_PERIOD = 1h`, `MAX_STALENESS = 1h`).

---

## 2. Audit methodology

The audit must combine **four parallel tracks**, each with its own deliverable. No single technique suffices.

### 2.1 Track A — Manual review (primary)

Line-by-line read by at least **two senior auditors working independently**, comparing notes only after each has produced an initial finding list. This is the single highest-signal activity and cannot be replaced by tooling.

**Per-contract checklist:**

1. **Business logic** — does the code match the spec in `SC/specs/` and this document?
2. **Invariants** — what must always hold? Is it enforced everywhere state changes?
3. **Access control** — every state-mutating external/public: who can call it, is the modifier at the top, is there an event?
4. **CEI ordering** — checks → effects → interactions, no state update after external call.
5. **Reentrancy** — guard present, transient storage slot unique, cross-function reentrancy considered.
6. **Arithmetic** — overflow, rounding direction (round against user on deposit/redeem), division before multiplication.
7. **External-call return values** — every `.call` / ERC20 transfer checked or uses SafeERC20.
8. **Storage layout** — diamond & proxy storage append-only, no reorder, no collision across facets.
9. **Upgradeability** — constructor `_disableInitializers()`, `initializer` modifier present, immutable variables correct, storage gap if needed.
10. **Edge cases** — `amount = 0`, `amount = type(uint256).max`, empty arrays, self-calls, same-address transfers, resolution at exact `endTime`, tie conditions.

**Deliverable A:** written finding list per package, each finding with file:line, severity, impact, likelihood, PoC, and recommended fix.

### 2.2 Track B — Automated static analysis

Run the following tools on **every package independently**. Every true-positive finding must appear in the report; every false-positive must be documented with justification.

| Tool | Purpose | Command |
|---|---|---|
| **Slither** | Detectors for reentrancy, uninitialized state, shadowing, tx.origin, dangerous delegatecall, missing zero-address checks | `slither packages/<pkg>/src --solc-remaps @predix=packages --config slither.config.json` |
| **Aderyn** (Cyfrin) | Rust-based detector suite, complements Slither | `aderyn packages/<pkg>` |
| **4naly3er** | Gas + informational findings | `npx 4naly3er ./packages/<pkg>/src` |
| **Solhint** | Style + best-practice lint | `solhint "packages/<pkg>/src/**/*.sol"` |
| **Solidity Metrics** (Consensys / tintinweb) | Complexity scoring; functions with CC > 10 must be justified | VSCode extension or `solidity-code-metrics` |

**Deliverable B:** full tool output + triage table (true positive / false positive / suppressed with reason).

### 2.3 Track C — Fuzzing & property-based testing

The team already ships Foundry invariant tests; the auditor must **extend and re-run** them with longer runs and additional properties. Minimum 256k runs per invariant; critical invariants at 1M runs.

| Tool | Target | Minimum budget |
|---|---|---|
| **Foundry invariant** | Critical invariants (see §3) | 1M runs for top 5 |
| **Echidna** | Property-based, independent harness in `echidna/` | 500k sequences, 50 txs each |
| **Medusa** (Trail of Bits) | Fuzzer with coverage-guided engine | same as Echidna |
| **Halmos** (a16z) | Symbolic execution, path enumeration for math-heavy helpers (`MatchMath`, `PriceBitmap`, `TickMath` call sites) | unbounded, default config |
| **Ityfuzz** (optional) | Hybrid fuzzer — useful for discovering cross-function reentrancy | stretch goal |

**Deliverable C:** new Echidna/Medusa harness files committed to `packages/<pkg>/echidna/`, run logs, coverage report, any counterexample saved as a Foundry repro test under `test/repro/`.

### 2.4 Track D — Formal verification (scoped)

Formal verification is **not** required for the whole protocol (prohibitive cost) but **is** required for three critical subsystems. The auditor may use Certora Prover, Halmos, or hevm symbolic tests.

1. **Redemption fee math** — prove `fee ≤ winningBurned * MAX_REDEMPTION_FEE_BPS / 10000` and `fee + payout == winningBurned` for all inputs in `MarketFacet.redeem`.
2. **CLOB solvency** — prove exchange collateral invariant holds over `splitMatch`, `mergeMatch`, `takeMatch`, `makeMatch` state transitions.
3. **Diamond storage non-collision** — prove that each facet's storage slot `keccak256("predix.storage.<module>")` does not collide with any other module's layout under any facet cut sequence.

**Deliverable D:** Certora spec files (or Halmos test files) + verification logs + list of assumptions (loop unrolls, bounded ints, etc.).

### 2.5 Track E — Integration & fork testing

The v4-core pragma (0.8.26) is incompatible with the diamond (0.8.30). The team currently uses an integration stub in router tests. The auditor must either:

- **Option 1** — stand up a real v4-core PoolManager in isolation (separate compilation), deploy the hook against it, and run router round-trip tests.
- **Option 2** — perform fork tests against Unichain testnet (Sepolia L2) with real PoolManager + Chainlink + Permit2.

Permit2 canonical deployment: `0x000000000022D473030F116dDEE9F6B43aC78BA3`.

**Deliverable E:** fork test suite under `test/fork/`, run log, list of discovered behaviors that differ from integration stub.

---

## 3. Critical invariants to verify

These invariants **must** be proven (fuzz + formal). Each is tagged with the file(s) that enforce it.

### INV-1 — Diamond collateral solvency (CRITICAL)

**Statement:** For every market where `isResolved == false && refundModeActive == false`:
```
YES.totalSupply == NO.totalSupply == market.totalCollateral
```
**Enforced by:** [MarketFacet.splitPosition](packages/diamond/src/facets/market/MarketFacet.sol), `mergePositions`, `refund`
**Test:** existing `invariant_SplitMergeCollateralIntegrity` in diamond test suite — extend to all state transitions.

### INV-2 — Exchange solvency (CRITICAL)

**Statement:** At all times and for every outcome token:
```
sum(order.depositLocked for order in orderbook) ==
  USDC.balanceOf(exchange) + sum(YES.balanceOf(exchange) + NO.balanceOf(exchange) across markets)
```
**Enforced by:** `TakerPath`, `MakerPath`, `ExchangeStorage` helpers
**Test:** existing strict solvency invariants in exchange package — verify extended to 1M runs.

### INV-3 — Router non-custody (HIGH)

**Statement:** After every external function returns successfully and after every revert:
```
USDC.balanceOf(router) == 0 && all outcomeToken balances of router == 0
```
**Enforced by:** `PrediXRouter` (stateless design, no storage)
**Test:** new invariant test required — assert non-custody after every `exec*` path.

### INV-4 — Redemption fee bound (HIGH)

**Statement:**
```
∀ marketId: effectiveRedemptionFeeBps(marketId) ≤ MAX_REDEMPTION_FEE_BPS (1500)
∀ redeem call: fee + payout == winningBurned
```
**Enforced by:** [MarketFacet.setDefaultRedemptionFeeBps](packages/diamond/src/facets/market/MarketFacet.sol), `setPerMarketRedemptionFeeBps`, `_effectiveRedemptionFee`, `redeem`
**Test:** formal verification required (Track D #1).

### INV-5 — Hook identity commit (HIGH)

**Statement:** `beforeSwap` reverts unless `_routerCommittedIdentity[keccak256(poolId, caller)]` is set in the same transaction (EIP-1153 transient).
**Enforced by:** `PrediXHookV2.beforeSwap`, `PrediXRouter` commit calls
**Test:** direct-swap-bypass test, cross-transaction replay test (transient cleared after tx).

### INV-6 — Resolution monotonicity (MEDIUM)

**Statement:** Once `isResolved == true`, `outcome` and `resolvedAt` never change; `refundModeActive` can never be set true.
**Enforced by:** `resolveMarket`, `emergencyResolve`, `enableRefundMode` (pre-check `!isResolved`)
**Test:** existing unit tests + fuzz on admin function call order.

### INV-7 — Outcome token supply bound (MEDIUM)

**Statement:** Only the diamond (factory) can mint/burn outcome tokens. `OutcomeToken.mint`/`burn` reverts for any other caller.
**Enforced by:** `OutcomeToken` constructor-assigned `factory` immutable.
**Test:** unit test + access control fuzz.

### INV-8 — Last admin lockout protection (MEDIUM)

**Statement:** `AccessControlFacet.renounceRole(DEFAULT_ADMIN_ROLE)` reverts if caller is the last admin; `revokeRole` same.
**Enforced by:** `LibAccessControl.memberCount` + `_enforceLastAdminGuard`.
**Test:** existing unit test + invariant that `memberCount[DEFAULT_ADMIN_ROLE] ≥ 1` always.

### INV-9 — Per-market cap enforcement (MEDIUM)

**Statement:** After any `splitPosition`, `market.totalCollateral ≤ effectivePerMarketCap(market)`.
**Enforced by:** `splitPosition` cap check.
**Test:** fuzz test split with random caps.

### INV-10 — Oracle approval ratchet (LOW)

**Statement:** `createMarket` requires `approvedOracles[oracle] == true` at call time; revoking an oracle after market creation does not block resolution of existing markets.
**Enforced by:** `createMarket`, `resolveMarket` reading stored oracle.
**Test:** unit test sequence.

---

## 4. Per-package audit scope

### 4.1 `shared` (foundation)

**Files to audit:**
- `constants/Roles.sol`, `Modules.sol`
- `utils/TransientReentrancyGuard.sol` — EIP-1153 slot uniqueness, re-entry across facets
- `tokens/OutcomeToken.sol` — ERC20+Permit, factory-only mint/burn, 6 decimals hardcoded
- `interfaces/*.sol` — event/error signatures (changing these is a breaking ABI change post-audit)

**Focus areas:**
1. Transient reentrancy guard namespacing — verify slot does not collide with any facet's diamond storage slot or any transient slot used elsewhere.
2. `OutcomeToken.mint`/`burn` — factory-only enforcement, no back-door.
3. ERC20Permit nonce handling — replay protection.
4. `SafeERC20` usage everywhere tokens flow.

**Expected effort:** 1 day.

### 4.2 `oracle`

**Files to audit:**
- `adapters/ManualOracle.sol` — OZ AccessControl with `REPORTER_ROLE`
- `adapters/ChainlinkOracle.sol` — with L2 sequencer uptime feed support
- `interfaces/IManualOracle.sol`, `IChainlinkOracle.sol`

**Focus areas:**
1. **Chainlink staleness** — `MAX_STALENESS = 1h` bound, `answeredInRound` deprecation considered.
2. **Sequencer uptime** — `SEQUENCER_GRACE_PERIOD = 1h` after L2 comes back up; verify against [Chainlink L2 sequencer docs](https://docs.chain.link/data-feeds/l2-sequencer-feeds).
3. **Round data validation** — `price > 0`, `updatedAt > 0`, `startedAt > 0`.
4. **Manual oracle access control** — `REPORTER_ROLE` enforcement, idempotency of `setOutcome`.
5. **Price threshold interpretation** — who decides YES/NO from numeric feed? Document decision rule and verify no front-running window.

**Historical hacks to check against:**
- Compound price feed mis-configuration (2020)
- Mango Markets oracle manipulation (Oct 2022)
- Cream Finance (flash loan → oracle manipulation)

**Expected effort:** 1.5 days.

### 4.3 `diamond`

**Files to audit:** all facets + libs + init + proxy. This is the protocol core.

**Files:**
- `proxy/Diamond.sol`, `init/DiamondInit.sol`, `init/MarketInit.sol`
- `facets/cut/DiamondCutFacet.sol`, `facets/loupe/DiamondLoupeFacet.sol`
- `facets/access/AccessControlFacet.sol`, `facets/pausable/PausableFacet.sol`
- `facets/market/MarketFacet.sol` — largest, most critical
- `facets/event/EventFacet.sol` — multi-outcome coordinator
- `libraries/LibDiamondStorage.sol`, `LibAccessControlStorage.sol`, `LibPausableStorage.sol`, `LibMarketStorage.sol`, `LibEventStorage.sol`, `LibConfigStorage.sol`
- `libraries/LibDiamond.sol`, `LibMarket.sol`, `LibAccessControl.sol`, `LibPausable.sol`

**Focus areas:**

1. **Diamond storage non-collision** — every library uses `keccak256("predix.storage.<module>.v<n>")`; verify uniqueness and that `v<n>` bumps when layout changes.
2. **Storage append-only** — `LibMarketStorage` v1.3 added `eventId`, `perMarketRedemptionFeeBps`, `redemptionFeeOverridden`. Verify these are at the end, not in the middle.
3. **Facet cut authorization** — only `DEFAULT_ADMIN_ROLE` can call `diamondCut`; no backdoor via `fallback`.
4. **Selector conflicts** — loupe must reflect exact selectors; no shadow selectors.
5. **Init re-entry guard** — `DiamondInit.init()` can only run once.
6. **Last-admin lockout** — verified by `_enforceLastAdminGuard`.
7. **Redemption fee math** — `fee = winningBurned * feeBps / 10000`, `payout = winningBurned - fee`, `fee + payout == winningBurned`, no rounding drain.
8. **Cap enforcement on split** — per-market cap override + default cap, `0` means unlimited (verify with `setPerMarketCap(id, 0)`).
9. **Refund mode** — cannot be enabled if resolved; burn amounts must match pre-resolution invariant.
10. **Emergency resolve** — 7-day delay, operator role, bypasses pause (intentional).
11. **Sweep unclaimed** — 365-day grace, target is `feeRecipient`, emits event.
12. **Pausable** — verify every external entry point respects the pause, except `emergencyResolve`, `enableRefundMode`, `sweepUnclaimed` (intentional bypass for emergencies).
13. **Market creation fee** — pulled from creator, non-refundable, no reentrancy window.
14. **Event facet mutual exclusion** — verify `Market_PartOfEvent` revert guards every child-market entry point.
15. **`eventId = 0` sentinel** — ensure standalone markets never collide with event coordination.

**Historical hacks to check against:**
- **Audius governance proxy collision** (July 2022) — storage slot collision in upgradeable proxy.
- **Nomad bridge** (Aug 2022) — init function replay.
- **Parity multisig** (2017) — unprotected init/delegatecall.
- **Qubit bridge** (Jan 2022) — missing access control on deposit.
- **Wormhole** (Feb 2022) — signature verification bypass (relevant to oracle/signature paths).

**Expected effort:** 4 days (this is the longest package).

### 4.4 `hook`

**Files to audit:**
- `hooks/PrediXHookV2.sol` — implements `IHooks` directly, custom `onlyPoolManager`, permissionless `registerMarketPool`
- `proxy/PrediXHookProxyV2.sol` — ERC1967 + 48h timelock + 2-step admin + atomic init in constructor
- `interfaces/IPrediXHook.sol`, `IPrediXHookProxy.sol`
- `constants/FeeTiers.sol`

**Focus areas:**

1. **Hook address salt mining** — `getHookPermissions()` flags must match the deployed address's lower bits (v4-core requirement). Any mismatch = permanent brick.
2. **`beforeSwap` fee override** — OR with `LPFeeLibrary.OVERRIDE_FEE_FLAG`, verify via v4-core test fixtures.
3. **Identity commit** — `_routerCommittedIdentity` transient slot: verify namespacing, same-tx-only guarantee, cleared after tx (automatic EIP-1153 behavior).
4. **`onlyPoolManager`** — custom modifier, verify no bypass, compare against `BaseHook` reference (v4-periphery).
5. **Permissionless `registerMarketPool`** — verify currency validation (YES+NO tokens registered to diamond) is sufficient; attacker-registered pool cannot poison state of legitimate markets.
6. **Proxy atomic init** — constructor delegatecalls impl.initialize. Verify no front-run window where impl is exposed unininitialized.
7. **48h timelock bypass** — verify no path skips the timelock; admin rotation 2-step (propose + accept).
8. **Pricing logic** — dynamic fee calculation: is input sanitized? Can an attacker pass sqrtPriceLimitX96 that causes under/overflow?
9. **No fund custody** — hook must never hold USDC or outcome tokens between transactions.

**Historical hacks to check against:**
- **Uniswap v4 hook exploits** (research `samczsun` and recent hook audits) — especially hook re-entry via `unlock`.
- **Proxy init front-run** (multiple incidents) — Initializable pattern mistakes.
- **Tornado Cash governance** (May 2023) — malicious proposal via proxy + init.

**Expected effort:** 2 days.

### 4.5 `exchange`

**Files to audit:**
- `IPrediXExchange.sol`, `PrediXExchange.sol`, `ExchangeStorage.sol`
- `mixins/TakerPath.sol`, `MakerPath.sol`, `Views.sol`
- `libraries/PriceBitmap.sol`, `MatchMath.sol`

**Focus areas:**

1. **Solvency invariant** (INV-2) — strictest invariant in the codebase.
2. **Dust filter (Option 4)** — atomic skip before state mutation at `TakerPath` lines 200/267/299. Verify no path where `outDelta == 0` but `cost` already updated.
3. **Match math** — rounding direction, `MatchMath.mulDivDown` vs `mulDivUp` selection.
4. **Price bitmap** — bit manipulation correctness, off-by-one on `nextPriceUp`/`nextPriceDown`.
5. **Order queue integrity** — `_removeFromQueue` preserves FIFO, no gaps.
6. **Complement pair matching** — user A's YES sell matches user B's NO sell into a split, not a YES-YES trade.
7. **Maker fully-filled (M1+M5)** — fixed in prior review; verify no regression.
8. **Reentrancy** — every external entry has the guard.
9. **Pause respect** — `onlyPauser` via diamond `Roles.PAUSER_ROLE`.
10. **Permit2** — if exchange accepts Permit2, verify signature reuse bounds.
11. **Gas DoS** — orderbook walk bounded by `maxFills` param.

**Historical hacks to check against:**
- **Polymarket CTF exchange** — study audit findings by OpenZeppelin on the same complement-pair pattern.
- **0x exchange** (2019) — signature malleability.
- **Hashflow** (2023) — signature verification.
- **Level Finance** (May 2023) — reward accounting double-claim.

**Expected effort:** 3 days.

### 4.6 `router`

**Files to audit:**
- `PrediXRouter.sol` — 9 immutables, 4 trade primitives, 4 Permit2 variants, 4 quote functions
- `interfaces/IPrediXRouter.sol`, `IPrediXExchangeView.sol`, `IPrediXHookCommit.sol`

**Focus areas:**

1. **Non-custody** (INV-3).
2. **Permit2 integration** — signature deadline, nonce uniqueness, witness binding.
3. **V4Quoter H-03 fix** — revert-and-decode, correct error selector parsing.
4. **Fee-adjusted CLOB caps** — `_clob*Limit` wrappers compute cap from AMM fee-adjusted spot; verify no off-by-one.
5. **Virtual-NO path** — 3% safety margin; verify `slippageBps` bounds.
6. **Hook commit before unlock** — identity commit must happen before `PoolManager.unlock`.
7. **Aggregation math** — split ratio between CLOB and AMM: verify profit maximization cannot be gamed.
8. **Quote vs execute divergence** — the quote is an off-chain hint, execute uses `amountOutMin` slippage floor; verify floor enforced.
9. **Reentrancy** — router is stateless but calls many externals; ensure no state to corrupt.

**Historical hacks to check against:**
- **1inch router v5 approvals** — unlimited approval risk.
- **SushiSwap RouteProcessor2** (April 2023) — 1:1 balance check bypass.
- **Kyber Aggregator** (Sep 2022) — front-end compromise; out of scope but document.
- **MEV sandwich attacks** — verify slippage floor is the only user-facing protection and document.

**Expected effort:** 2.5 days.

---

## 5. Vulnerability taxonomy — checklist

The auditor must explicitly state **present / absent / n/a** for every item below, per package. This is non-negotiable — the protocol team needs a complete coverage map.

### 5.1 SWC Registry (classical)

| ID | Name | Applicable packages |
|---|---|---|
| SWC-101 | Integer overflow/underflow | all (verify 0.8 + unchecked blocks) |
| SWC-104 | Unchecked call return value | all |
| SWC-105 | Unprotected ether withdrawal | n/a (no ether handling) |
| SWC-106 | Selfdestruct | n/a (Cancun removed) |
| SWC-107 | Reentrancy (same-function, cross-function, read-only) | diamond, exchange, router, hook |
| SWC-108 | State variable default visibility | all |
| SWC-109 | Uninitialized storage pointer | all |
| SWC-110 | Assert violation | all |
| SWC-111 | Deprecated Solidity functions | all |
| SWC-112 | Delegatecall to untrusted callee | diamond, hook proxy |
| SWC-113 | DoS with failed call | exchange (orderbook), router |
| SWC-114 | Front-running / transaction ordering | router, exchange, oracle |
| SWC-115 | tx.origin auth | all |
| SWC-116 | block.timestamp used as trust anchor | diamond (endTime, EMERGENCY_DELAY, GRACE_PERIOD), oracle |
| SWC-117 | Signature malleability | router (Permit2), exchange (if signed orders) |
| SWC-118 | Incorrect constructor name | n/a (modern Solidity) |
| SWC-119 | Shadowing state variables | all |
| SWC-120 | Weak randomness | n/a (no RNG) |
| SWC-121 | Missing protection against signature replay | router, oracle (manual) |
| SWC-123 | Requirement violation | all |
| SWC-124 | Write to arbitrary storage | hook (assembly), shared (transient) |
| SWC-125 | Incorrect inheritance order | diamond (facet composition) |
| SWC-126 | Insufficient gas griefing | exchange (orderbook walk) |
| SWC-127 | Arbitrary jump with function type | n/a |
| SWC-128 | DoS with block gas limit | exchange, router (quote loops) |
| SWC-129 | Typographical error | all |
| SWC-130 | Right-To-Left-Override | all |
| SWC-131 | Presence of unused variables | all |
| SWC-132 | Unexpected ether balance | n/a |
| SWC-133 | Hash collisions with multiple variable-length args | all (`abi.encodePacked`) |
| SWC-134 | Message call with hardcoded gas | all |
| SWC-135 | Code with no effects | all |
| SWC-136 | Unencrypted private data | all |

### 5.2 Modern vulnerability classes (post-SWC, from 2021+ post-mortems)

- [ ] **Price oracle manipulation** via flash loan (bZx, Harvest, Cream) — document oracle design resistance.
- [ ] **Cross-contract reentrancy** via ERC777 / ERC721 callbacks / custom tokens — OutcomeToken is plain ERC20, but verify.
- [ ] **Read-only reentrancy** (Curve / Balancer class) — verify no view function returns stale state during reentrancy window.
- [ ] **Flash-loan governance attack** — verify admin cannot be flash-loaned into control (governance is multisig, not token-based, but confirm).
- [ ] **ERC4626 inflation / first-depositor attack** — n/a (no vault), but check if `OutcomeToken` pattern has equivalent risk.
- [ ] **Signature replay across chains** — Permit2 uses chainId, verify.
- [ ] **Permit phishing** (Uniswap Permit2 drain pattern) — document user education responsibility.
- [ ] **MEV sandwich** (router) — slippage parameter enforced.
- [ ] **JIT liquidity** (v4 hook) — does dynamic fee help or hurt JIT?
- [ ] **Pool manager hook re-entry** (Uniswap v4-specific) — hook must not call pool manager except within its own `beforeSwap`/`afterSwap` frame.
- [ ] **Storage collision across upgrades** (diamond + proxy) — §4.3 focus.
- [ ] **Gas griefing via malicious token** — n/a, USDC is whitelisted.
- [ ] **ERC20 approve race** — use `forceApprove` / increase/decrease.
- [ ] **Proxy admin = implementation admin** (Parity-class) — verify separation.
- [ ] **Precision loss / donation attacks** — exchange `MatchMath`, redemption fee.
- [ ] **Double-entry ERC20** (e.g. legacy TUSD) — USDC is not dual-address, document assumption.
- [ ] **Fee-on-transfer token** — USDC is not FoT; verify pre/post balance check if protocol ever integrates another collateral.
- [ ] **Rebasing token** — same, verify.
- [ ] **Blocklisted token recipient** — what happens if USDC blocks `feeRecipient`? Document.
- [ ] **Griefing via dust order spam** (exchange) — maxFills bound documented.
- [ ] **Governance delay bypass** (timelock) — verify hook proxy 48h timelock has no escape.

### 5.3 Uniswap v4 hook-specific risks (emerging class)

Reference: [OpenZeppelin uniswap-hooks](https://github.com/OpenZeppelin/uniswap-hooks), [v4-periphery BaseHook](https://github.com/Uniswap/v4-periphery).

- [ ] Hook address permissions flag mismatch → brick.
- [ ] `beforeSwap` return value format (delta vs fee) correct.
- [ ] `OVERRIDE_FEE_FLAG` OR'd in return.
- [ ] `unlock` callback `msg.sender == poolManager`.
- [ ] Hook does not hold funds across transactions.
- [ ] Hook does not trust `sender` parameter (it's the caller of PoolManager, not necessarily the user).
- [ ] Hook-initiated swaps do not recurse.
- [ ] Native ETH handling (n/a, USDC only, but document).
- [ ] `HookData` passed to hook is untrusted.

---

## 6. Historical hack case studies — required reading

The auditor must confirm they have read each post-mortem and document which of the following failure modes **do not** apply to PrediX V2 and why.

### 6.1 DeFi hacks directly relevant to PrediX

| Year | Target | Root cause | Relevance to PrediX |
|---|---|---|---|
| 2016 | The DAO | Reentrancy | Diamond + Exchange reentrancy guards |
| 2017 | Parity Multisig | Unprotected `initWallet` delegatecall | Diamond init + hook proxy init |
| 2020 | bZx | Flash loan + oracle manipulation | Oracle design |
| 2020 | Harvest | Same | Oracle |
| 2021 | Compound | Token distribution bug (COMPtoken) | Redemption / fee math |
| 2021 | PolyNetwork | Access control bypass in keeper | Admin / operator roles |
| 2021 | Cream | Cross-asset re-entry | Exchange cross-pair |
| 2021 | BadgerDAO | Frontend compromise + Permit2 drain | Out of scope — document |
| 2022 | Wormhole | Signature verification | Permit2 / Router |
| 2022 | Ronin | Compromised validator keys | Admin key management |
| 2022 | Nomad | Init replay | Diamond init guard |
| 2022 | Beanstalk | Flash governance | Governance design (multisig only) |
| 2022 | Mango | Oracle manipulation via illiquid market | Oracle adapter |
| 2022 | Audius | Storage proxy collision | Diamond storage |
| 2023 | Euler | Donation + liquidation accounting | CLOB solvency |
| 2023 | Curve (Vyper compiler) | Compiler-level reentrancy lock failure | Foundry 0.8.30 — compiler trust |
| 2023 | Multichain | Admin key compromise | Timelock + multisig |
| 2023 | KyberSwap | Tick manipulation in CLMM math | v4 hook math |
| 2023 | Mixin | Cloud-hosted key compromise | Key storage |
| 2024 | Radiant Capital | Compromised multisig signer | Multisig threshold |
| 2024 | Penpie | Reentrancy via reward claim hook | Hook re-entry |
| 2024 | WazirX | Multisig phishing | Admin social engineering |

### 6.2 Required references

- [Rekt.news leaderboard](https://rekt.news/leaderboard/) — top 50 post-mortems
- [DeFiLlama hacks dashboard](https://defillama.com/hacks)
- [Immunefi public disclosures](https://immunefi.com/explore/) — bug classes with PoC
- [samczsun blog](https://samczsun.com/) — especially posts on Uniswap v3/v4 math, reentrancy, `ecrecover` pitfalls
- [Trail of Bits publications](https://github.com/trailofbits/publications) — audit reports with similar scope
- [OpenZeppelin audits](https://blog.openzeppelin.com/security-audits) — especially v4-hook and prediction-market audits
- [Spearbit portfolio](https://spearbit.com/portfolio) — recent DeFi audits
- [Code4rena findings](https://code4rena.com/reports) — aggregate finding database
- [Sherlock audit reports](https://audits.sherlock.xyz)

---

## 7. Audit tools — required configuration

### 7.1 Slither config

`slither.config.json`:

```json
{
  "detectors_to_exclude": "naming-convention,solc-version,pragma",
  "filter_paths": "lib/,test/,out/,node_modules/",
  "compile_force_framework": "foundry",
  "exclude_informational": false,
  "exclude_low": false
}
```

Run per-package:
```
cd packages/<pkg> && slither . --config ../../slither.config.json
```

### 7.2 Echidna config

`echidna.yaml`:

```yaml
testMode: assertion
testLimit: 500000
seqLen: 100
shrinkLimit: 5000
corpusDir: "echidna-corpus"
coverage: true
deployer: "0x30000"
contractAddr: "0x10000"
balanceContract: 0
balanceAddr: 1000000000000000000000
maxGasprice: 0
```

### 7.3 Foundry invariant config (per package `foundry.toml`)

```toml
[invariant]
runs = 1024
depth = 256
fail_on_revert = false
call_override = false
dictionary_weight = 80
include_storage = true
include_push_bytes = true
```

For audit, override at CLI:
```
forge test --match-test invariant_ --fuzz-runs 1000000 --invariant-runs 10000 --invariant-depth 512
```

### 7.4 Halmos

```bash
halmos --contract <ContractName> --function <function> --loop 256 --solver-timeout-branching 1000
```

Targets: `MatchMath`, `PriceBitmap`, `_effectiveRedemptionFee`, `redeem`.

### 7.5 Certora (if used)

Spec files under `packages/<pkg>/certora/specs/`, verification via `certoraRun` with `--rule` flags per invariant. See §2.4 for targets.

---

## 8. Severity classification & reporting format

### 8.1 Severity matrix (Immunefi-style, adapted)

| Severity | Impact | Likelihood | Example |
|---|---|---|---|
| **Critical** | Direct loss of user funds or permanent protocol halt | High or certain | Reentrancy drain, unprotected mint, last-admin lockout |
| **High** | Loss of funds under specific conditions, or severe DoS | Medium–High | Oracle manipulation with bounded loss, redemption fee bypass |
| **Medium** | Degraded functionality, griefing, recoverable state corruption | Medium | Pause bypass, dust grief, off-by-one in fee math |
| **Low** | Minor logic deviation, suboptimal gas, missing event | Low | Missing zero-check, unused variable, inconsistent NatSpec |
| **Informational** | Code quality, style, documentation | N/A | Naming, formatting, redundant checks |

### 8.2 Finding report format

Every finding must include:

```
### [C-01] Title

**Severity:** Critical
**Impact:** <1-2 sentences>
**Likelihood:** <High/Medium/Low> because <reason>
**File:** packages/diamond/src/facets/market/MarketFacet.sol#L123-L145
**Description:** <technical explanation>
**Proof of concept:**
```solidity
// minimal repro test
function testExploit() public { ... }
```
**Recommended fix:** <concrete, minimal patch>
**Resolution status:** <to be filled by protocol team>
```

### 8.3 Deliverables

1. **Preliminary report** — within 3 business days of audit start, covering scope confirmation, initial findings, and any blockers.
2. **Draft report** — at audit end, full finding list, no acknowledgement required.
3. **Final report** — after fix verification, each finding marked Fixed / Acknowledged / Won't fix.
4. **Executive summary** (1 page) — for public release.
5. **Fix verification diff review** — auditor reviews the PR that addresses findings; no new findings introduced by fixes.
6. **Disclosure** — coordinated with protocol team; embargo until mainnet deployment or 90 days, whichever is earlier.

---

## 9. Pre-audit preparation checklist (protocol team)

- [x] All 6 packages pass `forge build` with zero warnings.
- [x] All 6 packages pass `forge test` (543/543 tests passing).
- [x] `forge fmt --check` clean.
- [x] Zero `TODO`/`FIXME` without issue links.
- [x] All specs moved to `SC/specs/` (10 design docs).
- [x] `SC/CLAUDE.md` rules enforced.
- [ ] **Frozen commit** — audit starts on a specific git SHA, no changes until audit ends.
- [ ] **Dedicated audit branch** — `audit/v1.0`, protected, no force-push.
- [ ] **Contact channel** — Signal group + shared document for live Q&A.
- [ ] **Bug bounty program** — drafted and ready to activate post-audit (Immunefi recommended).
- [ ] **Deployment scripts** — under review but out of audit scope.
- [ ] **Access control parameters** — multisig threshold, timelock durations, role holders documented in `SC/specs/DEPLOYMENT_PARAMS.md` (to be written).
- [ ] **Emergency response runbook** — drafted.

---

## 10. Engagement structure & timeline

### 10.1 Suggested auditor firms (multi-quote)

Get proposals from at least 3 of:

- **Tier 1:** Trail of Bits, Spearbit, OpenZeppelin, Zellic, ChainSecurity
- **Tier 2:** Cantina, Halborn, Sigma Prime, Consensys Diligence, Quantstamp
- **Contest:** Code4rena, Sherlock, Cantina Competitions — complementary to a private audit, not a replacement

**Evaluation criteria:**
1. Recent portfolio includes EIP-2535 diamond and/or Uniswap v4 hook audits.
2. Team has at least one senior Solidity engineer with >3 years DeFi audit experience.
3. Willingness to use Foundry + Echidna + Halmos (not Hardhat-only).
4. Turnaround ≤ 4 weeks.
5. Fix-verification included in quote.

### 10.2 Timeline (target: 4 weeks)

| Week | Activity |
|---|---|
| 0 | Scope lockdown, commit freeze, context transfer call |
| 1 | Manual review (Track A) + static analysis (Track B) parallel |
| 2 | Fuzzing (Track C) + formal verification (Track D) + preliminary report |
| 3 | Integration/fork testing (Track E) + deep-dive findings review |
| 4 | Draft report + fix review + final report |

### 10.3 Post-audit

1. Fix all Critical and High findings before any deployment.
2. Fix Medium unless explicit acknowledged-risk rationale.
3. Re-audit of fixes (scope: diff only) — included in main quote.
4. Public disclosure 30 days after mainnet, via blog post + audit report PDF.
5. Launch bug bounty (Immunefi, tier: Critical = $100k+, scale to TVL).
6. Monitor: [Forta](https://forta.org/) detectors for admin function calls, [Tenderly](https://tenderly.co/) alerts, on-chain invariant watchers.

---

## 11. Out-of-scope items (documented explicitly)

The auditor may flag these but is not required to deliver findings on:

1. **Phase 5 real v4-core integration** — currently stubbed via `IntegrationPoolManager` / `IntegrationQuoter` due to pragma incompatibility (v4-core 0.8.26 vs diamond 0.8.30). Scheduled post-audit.
2. **Deployment scripts** — not yet written; deployment-time parameters documented separately.
3. **Off-chain infrastructure** — frontend, backend, keepers, indexer (separate `BE/` package, not in this audit).
4. **Uniswap v4-core itself** — audited by multiple firms, out of scope.
5. **OpenZeppelin Contracts** — upstream dependency, out of scope.
6. **Chainlink aggregator contracts** — upstream, out of scope; only the adapter is in scope.
7. **Permit2** — canonical Uniswap deployment, out of scope; only integration is in scope.
8. **USDC** — Circle deployment, out of scope; 6-decimal no-fee assumption documented.
9. **Multi-sig wallet itself** (Safe / Gnosis) — out of scope; threshold and signers are operational.
10. **MEV attacks at the mempool level** — mitigation is slippage parameter; no private mempool integration.
11. **Front-end signature phishing** — user education responsibility.

---

## 12. Known issues & prior findings (full disclosure)

The auditor must be informed of every known issue the team has already identified and either fixed, accepted, or deferred. Full list in `SC/specs/` and prior audit report `PREDIX_AUDIT_REPORT_v2.md` from the legacy V1 codebase. Highlights:

- **17 audit findings** (C-01 through L-07) from V1 audit — all addressed in V2, verification required.
- **H-03 (V4Quoter revert-and-decode)** — fixed per v4-periphery upstream; empirical verification deferred to Phase 5 integration.
- **M-02 (multi-EOA anti-sandwich)** — mitigation is slippage parameter; documented limitation.
- **Exchange gas budget** — 10-fill taker path is 1.68M gas vs 1.2M initial target; accepted, documented in `SC/specs/exchange/EXCHANGE_REFACTOR_SPEC.md`.
- **Hook permissionless `registerMarketPool`** — round 3 patch; currency validation is the sole guard.
- **Last-admin lockout protection** — added via `memberCount`, verification required.

---

## 13. Post-audit monitoring & runbook (forward-looking)

Not in the auditor's scope but listed so the audit acknowledges the operational story:

- **Invariant monitor** — off-chain daemon that re-asserts INV-1, INV-2, INV-3 every block; pages on drift.
- **Admin action monitor** — Forta detector on every `onlyRole` function call.
- **Oracle deviation monitor** — compare Chainlink aggregator against secondary source (CoinGecko, Binance) with 5% threshold.
- **Pause drill** — quarterly simulation of `PausableFacet.pause` + unpause.
- **Key rotation drill** — annual multisig signer rotation test on testnet.
- **Incident response** — on-call rotation with 1h SLA for Critical detections.

---

## 14. Authoritative references

All listed in `SC/CLAUDE.md` §13 and duplicated here for the auditor's convenience.

**Security:**
- [ConsenSys Smart Contract Best Practices](https://consensys.github.io/smart-contract-best-practices/)
- [Trail of Bits — Building Secure Contracts](https://github.com/crytic/building-secure-contracts)
- [SCSVS — Smart Contract Security Verification Standard](https://github.com/ComposableSecurity/SCSVS)
- [SWC Registry](https://swcregistry.io/)
- [Secureum mind map](https://github.com/x676f64/secureum-mind_map)
- [samczsun blog](https://samczsun.com/)
- [Rekt.news](https://rekt.news/)
- [Immunefi disclosures](https://immunefi.com/explore/)
- [DeFiLlama hacks](https://defillama.com/hacks)

**Tooling:**
- [Slither](https://github.com/crytic/slither)
- [Echidna](https://github.com/crytic/echidna)
- [Medusa](https://github.com/crytic/medusa)
- [Halmos](https://github.com/a16z/halmos)
- [Certora Prover](https://www.certora.com/)
- [Foundry Book](https://book.getfoundry.sh/)
- [Aderyn](https://github.com/Cyfrin/aderyn)
- [4naly3er](https://github.com/Picodes/4naly3er)

**Standards:**
- [EIP-2535 Diamond](https://eips.ethereum.org/EIPS/eip-2535)
- [EIP-1153 Transient storage](https://eips.ethereum.org/EIPS/eip-1153)
- [EIP-1967 Proxy storage slots](https://eips.ethereum.org/EIPS/eip-1967)
- [EIP-2612 Permit](https://eips.ethereum.org/EIPS/eip-2612)
- [Permit2](https://github.com/Uniswap/permit2)

**Uniswap v4:**
- [v4-core](https://github.com/Uniswap/v4-core)
- [v4-periphery](https://github.com/Uniswap/v4-periphery)
- [OpenZeppelin uniswap-hooks](https://github.com/OpenZeppelin/uniswap-hooks)

**Prior art (prediction markets):**
- [Polymarket CTF Exchange](https://github.com/Polymarket/ctf-exchange) — complement pair reference
- [Gnosis Conditional Tokens Framework](https://github.com/gnosis/conditional-tokens-contracts) — canonical CTF

---

## 15. Sign-off

This document is the complete audit brief. Any deviation, addition, or scope change requires written approval from the protocol team lead and must be appended below.

**Changelog:**
- v1.0 (2026-04-14) — Initial draft for external auditor engagement.

**Protocol team contact:** (to be filled)
**Auditor contact:** (to be filled)
**Engagement start:** (to be filled)
**Frozen commit SHA:** (to be filled at audit start)
