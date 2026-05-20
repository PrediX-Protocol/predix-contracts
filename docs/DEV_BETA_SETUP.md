# Dev Beta Setup

**Audience:** internal engineering
**Status:** Active during the dev-beta window
**Owner:** KT (Security Owner)
**Last reviewed:** 2026-05-20

The dev-beta deploy is **smart contracts on real Unichain mainnet**, with **real Chainlink + Permit2 + Uniswap v4 + USDC**, but **operated at internal-test scale**: limited testers, small TVL caps, no public marketing. This doc covers the minimal viable operational setup. When the team is ready to open up to public users, graduate to the four-Safe model per [`SAFE_DEPLOYMENT_RUNBOOK.md`](SAFE_DEPLOYMENT_RUNBOOK.md).

The smart contracts deployed by `DeployAll` are **identical** across dev beta, public beta, and production. Only the operational posture (Safe layout, monitoring, response) changes.

---

## 1. When to use this profile

Use `.env.dev-beta.example` when:

- Verifying real Chainlink integration against canonical feeds.
- End-to-end smoke testing against real Permit2 / PoolManager / V4Quoter / USDC.
- Onboarding internal team + a small named tester group.
- TVL ceiling stays under $50k aggregate during the test window.

Do **not** use this profile when:

- Opening to public users (graduate to `.env.beta.example` first — see § 5).
- Running production launch (graduate to a four-Safe deploy per `SAFE_DEPLOYMENT_RUNBOOK.md`).
- Holding > $50k aggregate TVL at any time.

---

## 2. What the dev-beta setup relaxes

Relative to `KEY_MANAGEMENT_POLICY.md` v2.0 production:

| Item | Production (4-Safe) | Dev beta |
|---|---|---|
| Safe count | 4 distinct | **1 team Safe** holds every admin role except PAUSER |
| Threshold per Safe | 3-of-5 / 2-of-4 / 2-of-3 | **2-of-3 or 3-of-5** on the single team Safe |
| Signer count | 9–10 distinct individuals | 3–5 team leads |
| Hardware wallet | Strict (Ledger / Trezor) | Recommended; KMS-backed EOA acceptable for non-Safe roles |
| Key ceremony | Formal three-phase per `SAFE_DEPLOYMENT_RUNBOOK.md` | Generate via `app.safe.global` with existing team wallets, no observers |
| PAUSER on-call | 24/7 three-shift rotation per `PAUSER_ONCALL_PLAYBOOK.md` | Business hours, ad-hoc, KMS-backed hot wallet |
| Monitoring | Forta/Defender + PagerDuty + 24/7 escalation | **Tenderly alerts → Slack channel** |
| Bug bounty | Immunefi listing live | Internal disclosure only |
| Drill cadence | Monthly tabletop + quarterly testnet + annual full | None — fix as issues arise |

The blast radius of a single team-Safe compromise is bounded by the conservative caps below. That bound is what makes the single-Safe posture acceptable during this window.

---

## 3. What stays the same as production

These items hold regardless of deploy profile. Relaxing any of them widens the blast radius beyond acceptable for a real-mainnet deploy.

- [ ] `DIAMOND_FINALIZE_GOVERNANCE=true` — deployer EOA renounces every privileged role in-broadcast.
- [ ] `forge script VerifyDeployEnv` passes pre-broadcast — canonical Permit2 + sequencer feed enforced.
- [ ] `forge script PostDeployVerify` passes after the hook admin rotation lands — every wiring invariant confirmed.
- [ ] `TIMELOCK_DELAY_SECONDS=172800` (48h floor). Do not lower.
- [ ] PAUSER address SEPARATE from the team Safe — emergency pause must not wait on the governance quorum.
- [ ] Conservative caps: `DEFAULT_PER_MARKET_CAP=5_000_000_000` (5k USDC), `MARKET_CREATION_FEE=10_000_000` (10 USDC anti-spam), `DEFAULT_REDEMPTION_FEE_BPS=100` (1.00%).
- [ ] Public-facing UI displays a "Dev beta — real funds at risk" banner. No marketing claiming production.

---

## 4. Setup checklist

### 4.1 Pre-deploy (~30 minutes)

- [ ] Identify 3–5 team leads who will hold the Safe.
- [ ] Each signer connects an existing wallet to `app.safe.global` (hardware preferred; software acceptable for dev beta).
- [ ] Deploy a fresh Safe on Unichain mainnet with the chosen signers and threshold (recommend 2-of-3 or 3-of-5).
- [ ] Record the Safe address as `TEAM_SAFE` in the team's password manager — not in the repo.
- [ ] Generate or designate one KMS-backed hot wallet for `PAUSER_ADDRESS`. AWS KMS, GCP KMS, or HashiCorp Vault.
- [ ] Generate or designate hot wallets for `CREATOR_ROLE`, `REPORTER_ROLE`, paymaster signer. KMS-backed.

### 4.2 Env wiring (~10 minutes)

- [ ] `cp .env.dev-beta.example .env`
- [ ] Fill in `TEAM_SAFE`, `PAUSER_ADDRESS`, `FEE_RECIPIENT`, `DEPLOYER_PRIVATE_KEY` (or use `--ledger`), `UNICHAIN_RPC_PRIMARY`.
- [ ] Confirm `CHAINLINK_ENABLED=false` if running first-pass tests with ManualOracle only; flip to `true` and supply `REGISTRAR_ADDRESS=${TEAM_SAFE}` when ready to test Chainlink integration.

### 4.3 Pre-flight + deploy (~5 minutes)

