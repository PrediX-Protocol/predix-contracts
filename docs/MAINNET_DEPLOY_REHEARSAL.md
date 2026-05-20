# Mainnet Deploy Rehearsal — T-48h Checklist

**Audience:** operators, security
**Status:** Active
**Last reviewed:** 2026-05-20

This document is the operational runbook for the 48-hour window before
PrediX mainnet deployment. It complements the existing `BUNDLE_C_CHECKLIST.md`
with the test-infrastructure-specific verifications layered on top of the
unit + integration test gates.

> **Why a separate rehearsal?** Code audits validate the contracts. Deploy
> rehearsals validate the operational stack around them — multisigs, RPC
> infrastructure, pin block freshness, monitoring, incident response. The
> Bybit Feb 2025 hack ($1.4B) was an operational compromise of a clean
> codebase. Rehearsal is the layer that catches that class of issue.

---

## T-48h: Pin block freeze

The fork test suite is pinned to a specific Unichain mainnet block for
reproducibility. Stale pin blocks cause silent test rot when external
contracts at those blocks predate canonical deployments. Before mainnet
deploy, the pin block MUST be bumped to a recent block and the full fork
suite must pass against it.

- [ ] Run `scripts/bump-pin-block.sh`
- [ ] Verify the pin block is **post-canonical-deploy** of v4 PoolManager,
      V4Quoter, real USDC, and Permit2 on Unichain mainnet.
      ```
      cast code $POOL_MANAGER_ADDRESS --rpc-url $UNICHAIN_RPC_PRIMARY --block $UNICHAIN_MAINNET_PIN_BLOCK | head -c 30
      # MUST return non-empty bytecode for all 4 canonical contracts.
      ```
- [ ] Tag the bump commit `rehearsal-YYYYMMDD`.
- [ ] Trigger the CI fork-tests-mainnet job.

## T-48h: Full fork suite — 3 consecutive runs

- [ ] **Run 1**: Pin block N-1000 (history check)
- [ ] **Run 2**: Pin block N (target deploy state)
- [ ] **Run 3**: Pin block N+1000 (forward — should produce identical results)

All 3 runs MUST show identical test pass counts and identical gas snapshots
(within rounding). Any divergence indicates time-dependent behavior that
needs investigation before mainnet.

## T-48h: Gas snapshot comparison

- [ ] Diff `.forge-snapshots/` against the last tagged release.
- [ ] Any gas regression > **5%** must be:
      - Justified in the commit message that introduced it
      - Reviewed by at least one other engineer
      - Listed in the deploy rehearsal report

## T-48h: Invariant extended run

The default invariant campaign runs 256 sequences x 128k calls. The
rehearsal run extends this to 512 sequences x 500-call depth.

- [ ] Run nightly fork tests workflow with `FOUNDRY_INVARIANT_RUNS=512`:
      ```
      gh workflow run ci.yml --ref rehearsal-YYYYMMDD --field run_extended=true
      ```
- [ ] Document any new invariant failures.
- [ ] **NO invariant failures may proceed to mainnet.**

## T-48h: Multi-RPC verification

PrediX's fork tests should pass against ALL configured RPC providers, not
just the primary. This catches RPC-specific quirks (data availability,
archive depth, rate limits).

- [ ] Run fork suite with `UNICHAIN_RPC_PRIMARY` = primary endpoint.
- [ ] Run fork suite with `UNICHAIN_RPC_PRIMARY` = secondary endpoint (the
      one configured as failover via `UNICHAIN_RPC_SECONDARY`).
- [ ] Both runs MUST produce identical pass counts.

## T-48h: Bytecode diff vs Sepolia

If a Sepolia staging deployment exists (per `README.md`), the mainnet
candidate bytecode should match the Sepolia bytecode for every audited
contract.

- [ ] For each in-scope contract, compute keccak of deployed bytecode:
      ```
      cast code 0x... --rpc-url https://sepolia.unichain.org | xxd -r -p | cast keccak
      ```
- [ ] Compute the same hash for the mainnet candidate bytecode (offline
      compilation output).
- [ ] Hashes MUST match. Any difference must be justified in writing.

---

## T-24h: Key ceremony

