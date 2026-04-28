# PrediX V2 — External Audit RFP Package

**Date**: 2026-04-28
**Protocol**: PrediX V2 — binary prediction market (Uniswap v4 hook + Diamond proxy + on-chain CLOB)
**Chain**: Unichain (OP Stack L2), live on Sepolia testnet since 2026-04-17
**Codebase**: `upgrade_v2` branch
**Repo**: `github.com/PrediX-Protocol/predix-contracts` (private — access granted upon engagement)

---

## 1. What PrediX does (1 paragraph)

Users deposit USDC, receive a pair of YES/NO ERC-20 outcome tokens that redeem 1:1 when a market resolves, and trade those tokens on a hybrid CLOB + AMM aggregator routed in a single transaction. The AMM is a Uniswap v4 pool controlled by a custom hook with time-decaying dynamic fees and EIP-1153 anti-sandwich protection. The CLOB is an on-chain limit order book with 4-way waterfall matching (direct + synthetic mint/merge). Resolution comes from pluggable oracle adapters (manual reporter + Chainlink with round-pinned, sequencer-aware resolution).

## 2. Codebase scope

| Package | LOC | Role | Key contracts |
|---|---|---|---|
| **diamond** | ~2,000 | EIP-2535 proxy; market lifecycle (create/split/merge/resolve/redeem/refund/sweep); events; access control; pause | `MarketFacet`, `EventFacet`, `AccessControlFacet`, `PausableFacet`, `DiamondCutFacet`, `Diamond` |
| **hook** | ~1,600 | Uniswap v4 hook + ERC-1967 proxy; pool-to-market binding; dynamic fee; anti-sandwich; 6 timelocked governance flows | `PrediXHookV2`, `PrediXHookProxyV2` |
| **exchange** | ~1,750 | On-chain CLOB + ERC-1967 proxy; 4-side limit order book; 4-way waterfall matching (complementary + synthetic mint/merge) | `PrediXExchange`, `PrediXExchangeProxy`, `MakerPath`, `TakerPath`, `Views`, `MatchMath`, `PriceBitmap` |
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
                    │ PrediXRouter │  (stateless aggregator)
                    └──┬───────┬───┘
            CLOB leg   │       │   AMM leg
                ┌───────▼──┐ ┌──▼──────────┐
                │ Exchange │ │ PoolManager │
                │  (CLOB)  │ │  (Uni v4)   │
                │ ERC-1967 │ └──┬──────────┘
                └──────┬───┘    │ hook callbacks
                       │  ┌─────▼──────────┐
                       │  │ PrediXHookV2   │  (via ERC-1967 proxy)
                       │  │ dynamic fee    │
                       │  │ anti-sandwich  │
                       │  │ lifecycle gates│
                       │  └──────┬─────────┘
                       │         │ getMarket()
                    ┌──▼─────────▼───┐
                    │    Diamond     │  (EIP-2535)
                    │  MarketFacet   │
                    │  EventFacet    │
                    │  AccessCtrl    │
                    └──────┬─────────┘
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
| **Hook proxy admin** | Trusted (separate key) | Hook impl upgrade + timelock duration. 48h timelocked. |
| **Exchange proxy admin** | Trusted (separate key) | Exchange impl upgrade. 48h timelocked. |
| **Oracle reporter** | Trusted per-deployment | Report outcomes. Admin can revoke. |
| **Users** | Untrusted | Trade, split, merge, redeem, refund |

## 5. Key invariants

| ID | Invariant | Where tested |
|---|---|---|
| INV-1 | `YES.totalSupply == NO.totalSupply == market.totalCollateral` (unresolved) | `invariant_supplyEqualsCollateral` (256 runs x 128k calls) |
| INV-2 | `Exchange.USDC.balance >= sum(active depositLocked)` | `invariant_solvency_usdc` |
| INV-3 | `Router.balance(USDC, YES, NO) == 0` post-call | `invariant_RouterUsdcBalanceIsZero` + YES + NO variants |
| INV-4 | `fee + payout == winningBurned` (exact integer) | `testFuzz_FeeMath_PayoutPlusFeeEqualsBurned` |
| INV-5 | Every swap carries a router-committed identity (anti-sandwich) | Identity hard-gate test |
| INV-6 | Per-market fee override <= snapshotted default (no retroactive hike) | Per-market fee mid-flight test |