- [ ] `forge script VerifyDeployEnv --rpc-url $UNICHAIN_RPC_PRIMARY`
      Expected output: `VerifyDeployEnv: OK`.
- [ ] `forge script DeployAll --rpc-url $UNICHAIN_RPC_PRIMARY --sender $DEPLOYER_ADDRESS --broadcast`
- [ ] Capture the deployed addresses from the script's log output. Populate `DIAMOND_ADDRESS`, `EXCHANGE_ADDRESS`, `HOOK_PROXY_ADDRESS`, `ROUTER_ADDRESS`, `ORACLE_MANUAL_ADDRESS`, `TIMELOCK_ADDRESS` in `.env`.

### 4.4 Post-deploy handover (T+0+48h)

The hook's admin rotation is two-step. The deployer proposes `setAdmin(HOOK_RUNTIME_ADMIN)` in-broadcast; the new admin must call `acceptAdmin()` after the 48h delay. For dev beta:

- [ ] After 48h, the team Safe signs `hook.acceptAdmin()`.
- [ ] `forge script PostDeployVerify --rpc-url $UNICHAIN_RPC_PRIMARY`
      Expected output: `PostDeployVerify: OK`.

### 4.5 Monitoring (~30 minutes)

Minimum viable monitoring for dev beta:

- [ ] Tenderly project monitoring the deployed contracts (diamond, hook proxy, exchange, router, oracles).
- [ ] Tenderly alerts → Slack webhook in a dedicated channel (`#predix-dev-beta-alerts` or similar). Alert on:
      - Any `Paused` / `Unpaused` event
      - Any `RoleGranted` / `RoleRevoked`
      - Any failed transaction on these contracts
      - `MarketEmergencyResolved` / `EventEmergencyResolved`
      - `Upgraded` on either proxy
- [ ] On-call engineer assigned (one person, business hours) — drops the Slack channel into their notification feed.

PagerDuty / Forta / Defender are **not required** for dev beta. They become required when graduating to public beta.

---

## 5. Graduation

When ready to open dev beta to public users (public beta) or run a true production launch, follow this graduation path. **No code change required** — all changes are at the env / Safe level.

### 5.1 Dev beta → public beta

Trigger: opening market creation or trading to non-team users.

- [ ] Run [`SAFE_DEPLOYMENT_RUNBOOK.md`](SAFE_DEPLOYMENT_RUNBOOK.md) phases A–C to deploy the four production Safes.
- [ ] On the live diamond, the team Safe proposes (via 48h timelock):
      - `grantRole(DEFAULT_ADMIN_ROLE, SAFE_1)`
      - `grantRole(ADMIN_ROLE, SAFE_1)`
      - `grantRole(OPERATOR_ROLE, SAFE_1)`
      - `grantRole(CREATOR_ROLE, SAFE_1)` (or keep a hot wallet)
- [ ] After the 48h timelock, execute the grants.
- [ ] Team Safe proposes role revocations from itself: `revokeRole(*, TEAM_SAFE)` for each granted role. The new Safe 1 executes these revocations.
- [ ] Rotate `HOOK_PROXY_ADMIN` to Safe 2 via `hook.transferProxyAdmin(SAFE_2)`.
- [ ] Rotate `EXCHANGE_PROXY_ADMIN` to Safe 2 via the proxy's admin-transfer flow.
- [ ] Rotate `HOOK_RUNTIME_ADMIN` to Safe 3 via the existing two-step `setAdmin` → `acceptAdmin`.
- [ ] Transfer paymaster ownership to Safe 3.
- [ ] Rotate `PAUSER_ROLE` to Safe 4 via the same `grantRole` + `revokeRole` pair from Safe 1.
- [ ] Run `forge script PostDeployVerify` against an updated env pointing at the four Safes — must pass.
- [ ] Stand up the `PAUSER_ONCALL_PLAYBOOK.md` rotation.
- [ ] Raise caps: `DEFAULT_PER_MARKET_CAP` → 50k USDC, etc. (per `.env.beta.example`).
- [ ] Bug bounty live (internal disclosure plus a modest public bounty).

### 5.2 Public beta → production

After ≥ 1 week of clean public-beta operation, no PAUSE events, no emergency resolves, no role rotations:

- [ ] Raise `TIMELOCK_DELAY_SECONDS` from 172800 (48h) to 432000–604800 (5–7d) via the existing `proposeTimelockDuration` flow.
- [ ] External audit firm sign-off lands.
- [ ] Bug bounty escalated to full Immunefi listing.
- [ ] Lift caps via governance per business plan.
- [ ] Open market creator role to public per business plan.

Graduation requires **no new deploy**. The same contracts continue running with progressively stricter operational posture.

---

## 6. Reference

- `.env.dev-beta.example` — env template for this profile
- `.env.beta.example` — env template for the public-beta graduation step
- `.env.example` — generic deploy template (used as the base for both above)
- [`KEY_MANAGEMENT_POLICY.md`](KEY_MANAGEMENT_POLICY.md) — production policy this profile relaxes against
- [`SAFE_DEPLOYMENT_RUNBOOK.md`](SAFE_DEPLOYMENT_RUNBOOK.md) — full ceremony required for public beta + production
- [`PAUSER_ONCALL_PLAYBOOK.md`](PAUSER_ONCALL_PLAYBOOK.md) — Safe 4 operational manual, becomes required at public beta
- [`MAINNET_DEPLOY_REHEARSAL.md`](MAINNET_DEPLOY_REHEARSAL.md) Appendix A — beta launch mode (the broader version of this doc)
