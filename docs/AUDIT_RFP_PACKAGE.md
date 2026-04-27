# PrediX V2 — External Audit RFP Package

**Date**: 2026-04-27
**Protocol**: PrediX V2 — binary prediction market (Uniswap v4 hook + Diamond proxy + on-chain CLOB)
**Chain**: Unichain (OP Stack L2), live on Sepolia testnet since 2026-04-17
**Codebase**: `upgrade_v2` branch @ commit `102cfc0`
**Repo**: `github.com/PrediX-Protocol/predix-contracts` (private — access granted upon engagement)

---

## 1. What PrediX does (1 paragraph)

Users deposit USDC, receive a pair of YES/NO ERC-20 outcome tokens that redeem 1:1 when a market resolves, and trade those tokens on a hybrid CLOB + AMM aggregator routed in a single transaction. The AMM is a Uniswap v4 pool controlled by a custom hook with time-decaying dynamic fees and EIP-1153 anti-sandwich protection. The CLOB is an on-chain limit order book with 4-way waterfall matching (direct + synthetic mint/merge). Resolution comes from pluggable oracle adapters (manual reporter + Chainlink with round-pinned, sequencer-aware resolution).

## 2. Codebase scope

| Package | LOC | Role | Key contracts |
|---|---|---|---|
| **diamond** | ~2,000 | EIP-2535 proxy; market lifecycle (create/split/merge/resolve/redeem/refund/sweep); events; access control; pause | `MarketFacet`, `EventFacet`, `AccessControlFacet`, `PausableFacet`, `DiamondCutFacet`, `Diamond` |
| **hook** | ~1,600 | Uniswap v4 hook + ERC-1967 proxy; pool-to-market binding; dynamic fee; anti-sandwich; 6 timelocked governance flows | `PrediXHookV2`, `PrediXHookProxyV2` |
| **exchange** | ~1,750 | On-chain CLOB; 4-side limit order book; 4-way waterfall matching (complementary + synthetic mint/merge) | `PrediXExchange`, `MakerPath`, `TakerPath`, `Views`, `MatchMath`, `PriceBitmap` |
| **router** | ~1,250 | Stateless aggregator; CLOB+AMM routing; virtual-NO synthesis; Permit2 | `PrediXRouter` |
| **oracle** | ~360 | Manual reporter + Chainlink (phase-aware round selection, L2 sequencer uptime) | `ManualOracle`, `ChainlinkOracle` |
| **paymaster** | ~130 | ERC-4337 verifying paymaster | `PrediXPaymaster` |
| **shared** | ~700 | Cross-package interfaces, `OutcomeToken` (ERC-20 + EIP-2612), `TransientReentrancyGuard`, `Roles`, `Modules` | — |
| **Total** | **~8,700** | | |

Solidity 0.8.30, EVM Cancun, `via_ir = true`, optimizer 200 runs.

## 3. Architecture diagram

```
                    ┌──────────────┐
                    │   Frontend   │
                    └──────┬───────┘
                           │ Permit2 / direct
                    ┌──────▼───────┐
                    │ PrediXRouter  │  (stateless aggregator)
                    └──┬───────┬───┘
            CLOB leg   │       │   AMM leg
                ┌──────▼──┐ ┌──▼──────────┐
                │ Exchange │ │ PoolManager │
                │  (CLOB)  │ │  (Uni v4)   │
                └──────┬───┘ └──┬──────────┘
                       │        │ hook callbacks
                ┌──────▼────────▼──┐
                │  PrediXHookV2    │  (via ERC-1967 proxy)
                │  dynamic fee     │
                │  anti-sandwich   │
                │  lifecycle gates │
                └──────────┬───────┘
                           │ getMarket()
                    ┌──────▼───────┐
                    │   Diamond    │  (EIP-2535)
                    │  MarketFacet │
                    │  EventFacet  │
                    │  AccessCtrl  │
                    └──────┬───────┘
                           │ isResolved() / outcome()
                    ┌──────▼───────┐
                    │   Oracles    │
                    │  Manual /    │
                    │  Chainlink   │
                    └──────────────┘
```

## 4. Trust assumptions

| Actor | Trust level | Powers |
|---|---|---|
| **DEFAULT_ADMIN_ROLE** | Fully trusted (multisig planned) | Grant/revoke all roles except CUT_EXECUTOR |
| **ADMIN_ROLE** | Fully trusted | Fees, oracle whitelist, per-market caps, refund mode, fee recipient |
| **OPERATOR_ROLE** | Trusted | Emergency resolve (7-day delay), event resolution (pick winner) |
| **PAUSER_ROLE** | Trusted | Pause modules. Cannot block redeem/refund (bypass by design) |
| **CUT_EXECUTOR_ROLE** | Self-administered (Timelock) | Diamond facet mutations. 48h mandatory delay. |
| **CREATOR_ROLE** | Limited | Create markets/events only |
| **Hook admin** | Trusted (multisig planned) | Diamond rotation, trusted-router, unregister, pause. All 48h timelocked. |
| **Proxy admin** | Trusted (separate key) | Hook impl upgrade + timelock duration. 48h timelocked. |
| **Oracle reporter** | Trusted per-deployment | Report outcomes. Admin can revoke. |
| **Users** | Untrusted | Trade, split, merge, redeem, refund |

## 5. Key invariants