- [ ] **4 distinct Safes ready** per [`KEY_MANAGEMENT_POLICY.md`](KEY_MANAGEMENT_POLICY.md) v2.0:
      - **Safe 1 — Protocol Governance** (3-of-5 hardware) — `MULTISIG_ADDRESS`
      - **Safe 2 — Upgrade Governance** (3-of-5 hardware, distinct signer set) — `HOOK_PROXY_ADMIN`, `EXCHANGE_PROXY_ADMIN`
      - **Safe 3 — Operations** (2-of-4) — `HOOK_RUNTIME_ADMIN`, `PAYMASTER_OWNER`
      - **Safe 4 — Incident Response** (2-of-3 on-call) — `PAUSER_ADDRESS`
- [ ] Execute the full ceremony per [`SAFE_DEPLOYMENT_RUNBOOK.md`](SAFE_DEPLOYMENT_RUNBOOK.md) — preparation (T-2w), key generation (T-1w), deployment ceremony (T-3d).
- [ ] Confirm Safe 4 on-call rotation is live per [`PAUSER_ONCALL_PLAYBOOK.md`](PAUSER_ONCALL_PLAYBOOK.md) — three-person rotation across UTC bands, PagerDuty wired, war room channel active.
- [ ] Each signer:
      - Uses a dedicated hardware wallet (Ledger / Trezor) on latest firmware
      - Is on a dedicated, freshly-imaged machine (no other crypto wallets)
      - Has independently verified the deploy script bytecode + addresses
- [ ] Multisig procedure:
      - Every signer MUST decode transaction data via `cast pretty-call`
        BEFORE signing
      - Every signer MUST verify Safe transaction hash matches independently
        computed hash (defense against Bybit-class supply chain attacks on
        `app.safe.global`)
      - Multisig deployments use a self-hosted Safe UI or the IPFS-pinned
        static build, NOT `app.safe.global`

## T-24h: Monitoring infrastructure

- [ ] Forta bots / Defender Sentinels deployed and dry-run tested:
      - Every `RoleGranted` / `RoleRevoked` on diamond
      - Every `DiamondCut` proposal and execution
      - Every hook governance flow (`*Proposed`, `*Updated`)
      - Every exchange / hook proxy `UpgradeProposed` / `Upgraded`
      - Every `MarketEmergencyResolved` / `RefundModeEnabled`
      - Anomalous trade volumes (> 5σ above expected)
- [ ] On-call rotation defined and signers acknowledge.
- [ ] PagerDuty / equivalent escalation policy live.

## T-24h: Bug bounty