## 6. Areas requesting special attention

1. **Exchange CLOB matching engine** (MakerPath + TakerPath) — most complex code; 4-way waterfall with synthetic mint/merge via diamond.
2. **Hook anti-sandwich identity commit** — EIP-1153 transient storage; trusted-router model; quoter cross-slot write.
3. **Virtual-NO synthesis in Router** — flash-sell YES, split, settle. 2-pass quote with safety margin.
4. **Governance timelocks** — 6 propose/execute/cancel flows across hook + proxy. Uniformly 48h. AlreadyPending guard on all.
5. **Diamond storage layout** — 8 namespaced slots. Append-only. ERC-1967 proxy slots on hook + exchange.
6. **Oracle round selection** (ChainlinkOracle) — phase-aware, adjacent-round, sequencer uptime.
7. **Access control completeness** — every admin function gated; CUT_EXECUTOR self-administered; last-holder guard.
8. **Exchange proxy upgrade** — ERC-1967 pattern with 48h timelocked upgrade + admin rotation.

## 7. Known issues (documented, accepted)

| Item | Status | Rationale |
|---|---|---|
| `emergencyResolve` empty catch block (no event) | Accepted Info | Intentional — oracle unreachable bypass. Recommend adding event for monitoring. |
| Hook `_lastSwap` mapping unbounded growth | Accepted Info | Cost borne by swapper. Bloom filter replacement is post-launch optimization. |
| `executeTrustedRouter` permissionless (vs other executes are admin-gated) | Accepted Info | Standard timelock pattern. Inconsistency documented. |
| OPERATOR picks arbitrary `winningIndex` for events | Accepted design | Centralization by design pre-DAO. |

## 8. Internal audit history

| Pass | Date | Findings | Fixed |
|---|---|---|---|
| Phase 1 remediation | 2026-04-15..21 | ~40 findings | All fixed |
| Bundle A | 2026-04-24 | 11 code items + 1 spec | All fixed |
| Remediation pass | 2026-04-25 | 5 findings | All fixed |
| Internal audit Pass 1 | 2026-04-25 | 0C/0H/0M/6L | All fixed |
| Internal audit Pass 2 | 2026-04-25..27 | 0C/0H/3M/9L | All fixed |
| Exchange proxy + deploy update | 2026-04-28 | Exchange converted to ERC-1967 proxy pattern | Deployed |
| **Total fixed** | | | **25+ security findings** |
| **Open findings** | | | **0** |

## 9. Test suite

- **815+ tests** across 7 packages (unit + fuzz + invariant + integration + e2e + fork)
- **16 invariant functions** with 256 runs x 128k calls per campaign
- **37 regression test files** — one per historical finding, regression-locked
- **E2E fork tests** against live Unichain Sepolia deployment
- CI: `.github/workflows/ci.yml` runs `forge test` + `forge fmt --check` on every push

## 10. Deliverables in this package

| File | Purpose |
|---|---|
| Source code (`packages/*/src/`) | ~8,700 LOC across 7 packages |
| Test suite (`packages/*/test/`) | 815+ tests |
| `SECURITY.md` | Vulnerability disclosure policy |
| `docs/INCIDENT_RESPONSE_PLAN.md` | Formal IR plan |
| `docs/KEY_MANAGEMENT_POLICY.md` | Key management + multisig policy |
| `docs/STATIC_ANALYSIS_STATUS.md` | Static analysis status + alternative coverage |

## 11. Engagement logistics

- **Preferred timeline**: 3-4 weeks
- **Preferred format**: Detailed finding report with severity ratings, reproduction steps, and recommended fixes
- **Point of contact**: KT (SP Labs) — keyti@predixpro.io
- **Repository access**: Private GitHub repo, read access granted upon engagement
- **Communication**: Weekly sync calls + async on Slack/Telegram
- **Budget**: Negotiable; ballpark $80K-$150K depending on firm and scope

## 12. Questions for the auditor

1. Should we include the deploy scripts (`scripts/`) in scope?
2. Do you want fork-test RPC credentials for Unichain Sepolia integration tests?
3. Do you prefer the codebase as a zip or GitHub repo access?
4. Any preferred format for the threat model beyond what's in the codebase?
