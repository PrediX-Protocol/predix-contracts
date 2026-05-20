# Deferred Audit Findings — Action Tracker

**Audience:** engineers, security
**Status:** Active
**Last reviewed:** 2026-05-19
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
| M-01 | Medium | Centralization composition across 4 admin multisigs | ops | 2d | High (pre-mainnet ops) | OPEN |
| L-01 | Low | Exchange USDC `forceApprove(diamond, max)` not revoked on upgrade | src | 30m | Medium | OPEN |
| L-02 | Low | Diamond rotation requires per-market `unregisterMarketPool` | src | 2-3h | Medium | OPEN |
| L-03 | Low | Sequencer feed `address(0)` silently bypasses on L2 | doc + deploy check | 30m | High (deploy-blocker) | OPEN |
| L-04 | Low | Redeem with only-losing-tokens burns for zero payout (UX trap) | src | 1h | Medium | OPEN |
| L-05 | Low | Cumulative-merge avoids redemption fee (design choice) | doc only | 15m | Low | OPEN |
| L-06 | Low | `emergencyResolve` lacks bypass-reason event field | src | 1-2h | Medium | OPEN |
| I-01 | Info | `_decimals[marketId]` dead state in ChainlinkOracle | src | 5m | Low | OPEN |
| I-02 | Info | sweep-unclaimed race in final block of GRACE_PERIOD | accept | — | Low | OPEN |
| I-03 | Info | Verify single global reentrancy slot doesn't block legitimate cross-facet entry | test only | 1h | Medium | OPEN |
| I-04 | Info | Per-fill flooring dust to feeRecipient (acceptable) | accept | — | Low | OPEN |
| I-05 | Info | `_lastSwap` mapping unbounded (post-launch bloom filter) | src (post-launch) | 1d | Low (post-launch) | DEFERRED |
| I-06 | Info | DiamondInit slot naming inconsistency | src | 5m | Low | OPEN |
| I-07 | Info | `_INIT_PRICE_MIN/MAX = ±5%` forces launch near 50¢ | design | — | Low | OPEN |
| I-08 | Info | Router `_isBannedRecipient` static list (no update on rotation) | design | — | Low | OPEN |
| I-09 | Info | Permit2 canonical-address check is code-length only | deploy verifier | 30m | High (deploy-blocker) | OPEN |

---

### M-01 — Centralization power composition across admin multisigs

**Status:** OPEN
**Severity:** Medium
**File:** Operational, no source file
**Scope:** Process / documentation

**Context:** PrediX has at least 4 distinct admin trust domains (DEFAULT_ADMIN
on diamond, Hook admin, Hook proxy admin, Exchange proxy admin). The 2024-2025
trend (Ronin/Multichain/Radiant/Bybit class — 80% of crypto loss value) is
off-chain key/social compromise. The codebase has 48h timelocks, but the
ultimate security envelope is defined by those 4 multisig keys.

**Action items:**

- [ ] Document in [`docs/KEY_MANAGEMENT_POLICY.md`](KEY_MANAGEMENT_POLICY.md):
      the 4 keys must be **4 distinct Safe multisigs** with non-overlapping
      signer sets.
- [ ] Operational drill: rehearse 48-hour incident response for each of the
      4 compromise scenarios (admin / hook admin / hook proxy admin /
      exchange proxy admin compromised).
- [ ] After 1 week of clean mainnet operation, raise the upgrade timelock
      floor from 48h to **5-7 days** via the existing
      `proposeTimelockDuration` flow (which already enforces monotonic
      increase — see PrediXHookProxyV2.sol:_MAX_TIMELOCK=30d).
- [ ] Every signer rotation must be a deliberate ceremony, not silent.

**Dependencies:** None.
**Effort:** ~2 days ops setup + ongoing.
**Priority:** **High** — must complete before mainnet deploy.

---

### L-01 — Exchange USDC `forceApprove` not revoked on impl upgrade