- [ ] Immunefi listing live with:
      - Scope: all 7 packages (DON'T forget `paymaster`)
      - Rewards aligned to TVL (recommend 10% of TVL up to $1M for Critical)
      - Disclosure timeline + SLAs defined

---

## T-2h: Final checks

- [ ] CI green on the rehearsal commit.
- [ ] All multisig signers have signed test transactions on testnet.
- [ ] Pause state confirmed `true` on all proxies (deploy starts PAUSED).
- [ ] Emergency rollback path tested.

---

## T-2h: Pre-flight env verification

- [ ] Run the standalone canonical-address pre-flight against the configured env:
      ```
      forge script VerifyDeployEnv --rpc-url $UNICHAIN_RPC_PRIMARY
      ```
      MUST print `VerifyDeployEnv: OK`. A revert here means `PERMIT2_ADDRESS`
      is not canonical, or `CHAINLINK_SEQUENCER_UPTIME_FEED` does not match
      the chain's expected feed. Fix env before proceeding.

## T+0: Deploy

- [ ] Execute deploy script from clean machine:
      ```
      forge script DeployAll --rpc-url $UNICHAIN_RPC_PRIMARY --sender $DEPLOYER_ADDRESS --broadcast
      ```
      The script runs `DeployEnvVerifier` in-broadcast as a second pre-flight
      and will revert before any state change if canonical addresses drift.
- [ ] Capture transaction hashes for every deploy step.
- [ ] Sourcify / Etherscan auto-verify within 1 hour.
- [ ] Bytecode hash matches T-48h offline computation.
- [ ] Multisig (`HOOK_RUNTIME_ADMIN`) calls `hook.acceptAdmin()` once the 48h
      `ADMIN_ROTATION_DELAY` has elapsed since `DeployAll` queued the
      rotation. Until accepted, the hook still routes runtime-admin calls
      to the deployer EOA.

## T+0+48h: Post-deploy verification

After the hook admin rotation is accepted, populate the deployed addresses
in `.env` (`DIAMOND_ADDRESS`, `HOOK_PROXY_ADDRESS`, `EXCHANGE_ADDRESS`,
`ROUTER_ADDRESS`, `ORACLE_MANUAL_ADDRESS`, `TIMELOCK_ADDRESS`) and run:

- [ ] `forge script PostDeployVerify --rpc-url $UNICHAIN_RPC_PRIMARY`
      MUST print `PostDeployVerify: OK`. The script reverts with a specific
      `PostDeployVerify_Failed(string)` on the first wiring discrepancy.
      Covers: diamond roles + facet routes, timelock delay + roles, hook
      diamond/admin/proxy admin/trusted routers, exchange diamond/usdc/
      fee-recipient/proxy admin + USDC allowance to diamond, router every
      immutable address, oracle approvals + DEFAULT_ADMIN_ROLE handover, and
      re-asserts canonical Permit2 + sequencer feed.

## T+1h: Mainnet smoke (Layer 5)

- [ ] Deploy a test market with small amounts (< 100 USDC TVL).
- [ ] Run full lifecycle: split → trade → resolve → redeem.
- [ ] Verify all events emitted.
- [ ] Verify router holds zero token balance after the trade.
- [ ] Verify Hook anti-sandwich detection on a controlled buyer/seller.

## T+24h: Unpause

- [ ] All smoke tests green.
- [ ] Monitoring quiet for 24h.
- [ ] Engineering sign-off from 2+ engineers.
- [ ] Operations sign-off.
- [ ] Unpause executed via multisig (with full procedure: clear-sign, verify,
      decode).

---

## Sign-off

| Role | Name | Date | Notes |
|---|---|---|---|
| Engineering | | | |
| Security | | | |
| Operations | | | |
| External audit firm | | | (post-clean audit report) |

---

## Appendix A — Beta launch mode

A beta launch deploys the **same** contracts as production but with a
conservative parameter set, an explicitly limited user surface, and an
explicit "beta" UI banner. Use this mode when integrating against real
Chainlink (when published on the target chain), real Permit2, and real
Uniswap v4 but before the full external audit has signed off.

This appendix covers **public beta** — limited public users, $50k per-market
caps, four-Safe operational posture. For an even lighter **internal
dev-beta** posture (1 Safe, business-hours response, $5k caps) used during
real-mainnet integration testing before public exposure, see
[`DEV_BETA_SETUP.md`](DEV_BETA_SETUP.md).

### What changes vs production

| Lever | Beta value | Production value |
|---|---|---|
| `DEFAULT_PER_MARKET_CAP` | 50,000 USDC | unlimited |
| `MARKET_CREATION_FEE` | 10 USDC (anti-spam) | per business model |
| `DEFAULT_REDEMPTION_FEE_BPS` | 100 (1.00%) | per business model |
| `TIMELOCK_DELAY_SECONDS` | 172800 (48h floor) | 432000–604800 (5–7d) once stable |
| `CHAINLINK_ENABLED` | `false` on Unichain at launch | `true` once Chainlink publishes Unichain feeds |
| Deploy starts paused? | Yes (pause MARKET, EVENT modules via PAUSER post-deploy) | No |
| Market creator role | Whitelisted team EOAs only | Open (per business model) |
| Bug bounty | Modest pool ($50–100k), public commitment | Full Immunefi listing |

`.env.beta.example` ships the beta `DEFAULT_*` values pre-filled. Use:

```
cp .env.beta.example .env
# fill in addresses, then continue with the T-48h … T+0+48h flow above
```

### Beta-specific T+0 steps

After `DeployAll` lands and `hook.acceptAdmin()` is signed by Safe 3:

- [ ] PAUSER (Safe 4) immediately pauses `MARKET` + `EVENT` modules on
      diamond. Beta unpauses only after `PostDeployVerify` is clean AND
      a smoke market completes its full lifecycle (split → trade →
      resolve → redeem) on T+1h.
- [ ] CREATOR_ROLE is granted only to the team's market-creator hot wallet
      (KMS-backed). Public creator role grant happens at graduation.

### Graduation to production

Promote from beta to production after:

1. ≥ 1 week of clean mainnet operation (no PAUSE events, no emergency
   resolves, no role rotations).
2. External audit firm sign-off lands.
3. Bug bounty escalated to full Immunefi listing.
4. Timelock proposal raises `TIMELOCK_DELAY_SECONDS` from 48h to 5–7d
   via the existing `proposeTimelockDuration` flow (which already enforces
   monotonic increase — see `PrediXHookProxyV2._MAX_TIMELOCK = 30d`).
5. Caps lifted via governance per business plan.

Graduation requires NO new deploy — the same contracts continue running
with updated parameters.