| ID | Invariant | Where tested |
|---|---|---|
| INV-1 | `YES.totalSupply == NO.totalSupply == market.totalCollateral` (unresolved) | `invariant_supplyEqualsCollateral` (256 runs × 128k calls) |
| INV-2 | `Exchange.USDC.balance >= Σ active depositLocked` | `invariant_solvency_usdc` |
| INV-3 | `Router.balance(USDC, YES, NO) == 0` post-call | `invariant_RouterUsdcBalanceIsZero` + YES + NO variants |
| INV-4 | `fee + payout == winningBurned` (exact integer) | `testFuzz_FeeMath_PayoutPlusFeeEqualsBurned` |
| INV-5 | Every swap carries a router-committed identity (anti-sandwich) | `FinalH06_ResolveIdentityHardGate` |
| INV-6 | Per-market fee override ≤ snapshotted default (no retroactive hike) | `Audit_L04_PerMarketFeeMidFlight` |

## 6. Areas requesting special attention

1. **Exchange CLOB matching engine** (MakerPath + TakerPath) — most complex code; 4-way waterfall with synthetic mint/merge via diamond.
2. **Hook anti-sandwich identity commit** — EIP-1153 transient storage; trusted-router model; quoter cross-slot write.
3. **Virtual-NO synthesis in Router** — flash-sell YES, split, settle. 2-pass quote with safety margin.
4. **Governance timelocks** — 6 propose/execute/cancel flows across hook + proxy. Uniformly 48h. AlreadyPending guard on all.
5. **Diamond storage layout** — 8 namespaced slots. Append-only. ERC-1967 proxy slots on hook.
6. **Oracle round selection** (ChainlinkOracle) — phase-aware, adjacent-round, sequencer uptime.
7. **Access control completeness** — every admin function gated; CUT_EXECUTOR self-administered; last-holder guard.

## 7. Known issues (documented, accepted)

| Item | Status | Rationale |
|---|---|---|
| `emergencyResolve` empty catch block (no event) | Accepted Info | Intentional — oracle unreachable bypass. Recommend adding event for monitoring. |
| Hook `_lastSwap` mapping unbounded growth | Accepted Info | Cost borne by swapper. Bloom filter replacement is post-launch optimization. |
| `executeTrustedRouter` permissionless (vs other executes are admin-gated) | Accepted Info | Standard timelock pattern. Inconsistency documented. |
| OPERATOR picks arbitrary `winningIndex` for events | Accepted design | Centralization by design pre-DAO. |
| Exchange `feeRecipient` immutable | Accepted Low | Requires Exchange redeploy to change. Documented. |

## 8. Internal audit history

| Pass | Date | Findings | Fixed |
|---|---|---|---|
| Phase 1 remediation | 2026-04-15..21 | ~40 findings | All fixed |
| Bundle A | 2026-04-24 | 11 code items + 1 spec | All fixed |
| Audit-fix pass (H-01/H-02/M-01/M-02/L-04) | 2026-04-25 | 5 findings | All fixed |
| Professional audit Pass 1 | 2026-04-25 | 0C/0H/0M/6L | All fixed |
| Professional audit Pass 2 + V3 cross-check | 2026-04-25..27 | 0C/0H/3M/9L | All fixed |
| **Total fixed** | | | **25+ security findings** |
| **Open findings** | | | **0** |

## 9. Test suite

- **799 tests** across 7 packages (unit + fuzz + invariant + integration + e2e)
- **16 invariant functions** with 256 runs × 128k calls per campaign
- **37 audit-repro test files** — one per historical finding, regression-locked
- **5 fork-test files** (require RPC environment, excluded from default CI)
- CI: `.github/workflows/ci.yml` runs `forge test` + `forge fmt --check` on every push

## 10. Deliverables in this package

| File | Purpose |
|---|---|
| Source code (packages/*/src/) | 8,700 LOC across 7 packages |
| Test suite (packages/*/test/) | 799 tests in 99 files |
| `specs/AUDIT_SPEC.md` | Detailed engagement brief with threat model |
| `SECURITY.md` | Vulnerability disclosure policy |
| `docs/INCIDENT_RESPONSE_PLAN.md` | Formal IR plan |
| `docs/STATIC_ANALYSIS_STATUS.md` | Slither status + alternative coverage |
| `audits/AUDIT_PROFESSIONAL_V2_FULLREPO_20260425.md` | Internal audit Pass 2.1 report |
| `audits/TOB_ASSESSMENT_REPORT_20260427.md` | Trail of Bits framework self-assessment |
| `audits/DIFF_UPGRADE_V2_VS_DEVELOP_20260427.md` | Branch comparison (25 commits, +4200 LOC) |
| `SPEC_VS_CODE_MATRIX.md` | Spec-to-code traceability matrix |
| `SC/CLAUDE.md` | Development rules + security guidelines |

## 11. Engagement logistics

- **Preferred timeline**: 3-4 weeks
- **Preferred format**: Detailed finding report with severity ratings, reproduction steps, and recommended fixes
- **Point of contact**: KT (SP Labs) — [email TBD]
- **Repository access**: Private GitHub repo, read access granted upon engagement
- **Communication**: Weekly sync calls + async on Slack/Telegram
- **Budget**: Negotiable; ballpark $80K-$150K depending on firm and scope

## 12. Questions for the auditor

1. Should we include the deploy scripts (`scripts/`) in scope?
2. Do you want fork-test RPC credentials for Unichain Sepolia integration tests?
3. Do you prefer the codebase as a zip or GitHub repo access?
4. Any preferred format for the threat model beyond `AUDIT_SPEC.md`?
