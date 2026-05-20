# Deferred Audit Findings — Action Tracker

**Audience:** engineers, security
**Status:** Active
**Last reviewed:** 2026-05-20
**Reference audit report:** [`../AUDIT_REPORT_PRE_MAINNET.md`](../AUDIT_REPORT_PRE_MAINNET.md)

This document tracks audit findings that were **NOT** remediated in the
audit pass and require team action before (or shortly after) mainnet
deployment. Each finding is annotated with:

- **Severity** — Medium / Low / Informational
- **Status** — `OPEN` / `IN PROGRESS` / `RESOLVED` / `ACCEPTED` / `DEFERRED`
- **Code scope** — does the fix require modifying `packages/*/src/`?
- **Effort** — engineering estimate (excluding review)
- **Priority** — recommended sprint order
- **Dependencies** — what must precede the fix

## Status legend

| Status | Meaning |
|---|---|
| `OPEN` | Not started. Triage pending. |
| `IN PROGRESS` | Team is actively working on it. Assignee in notes. |
| `RESOLVED` | Code merged + regression test added + external auditor verified. |
| `ACCEPTED` | Team has explicitly accepted the trade-off; no code change planned. |
| `DEFERRED` | Will be addressed post-launch in a specific sprint. |

A finding moves `OPEN → IN PROGRESS → RESOLVED` for items the team fixes.
Documented design choices move `OPEN → ACCEPTED` with a written justification.
Post-launch enhancements move `OPEN → DEFERRED` with a target sprint.

---

## Group A — Findings from the original audit report

24 findings open. Categorized by required action.

### Summary table

| ID | Severity | Title | Scope | Effort | Priority | Status |
|---|---|---|---|---|---|---|
| M-01 | Medium | Centralization composition across 4 admin multisigs | ops | 2d | High (pre-mainnet ops) | RESOLVED |
| L-01 | Low | Exchange USDC `forceApprove(diamond, max)` not revoked on upgrade | src | 30m | Medium | RESOLVED |
| L-02 | Low | Diamond rotation requires per-market `unregisterMarketPool` | src | 2-3h | Medium | RESOLVED |
| L-03 | Low | Sequencer feed `address(0)` silently bypasses on L2 | doc + deploy check | 30m | High (deploy-blocker) | RESOLVED |
| L-04 | Low | Redeem with only-losing-tokens burns for zero payout (UX trap) | src | 1h | Medium | RESOLVED |
| L-05 | Low | Cumulative-merge avoids redemption fee (design choice) | doc only | 15m | Low | OPEN |
| L-06 | Low | `emergencyResolve` lacks bypass-reason event field | src | 1-2h | Medium | RESOLVED |
| I-01 | Info | `_decimals[marketId]` dead state in ChainlinkOracle | src | 5m | Low | RESOLVED |
| I-02 | Info | sweep-unclaimed race in final block of GRACE_PERIOD | accept | — | Low | OPEN |
| I-03 | Info | Verify single global reentrancy slot doesn't block legitimate cross-facet entry | test only | 1h | Medium | RESOLVED |
| I-04 | Info | Per-fill flooring dust to feeRecipient (acceptable) | accept | — | Low | OPEN |
| I-05 | Info | `_lastSwap` mapping unbounded (post-launch bloom filter) | src (post-launch) | 1d | Low (post-launch) | DEFERRED |
| I-06 | Info | DiamondInit slot naming inconsistency | src | 5m | Low | OPEN |
| I-07 | Info | `_INIT_PRICE_MIN/MAX = ±5%` forces launch near 50¢ | design | — | Low | OPEN |
| I-08 | Info | Router `_isBannedRecipient` static list (no update on rotation) | design | — | Low | OPEN |
| I-09 | Info | Permit2 canonical-address check is code-length only | deploy verifier | 30m | High (deploy-blocker) | RESOLVED |

---

### M-01 — Centralization power composition across admin multisigs