**Status:** OPEN
**Severity:** Low
**File:** [`packages/exchange/src/PrediXExchange.sol:90`](../packages/exchange/src/PrediXExchange.sol#L90)

**Context:** Exchange grants the diamond `type(uint256).max` USDC allowance at
init. If the exchange impl is upgraded AND the new impl binds to a different
diamond, the OLD diamond retains unlimited USDC pull rights.

**Recommended fix:**

```solidity
// Add to PrediXExchange.sol
function revokeOldDiamond(address oldDiamond) external onlyAdmin {
    if (oldDiamond == diamond) revert CannotRevokeCurrent();
    IERC20(usdc).forceApprove(oldDiamond, 0);
    emit OldDiamondRevoked(oldDiamond);
}
```

Plus add the call into the impl-upgrade runbook so any upgrade that rebinds
the diamond also revokes the old allowance.

**Test required:** regression test deploying exchange, "upgrading" (simulated
via direct setter or migration impl) to new diamond, asserting old diamond
allowance == 0.

**Effort:** 30 min code + 30 min test.
**Priority:** Medium.

---

### L-02 — Diamond rotation requires per-market `unregisterMarketPool` cleanup

**Status:** OPEN
**Severity:** Low
**File:** [`packages/hook/src/hooks/PrediXHookV2.sol:315-349`](../packages/hook/src/hooks/PrediXHookV2.sol#L315)

**Context:** After `executeDiamondRotation`, each previously-registered pool
must be individually unregistered (48h timelock per market). For 50 markets,
that's 100 admin transactions over 48h+.

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

**Status:** OPEN
**Severity:** Low
**File:** [`packages/oracle/src/adapters/ChainlinkOracle.sol:181-193`](../packages/oracle/src/adapters/ChainlinkOracle.sol#L181)

**Context:** If deployer passes `address(0)` for `sequencerUptimeFeed_` on
an L2 deployment, the entire sequencer-uptime protection is silently skipped.

**Recommended fix (deploy-time, not code):**

- [ ] Add to deploy checklist: assert `ChainlinkOracle.sequencerUptimeFeed != address(0)`
      post-deploy when target chain is L2.
- [ ] Encode the canonical Unichain sequencer feed (when published by
      Chainlink) as a deploy-script required arg.
- [ ] (Optional) emit `SequencerFeedUnconfigured(address)` event from the
      constructor if `feed == address(0)`, for off-chain monitoring.

**Effort:** 30 min (doc + deploy verifier).
**Priority:** **High** — deploy-blocker for L2.

---

### L-04 — Redeem with only-losing-tokens burns for zero payout

**Status:** OPEN
**Severity:** Low
**File:** [`packages/diamond/src/facets/market/MarketFacet.sol:183-227`](../packages/diamond/src/facets/market/MarketFacet.sol#L183)

**Context:** Users with only losing tokens call `redeem()` → tokens burned,
zero USDC payout. Destructive UX trap.

**Recommended fix:**

```solidity
// In MarketFacet.redeem, add after balance reads:
if (winningBurned == 0) revert Market_NothingWorthRedeeming();
```

Frontend should reflect this — disable redeem button when winningBalance == 0.

**Alternative (less invasive):** keep the burn behavior, document in user docs
and SDK that redeem burns ALL outcome tokens regardless of which won.

**Test required:** regression test for the revert path.

**Effort:** 1 hour code + test.
**Priority:** Medium.

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

**Status:** OPEN
**Severity:** Low
**Files:**
- [`packages/diamond/src/facets/market/MarketFacet.sol:147-175`](../packages/diamond/src/facets/market/MarketFacet.sol#L147)
- [`packages/diamond/src/facets/event/EventFacet.sol:117-141`](../packages/diamond/src/facets/event/EventFacet.sol#L117)

**Context:** Monitoring (Forta/Defender) cannot distinguish legitimate
oracle-stall emergency-resolves from suspicious-bypass emergency-resolves.

**Recommended fix:**

```solidity
// Add to IMarketFacet
enum EmergencyBypassReason { OracleUnreachable, OracleRevoked, NotApprovedOracle }
event MarketEmergencyResolved(
    uint256 indexed marketId,
    bool outcome,
    address indexed by,
    EmergencyBypassReason reason  // NEW
);

// In MarketFacet.emergencyResolve:
EmergencyBypassReason reason;
if (LibConfigStorage.layout().approvedOracles[m.oracle]) {
    try IOracle(m.oracle).isResolved(marketId) returns (bool ok) {
        if (ok) revert Market_OracleResolvedUseResolve();
        // approved + not ready → unreachable
        reason = EmergencyBypassReason.OracleUnreachable;
    } catch {
        reason = EmergencyBypassReason.OracleUnreachable;
    }
} else {
    reason = EmergencyBypassReason.OracleRevoked;  // or NotApprovedOracle
}

emit MarketEmergencyResolved(marketId, outcome, msg.sender, reason);
```

Same pattern for `EventFacet.emergencyResolveEvent`.

**Note:** Event signature change — verify off-chain indexers updated.

**Effort:** 1-2 hours code + test.
**Priority:** Medium (improves operational visibility).

---

### Informational items (I-01..I-09)

#### I-01 — Dead state variable `_decimals` in ChainlinkOracle

**Status:** OPEN — quick win
**File:** [`packages/oracle/src/adapters/ChainlinkOracle.sol:104`](../packages/oracle/src/adapters/ChainlinkOracle.sol#L104)

**Fix:** remove `mapping(uint256 marketId => uint8) internal _decimals;` and
the `_decimals[marketId] = dec;` line in `register()`.

**Effort:** 5 min.

#### I-02 — Sweep-unclaimed race in final block of GRACE_PERIOD

**Status:** OPEN
**Recommended action:** ACCEPT (race window 1 block, no funds at risk).
Document the trade-off.

#### I-03 — Verify single global reentrancy slot doesn't block legitimate cross-facet entry

**Status:** OPEN
**File:** [`packages/shared/src/utils/TransientReentrancyGuard.sol`](../packages/shared/src/utils/TransientReentrancyGuard.sol)

**Recommended action:** Write a fuzz test that exhaustively calls every
external entry point inside every other `nonReentrant` external entry to
verify there is no legitimate cross-facet code path that gets accidentally
blocked.

**Effort:** 1 hour test only.

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

**Status:** OPEN
**File:** [`packages/router/src/PrediXRouter.sol:189`](../packages/router/src/PrediXRouter.sol#L189)

**Recommended fix (deploy-time):**

- [ ] Deploy verifier script asserts `router.permit2() == CANONICAL_PERMIT2`
      after deploy.
- [ ] OR: change constructor to `require(address(_permit2) == CANONICAL_PERMIT2, ...)`
      — but this would break test fixtures that deploy fresh Permit2.

Recommend deploy-verifier approach (less invasive).

**Effort:** 30 min deploy script.
**Priority:** **High** — deploy-blocker.

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

**Goal:** Items that must be resolved before mainnet deploy. ~3 days.

- [ ] **M-01**: 4 distinct multisigs deployed + signer ceremony + IR drill rehearsed
- [ ] **L-03**: Sequencer feed check in deploy verifier
- [ ] **I-09**: Permit2 canonical-address assertion in deploy verifier
- [ ] **L-01**: Add `revokeOldDiamond` admin function (defense-in-depth for future upgrade)

### Sprint 1 — First week post-mainnet (quick wins)

**Goal:** Code quality and monitoring improvements. ~2 days.

- [ ] **L-06**: Emergency bypass-reason event field (improves monitoring)
- [ ] **L-04**: Early-revert `Market_NothingWorthRedeeming` (UX safety)
- [ ] **I-01**: Remove `_decimals` dead state
- [ ] **L-05**: Documentation update (cumulative-merge fee semantics)
- [ ] **I-03**: Cross-facet reentrancy fuzz test
- [ ] **M-01 follow-up**: Raise upgrade timelock 48h → 5-7d after clean week

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