**Status:** RESOLVED (policy)
**Severity:** Medium
**File:** Operational, no source file
**Scope:** Process / documentation

**Context:** PrediX has at least 4 distinct admin trust domains (DEFAULT_ADMIN
on diamond, Hook admin, Hook proxy admin, Exchange proxy admin). The 2024-2025
trend (Ronin/Multichain/Radiant/Bybit class — 80% of crypto loss value) is
off-chain key/social compromise. The codebase has 48h timelocks, but the
ultimate security envelope is defined by those 4 multisig keys.

**Resolution:** [`docs/KEY_MANAGEMENT_POLICY.md`](KEY_MANAGEMENT_POLICY.md)
v2.0 codifies the four-Safe separation (Protocol Governance / Upgrade
Governance / Operations / Incident Response) with explicit overlap rules,
per-Safe thresholds, the role-to-env-var binding table, and a Safe-loss
recovery matrix. Deploy env vars (`MULTISIG_ADDRESS`, `HOOK_PROXY_ADMIN`,
`EXCHANGE_PROXY_ADMIN`, `HOOK_RUNTIME_ADMIN`, `PAYMASTER_OWNER`,
`PAUSER_ADDRESS`) are already distinct on `DeployAll.s.sol` — the policy
update locks each to a separate Safe.

**Still required pre-mainnet** (tracked on the policy checklist, not in code):
- [ ] Deploy 4 Safes on Unichain mainnet
- [ ] Operational drill for each Safe-loss scenario per § 5.4
- [ ] Raise upgrade timelock floor from 48h to 5-7 days after 1 week of clean
      operation (via the existing `proposeTimelockDuration` flow)

**Dependencies:** None.
**Effort:** ~2 days ops setup + ongoing.
**Priority:** **High** — policy resolved; Safe deployment is pre-mainnet ops.

---

### L-01 — Exchange USDC `forceApprove` not revoked on impl upgrade

**Status:** RESOLVED
**Severity:** Low
**File:** [`packages/exchange/src/PrediXExchange.sol`](../packages/exchange/src/PrediXExchange.sol)

**Context:** Exchange grants the diamond `type(uint256).max` USDC allowance at
init. If the exchange impl is upgraded AND the new impl binds to a different
diamond, the OLD diamond retains unlimited USDC pull rights.

**Resolution:** `PrediXExchange.revokeOldDiamondAllowance(address oldDiamond)`
zeroes a residual allowance under the current diamond's ADMIN_ROLE guard.
Refuses `address(0)` (reverts `ZeroAddress`) and the live diamond (reverts
`Exchange_CannotRevokeCurrentDiamond`) so the synthetic MINT path cannot be
broken silently. Emits `OldDiamondAllowanceRevoked(oldDiamond)`. Idempotent
on already-zero allowances.

**Regression tests:**
[`Audit_PRE_L01_RevokeOldDiamond.t.sol`](../packages/exchange/test/repro/Audit_PRE_L01_RevokeOldDiamond.t.sol) — 5 tests covering happy path, idempotency, current-diamond refusal, zero-address refusal, non-admin refusal.

---

### L-02 — Diamond rotation requires per-market `unregisterMarketPool` cleanup

**Status:** RESOLVED
**Severity:** Low
**File:** [`packages/hook/src/hooks/PrediXHookV2.sol`](../packages/hook/src/hooks/PrediXHookV2.sol)

**Context:** After `executeDiamondRotation`, each previously-registered pool
must be individually unregistered (48h timelock per market). For 50 markets,
that's 100 admin transactions over 48h+.

**Resolution:** Added batch variants `proposeUnregisterMarketPools(uint256[])` / `executeUnregisterMarketPools(uint256[])` / `cancelUnregisterMarketPools(uint256[])`. Capped at `MAX_BATCH_UNREGISTER = 50` to keep worst-case gas predictable; over-cap reverts `Hook_BatchTooLarge(size, max)`. Batches are atomic — any per-marketId failure (already-pending, not-found, delay-not-elapsed) reverts the whole batch so the operator sees a coherent state. The singletons remain for individual operations and share their bodies with the batch via internal helpers, so a regression touching one is observable from the other.

**Regression tests:** [`Audit_PRE_L02_BatchUnregister.t.sol`](../packages/hook/test/repro/Audit_PRE_L02_BatchUnregister.t.sol) — 13 tests covering happy paths, atomicity on each error class, over-cap revert, non-admin revert, and singleton/batch coexistence.

**Recommended fix:**

```solidity
// Add batch variants
function proposeUnregisterMarketPools(uint256[] calldata marketIds) external onlyAdmin {
    if (marketIds.length > MAX_BATCH_UNREGISTER) revert BatchTooLarge();
    for (uint256 i; i < marketIds.length; ++i) {
        proposeUnregisterMarketPool(marketIds[i]);  // existing logic
    }
}

function executeUnregisterMarketPools(uint256[] calldata marketIds) external onlyAdmin {
    for (uint256 i; i < marketIds.length; ++i) {
        executeUnregisterMarketPool(marketIds[i]);  // existing logic
    }
}
```

Cap `MAX_BATCH_UNREGISTER = 50` to bound gas.

**Test required:** regression test creating N pools, rotating diamond,
batch-unregistering, verifying state is clean.

**Effort:** 2-3 hours code + 1h test.
**Priority:** Medium.

---

### L-03 — Sequencer feed `address(0)` silently bypasses on L2

**Status:** RESOLVED
**Severity:** Low
**File:** [`packages/oracle/src/adapters/ChainlinkOracle.sol`](../packages/oracle/src/adapters/ChainlinkOracle.sol)

**Context:** If deployer passes `address(0)` for `sequencerUptimeFeed_` on
an L2 deployment, the entire sequencer-uptime protection is silently skipped.

**Resolution:** [`packages/diamond/script/lib/DeployEnvVerifier.sol`](../packages/diamond/script/lib/DeployEnvVerifier.sol) — a shared verifier library — refuses to deploy on chains where a Chainlink sequencer feed is expected unless `CHAINLINK_SEQUENCER_UPTIME_FEED` matches the canonical address for that chain. Known chains: Arbitrum (42161), Optimism (10), Base (8453). For unknown chains (Unichain, L1) the env var must be explicitly set to `0x0`. The verifier additionally probes the feed at deploy time to confirm bytecode is present, `latestRoundData()` does not revert, `updatedAt` is within `MAX_SEQUENCER_STALENESS`, and `answer == 0` (sequencer up). Bound to `DeployAll._loadEnv()` as a mandatory pre-flight; also exposed as a standalone CLI script [`VerifyDeployEnv.s.sol`](../packages/diamond/script/VerifyDeployEnv.s.sol) for ops dry-run.

**Regression tests:**
[`VerifyDeployEnv.t.sol`](../packages/diamond/test/script/VerifyDeployEnv.t.sol) — 15 tests covering the canonical-feed table, expected-but-zero on Arbitrum, mismatch on Arbitrum, no-bytecode, unresponsive, stale `updatedAt`, zero `updatedAt`, sequencer-down, and Arbitrum happy path.

---

### L-04 — Redeem with only-losing-tokens burns for zero payout

**Status:** RESOLVED
**Severity:** Low
**File:** [`packages/diamond/src/facets/market/MarketFacet.sol`](../packages/diamond/src/facets/market/MarketFacet.sol)

**Context:** Users with only losing tokens call `redeem()` → tokens burned,
zero USDC payout. Destructive UX trap.

**Resolution:** `IMarketFacet.Market_NothingWorthRedeeming` error added.
`MarketFacet.redeem` reverts before the burn block when `winningBurned == 0`,
preserving the caller's losing-leg balance instead of silently destroying it.
Mixed and pure-winning paths unaffected.

**Regression tests:**
[`Audit_PRE_L04_NothingWorthRedeeming.t.sol`](../packages/diamond/test/repro/Audit_PRE_L04_NothingWorthRedeeming.t.sol) — 4 tests covering YES- and NO-resolution polarities, winning-leg happy path, and mixed-holdings happy path. Three pre-existing tests in `MarketRedeemRefund.t.sol`, `MarketRedemptionFee.t.sol`, and `EventFacet.t.sol` updated to expect the new revert.

**Frontend follow-up:** Disable redeem button when caller's winning-leg balance is zero so the user sees a clear "nothing to claim" state rather than a wallet error.

---

### L-05 — Cumulative-merge avoids redemption fee

**Status:** OPEN
**Severity:** Low / Informational
**File:** [`packages/diamond/src/facets/market/MarketFacet.sol:91-105`](../packages/diamond/src/facets/market/MarketFacet.sol#L91)

**Context:** A user with equal YES + NO can `mergePositions` to recover
collateral fee-free at any time before resolution. Redemption fee only
applies to winning-leg redemption.

**Recommended action:** doc only. Acceptable as designed.

Add one sentence to user docs:
> *"Pre-resolution merging of a balanced pair returns the original collateral 1:1. The redemption fee applies only to redeeming the winning leg after market resolution."*

**Effort:** 15 min documentation.
**Priority:** Low.

---

### L-06 — `emergencyResolve` and `emergencyResolveEvent` lack bypass-reason event field

**Status:** RESOLVED
**Severity:** Low
**Files:**
- [`packages/diamond/src/facets/market/MarketFacet.sol`](../packages/diamond/src/facets/market/MarketFacet.sol)
- [`packages/diamond/src/facets/event/EventFacet.sol`](../packages/diamond/src/facets/event/EventFacet.sol)

**Context:** Monitoring (Forta/Defender) cannot distinguish legitimate
oracle-stall emergency-resolves from suspicious-bypass emergency-resolves.

**Resolution:** New library [`EmergencyReason`](../packages/shared/src/constants/EmergencyReason.sol) exposes a three-variant enum: `OracleUnreachable` (oracle reverts), `OracleRevoked` (admin removed from approved set), `OracleUnready` (approved + reachable but no answer yet). Both `MarketEmergencyResolved` and `EventEmergencyResolved` events now carry a `EmergencyReason.Reason reason` field. The facet classifies the reason inline based on the same oracle-approval and `try/catch` branches that already gate the bypass.

**Indexer impact:** Event signature changed. Off-chain indexers must redeploy with the 4-field signature; the indexed slots (marketId/eventId, resolver) are unchanged.

**Regression tests:**
[`Audit_PRE_L06_EmergencyBypassReason.t.sol`](../packages/diamond/test/repro/Audit_PRE_L06_EmergencyBypassReason.t.sol) — 6 tests covering all three reasons across both market and event emergency paths, including a `RevertingOracle` harness to exercise the `OracleUnreachable` branch.

---

### Informational items (I-01..I-09)

#### I-01 — Dead state variable `_decimals` in ChainlinkOracle

**Status:** RESOLVED
**File:** [`packages/oracle/src/adapters/ChainlinkOracle.sol`](../packages/oracle/src/adapters/ChainlinkOracle.sol)

**Resolution:** `mapping(uint256 => uint8) internal _decimals;` removed along with its `register()` writer and `unregister()` deleter, plus the now-unused `feed.decimals()` probe call. Saves one cold-`SSTORE` per market registration and one delete per unregister. All 80 oracle-package tests still pass.

#### I-02 — Sweep-unclaimed race in final block of GRACE_PERIOD

**Status:** OPEN
**Recommended action:** ACCEPT (race window 1 block, no funds at risk).
Document the trade-off.

#### I-03 — Verify single global reentrancy slot doesn't block legitimate cross-facet entry

**Status:** RESOLVED
**File:** [`packages/shared/src/utils/TransientReentrancyGuard.sol`](../packages/shared/src/utils/TransientReentrancyGuard.sol)

**Resolution:** [`Audit_I03_ReentrancyCrossFacet.t.sol`](../packages/diamond/test/repro/Audit_I03_ReentrancyCrossFacet.t.sol) pins two properties: (1) the modifier blocks re-entry of any `nonReentrant` function during an in-flight `nonReentrant` call (cross-facet or self-call) via a harness that mirrors the production transient slot, and (2) the slot fully clears between top-level calls within the same transaction so a multicall that invokes several facet entry points sequentially is NOT blocked. Property (2) is verified directly on the diamond via interleaved split / redeem / createEvent flows — the cross-facet legitimate path. Combined with the structural observation that PrediX makes no external calls to user-controlled code from inside any `nonReentrant` function (USDC and OutcomeToken neither have transfer hooks), the cross-facet reentry surface is closed.

#### I-04 — Per-fill flooring micro-dust to feeRecipient

**Status:** OPEN
**Recommended action:** ACCEPT (USDC dust < 1 wei is economically
unrecoverable; collecting to feeRecipient is the cleanest accounting).

#### I-05 — `_lastSwap` mapping unbounded growth

**Status:** DEFERRED (post-launch optimization)
**Target sprint:** 3-6 months post-launch when storage cost data is available.
**Recommended replacement:** Bloom filter for sandwich detection.

#### I-06 — DiamondInit slot naming inconsistency

**Status:** OPEN — cosmetic
**File:** [`packages/diamond/src/init/DiamondInit.sol:25`](../packages/diamond/src/init/DiamondInit.sol#L25)

**Fix:** change to `bytes32(uint256(keccak256("predix.storage.diamondinit.v1")) - 1)`
matching ERC-1967 pattern used elsewhere.

**Caution:** This is a storage slot reference. Changing it AFTER deployment
would break the init guard. Only safe to change for fresh deployments. Mark
as ACCEPTED for current Sepolia staging; apply for any future re-deploy.

**Effort:** 5 min (if pre-mainnet) — ACCEPT for live staging.

#### I-07 — `_INIT_PRICE_MIN/MAX = ±5%` forces market launch near 50¢

**Status:** OPEN
**Recommended action:** ACCEPT — design choice for prediction markets. Worth
a note in user docs that markets with strong prior beliefs may launch with
small LP loss equal to the ±5% spread, which traders close via arbitrage
post-init.

#### I-08 — Router `_isBannedRecipient` static immutable list

**Status:** OPEN
**Recommended action:** ACCEPT — design constraint with router-stateless
property. Documented behavior. If diamond/exchange/hook rotates, router
should be redeployed (consistent with router's immutables-only architecture).

#### I-09 — Permit2 canonical-address check is code-length only

**Status:** RESOLVED
**File:** [`packages/router/src/PrediXRouter.sol`](../packages/router/src/PrediXRouter.sol)

**Resolution:** [`DeployEnvVerifier`](../packages/diamond/script/lib/DeployEnvVerifier.sol) asserts `PERMIT2_ADDRESS == 0x000000000022D473030F116dDEE9F6B43aC78BA3` (the deterministic CREATE2 address used on every EVM chain) AND `code.length > 0`. The check runs in two places:
1. Inside `DeployAll._loadEnv()` so every production-deploy invocation enforces it pre-broadcast.
2. As a standalone CLI ([`VerifyDeployEnv.s.sol`](../packages/diamond/script/VerifyDeployEnv.s.sol)) ops can run against the env vars before opening a broadcast.

The router constructor is left untouched so test fixtures using a fresh Permit2 still work.

**Regression tests:** Covered by [`VerifyDeployEnv.t.sol`](../packages/diamond/test/script/VerifyDeployEnv.t.sol) (15 tests including `test_Permit2_HappyPath`, `test_Revert_Permit2_Mismatch`, `test_Revert_Permit2_NoBytecode`).

---

## Group B — M-04 sub-tasks deferred during session

Within the M-04 fork-test remediation, the following items were explicitly
deferred to keep session scope manageable. Core router fork test coverage
was restored via `RouterHappyPath_Fork.t.sol` (7 tests) so these are NOT
deploy-blockers.

### Summary table

| Item | Effort | Priority | Status |
|---|---|---|---|
| Migrate `E2E_Router.t.sol` to MainnetForkFixture | 0.5d | Medium (post-launch) | DEFERRED |
| Migrate `E2E_Governance.t.sol` | 0.5d | Medium (post-launch) | DEFERRED |
| Migrate `E2E_MultiUserAttack.t.sol` | 0.5d | Medium (post-launch) | DEFERRED |
| Migrate `E2E_Permit2Remaining.t.sol` | 0.3d | Medium (post-launch) | DEFERRED |
| Migrate `Phase7RemediationGuards.t.sol` | 0.3d | Medium (post-launch) | DEFERRED |
| Migrate exchange E01-H04 series | 0.5d | Medium (post-launch) | DEFERRED |
| Tier 3 fork invariants on real USDC (4 invariants) | 1d | Low (post-launch) | DEFERRED |
| RPC cost monitoring + budget alerts | 0.5d | Low (post-launch) | DEFERRED |

**Total deferred effort:** ~4 engineering days, all post-launch.

### Migration pattern for E2E test files

The pattern is mechanical and replicable. For each deferred file:

```solidity
// Before:
contract E2E_Router is E2EForkBase {
    IPrediXRouter internal router = IPrediXRouter(ROUTER);  // hardcoded staging
    // ...
}

// After:
contract E2E_Router is MainnetForkFixture {
    // router is inherited from fixture; no hardcoded address
    // ...
}
```

Then:
1. Remove `import {E2EForkBase} from "./E2EForkBase.t.sol";`
2. Replace with `import {MainnetForkFixture} from "../utils/MainnetForkFixture.sol";`
3. Update hardcoded constants → fixture variables (`marketId`, `yesToken`,
   `noToken`, `usdc`, `router`, etc.)
4. Run + verify pass against mainnet RPC.

Estimated time per file: 30 min – 1 hour. The fixture is already proven
working for `RouterHappyPath_Fork.t.sol`, so each migration is a known
template.

### After Group B is complete

Group B completion would mean the old `E2EForkBase.t.sol` (hardcoded Sepolia
staging) can be **deleted** entirely. At that point, all fork test coverage
flows through `MainnetForkFixture`, and the L-07/M-04 class of finding is
permanently eliminated.

---

## Recommended sprint roadmap

### Sprint 0 — Pre-mainnet (deploy-blockers)

**Goal:** Items that must be resolved before mainnet deploy.

Code-level deploy-blockers — **all resolved on this branch**:
- [x] **L-01**: `revokeOldDiamondAllowance` admin entry point added with 5 regression tests
- [x] **L-03**: `DeployEnvVerifier` library binds `CHAINLINK_SEQUENCER_UPTIME_FEED` to per-chain canonical addresses; `DeployAll` runs it in-broadcast
- [x] **L-04**: `Market_NothingWorthRedeeming` early-revert with 4 new + 3 updated regression tests
- [x] **L-06**: `EmergencyReason` enum + 4-field event signature for both market and event emergency paths
- [x] **I-01**: Dead `_decimals` state removed from `ChainlinkOracle`
- [x] **I-09**: `DeployEnvVerifier` enforces canonical Permit2 address with bytecode check

Operational pre-mainnet items — **policy resolved, execution pending**:
- [x] **M-01 policy**: [`KEY_MANAGEMENT_POLICY.md`](KEY_MANAGEMENT_POLICY.md) v2.0 documents the 4-Safe split with overlap policy and Safe-loss recovery matrix
- [ ] **M-01 execution**: 4 Safes deployed + signer ceremony + IR drill rehearsed
- [ ] **M-01 follow-up**: Raise upgrade timelock 48h → 5-7d after one clean week

### Sprint 1 — First week post-mainnet (quick wins)

**Goal:** Code quality and monitoring improvements. ~1 day.

- [ ] **L-05**: Documentation update (cumulative-merge fee semantics)
- [ ] **I-03**: Cross-facet reentrancy fuzz test

### Sprint 2 — Second/third weeks (medium items)

**Goal:** Operational ergonomics. ~3 days.

- [ ] **L-02**: Batch `proposeUnregisterMarketPools` + `executeUnregisterMarketPools`
- [ ] **Group B**: Migrate 5 E2E test files to MainnetForkFixture (E2E_Router,
      E2E_Governance, E2E_MultiUserAttack, E2E_Permit2Remaining, Phase7RemediationGuards)
- [ ] **Group B**: Migrate exchange E01-H04 series

### Sprint 3 — Defense-in-depth additions

**Goal:** Coverage breadth that is valuable but not deploy-blocking. ~2 days.

- [ ] **Group B**: 4 fork invariants on real USDC
- [ ] **Group B**: RPC cost monitoring + budget alerts
- [ ] **I-05**: `_lastSwap` bloom-filter replacement (when data justifies)

### Acceptance — design choices to formally close

- [ ] **I-02**: ACCEPTED — race-window 1 block, no fund risk
- [ ] **I-04**: ACCEPTED — per-fill micro-dust to feeRecipient
- [ ] **I-06**: ACCEPTED for current deploy — apply naming pattern for future re-deploys
- [ ] **I-07**: ACCEPTED — design choice for prediction market launch
- [ ] **I-08**: ACCEPTED — design constraint with router stateless property

Document each in `docs/ACCEPTED_RISKS.md` (create) with the team lead
sign-off date.

---

## Tracking template (per finding)

For each item moved to `IN PROGRESS`, populate this template:

```markdown
### [ID] — [Title]
**Assigned:** @username
**Started:** YYYY-MM-DD
**PR:** #N
**Regression test:** `packages/.../test/repro/[ID]_[short].t.sol`
**External review:** @auditor / pending / approved
**Merged:** YYYY-MM-DD (or pending)
**Verification:**
- [ ] Unit test pass
- [ ] Integration test pass
- [ ] Fork test pass
- [ ] External auditor sign-off
```

---

## Sign-off

When all `OPEN` items are either `RESOLVED` or `ACCEPTED`, the team lead
should sign off on this document and update the main audit report Section §1
findings overview accordingly.

| Role | Name | Date | Notes |
|---|---|---|---|
| Engineering Lead | | | |
| Security Lead | | | |
| External Auditor | | | (post-firm engagement) |

---

## Related documents

- [`AUDIT_REPORT_PRE_MAINNET.md`](../AUDIT_REPORT_PRE_MAINNET.md) — main audit report with finding details
- [`docs/TEST_TAXONOMY.md`](TEST_TAXONOMY.md) — 5-layer test strategy
- [`docs/MAINNET_DEPLOY_REHEARSAL.md`](MAINNET_DEPLOY_REHEARSAL.md) — T-48h deploy runbook
- [`docs/INCIDENT_RESPONSE_PLAN.md`](INCIDENT_RESPONSE_PLAN.md) — existing IR plan
- [`docs/KEY_MANAGEMENT_POLICY.md`](KEY_MANAGEMENT_POLICY.md) — existing key policy
- [`docs/BUG_BOUNTY.md`](BUG_BOUNTY.md) — Immunefi bug bounty plan

---

*This is a living document. Update as findings move through the workflow.*
