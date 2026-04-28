# Bundle C — Production Deployment Checklist

**Version**: 1.0
**Date**: 2026-04-28
**Purpose**: Step-by-step checklist for mainnet-ready deployment

---

## Phase 1: Pre-deployment (Day 1)

### 1.1 Deploy Safe Multisig

- [ ] Go to https://app.safe.global → Create new Safe on Unichain
- [ ] Add 5 signers (each with hardware wallet: Ledger/Trezor)
- [ ] Set threshold: 3-of-5
- [ ] Fund Safe with ~1 ETH for gas
- [ ] Record Safe address → paste into `.testenv.production` as `MULTISIG_ADDRESS`
- [ ] Verify all 5 signers can connect and sign a test tx

### 1.2 Prepare operational hot wallets

- [ ] Create `REPORTER_ADDRESS` EOA (manual oracle reporter)
- [ ] Create `REGISTRAR_ADDRESS` EOA (Chainlink market registrar)
- [ ] Fund each with ~0.1 ETH for gas
- [ ] Store keys in KMS (AWS KMS / HashiCorp Vault) — NOT local

### 1.3 Prepare env file

- [ ] Copy `.testenv.production.example` → `.testenv.production`
- [ ] Fill ALL addresses (multisig, hot wallets, USDC, PoolManager, Permit2, Quoter)
- [ ] Verify USDC address on Unichain block explorer
- [ ] Verify PoolManager address on Unichain docs
- [ ] Set `DIAMOND_FINALIZE_GOVERNANCE=true`
- [ ] Double-check `TIMELOCK_DELAY_SECONDS=172800` (48 hours)

---

## Phase 2: Rehearsal on Sepolia (Day 2)

### 2.1 Dry-run deployment

```bash
# Load Sepolia env
source .testenv.staging

# Simulate (no broadcast)
forge script packages/diamond/script/DeployAll.s.sol \
  --rpc-url $RPC_URL \
  --private-key $DEPLOYER_PRIVATE_KEY \
  -vvv

# If simulation passes, broadcast
forge script packages/diamond/script/DeployAll.s.sol \
  --rpc-url $RPC_URL \
  --private-key $DEPLOYER_PRIVATE_KEY \
  --broadcast \
  -vvv
```

### 2.2 Post-deploy verification

- [ ] Record all deployed addresses from console output
- [ ] Verify Diamond:
  ```bash
  cast call $DIAMOND "hasRole(bytes32,address)(bool)" $(cast keccak "predix.role.admin") $MULTISIG
  # Should return: true
  
  cast call $DIAMOND "hasRole(bytes32,address)(bool)" $(cast keccak "predix.role.admin") $DEPLOYER
  # Should return: false (deployer revoked)
  ```
- [ ] Verify Timelock holds CUT_EXECUTOR:
  ```bash
  cast call $DIAMOND "hasRole(bytes32,address)(bool)" $(cast keccak "predix.role.cut_executor") $TIMELOCK
  # Should return: true
  ```
- [ ] Verify Hook admin = multisig (or HOOK_RUNTIME_ADMIN):
  ```bash
  cast call $HOOK_PROXY "admin()(address)"
  ```
- [ ] Verify Hook proxy admin:
  ```bash
  cast call $HOOK_PROXY "proxyAdmin()(address)"
  ```
- [ ] Verify Exchange proxy admin:
  ```bash
  cast call $EXCHANGE_PROXY "admin()(address)"
  ```
- [ ] Verify fee recipient:
  ```bash
  cast call $DIAMOND "feeRecipient()(address)"
  ```

### 2.3 Smoke tests on Sepolia

- [ ] Create a market via multisig:
  ```bash
  # From multisig (via Safe UI or cast with signer)
  cast send $DIAMOND "createMarket(string,uint256,address)" \
    "Test market" $(date -v+7d +%s) $MANUAL_ORACLE
  ```
- [ ] Split position (as user)
- [ ] Trade on CLOB (placeOrder + fillMarketOrder)
- [ ] Resolve market (via reporter)
- [ ] Redeem (as user)
- [ ] Verify fee arrived at feeRecipient
- [ ] Test pause from hot wallet:
  ```bash
  cast send $DIAMOND "pauseModule(bytes32)" $(cast keccak "predix.module.market") \
    --private-key $PAUSER_KEY
  ```
- [ ] Verify split reverts while paused
- [ ] Unpause
- [ ] Test emergency resolve (after 7 days)

### 2.4 Rehearsal rollback test

- [ ] Pause all modules (simulate incident)
- [ ] Verify redeem/refund still works while paused
- [ ] Cancel any pending governance (if any)
- [ ] Unpause

---

## Phase 3: Mainnet Deployment (Day 3-4)

### 3.1 Pre-flight

- [ ] Rehearsal on Sepolia passed all checks above
- [ ] External audit firm sign-off received
- [ ] Source code matches audited commit exactly: `git log --oneline -1`
- [ ] `.testenv.production` filled with mainnet addresses
- [ ] All 5 multisig signers available + online
- [ ] Team Slack/Discord channel open for coordination

### 3.2 Deploy

```bash
source .testenv.production

# SIMULATION FIRST — verify everything before spending real ETH
forge script packages/diamond/script/DeployAll.s.sol \
  --rpc-url $RPC_URL \
  --private-key $DEPLOYER_PRIVATE_KEY \
  -vvv

# User confirms: "MAINNET APPROVED"

# BROADCAST
forge script packages/diamond/script/DeployAll.s.sol \
  --rpc-url $RPC_URL \
  --private-key $DEPLOYER_PRIVATE_KEY \
  --broadcast \
  --verify \
  -vvv
```

### 3.3 Post-deploy verification (same as 2.2 but on mainnet)

- [ ] ALL role checks pass (multisig holds admin, timelock holds cut_executor)
- [ ] Deployer holds ZERO roles
- [ ] Fee recipient correct
- [ ] Hook admin + proxy admin correct
- [ ] Exchange proxy admin correct
- [ ] Oracle admin = multisig
- [ ] Contracts verified on block explorer

### 3.4 Publish

- [ ] Update README.md with mainnet contract addresses
- [ ] Update `specs/AUDIT_SPEC.md` with deployed addresses
- [ ] Publish contract source on block explorer (auto via `--verify`)
- [ ] Announce on Discord/Twitter

### 3.5 Post-deploy security

- [ ] Destroy deployer private key (or move to cold storage)
- [ ] Enable monitoring (Forta / OZ Defender) with deployed addresses
- [ ] Activate Immunefi bug bounty with mainnet scope
- [ ] Schedule first incident response drill (1 week post-launch)

---

## Phase 4: Ongoing Operations

### Role matrix (post-deploy)

| Role | Holder | Key type | Purpose |
|---|---|---|---|
| DEFAULT_ADMIN_ROLE | Safe 3-of-5 | Hardware wallets | Grant/revoke all roles |
| ADMIN_ROLE | Safe 3-of-5 | Hardware wallets | Fee config, oracle whitelist, caps |
| OPERATOR_ROLE | Safe 3-of-5 | Hardware wallets | Emergency resolve, event resolve |
| PAUSER_ROLE | Hot wallet | KMS-managed | Fast incident response pause |
| CREATOR_ROLE | Backend service | KMS-managed | Create markets via API |
| CUT_EXECUTOR_ROLE | TimelockController | On-chain (48h delay) | Diamond facet upgrades |
| Hook admin | Safe 3-of-5 | Hardware wallets | Diamond rotation, trusted-router, pause |
| Hook proxy admin | Safe 3-of-5 | Hardware wallets | Hook impl upgrades |
| Exchange proxy admin | Safe 3-of-5 | Hardware wallets | Exchange impl upgrades |
| Oracle admin | Safe 3-of-5 | Hardware wallets | Revoke reporter, role management |
| Oracle reporter | Hot wallet | KMS-managed | Report manual oracle outcomes |
| Oracle registrar | Hot wallet | KMS-managed | Register Chainlink feeds |
| Paymaster owner | Safe 3-of-5 | Hardware wallets | Signer rotation, pause |

### Monitoring alerts (Forta / OZ Defender)

| Alert | Condition | Severity |
|---|---|---|
| Large fee transfer | `feeRecipient` receives > $10K in 1 tx | Medium |
| Pause event | Any `Paused` / `ModulePaused` event | High |
| Governance proposal | Any `*Proposed` event (upgrade, rotation, timelock) | High |
| Unusual revert rate | > 10% of txs revert in 1 hour | Medium |
| Role change | Any `RoleGranted` / `RoleRevoked` event | Critical |
| Large collateral | `splitPosition` with > $100K single tx | Medium |
| Oracle resolution | `MarketResolved` event (track all) | Info |

---

## Appendix: Emergency Procedures Quick Reference

### Pause everything (P0 nuclear)

```bash
# Pause Diamond MARKET module
cast send $DIAMOND "pauseModule(bytes32)" \
  $(cast keccak "predix.module.market") \
  --private-key $PAUSER_KEY

# Pause Exchange
cast send $EXCHANGE_PROXY "pause()" --private-key $PAUSER_KEY

# Pause Hook
cast send $HOOK_PROXY "setPaused(bool)" true --private-key $HOOK_ADMIN_KEY
```

### Cancel pending governance

```bash
# Cancel hook diamond rotation
cast send $HOOK_PROXY "cancelDiamondRotation()" --private-key $HOOK_ADMIN_KEY

# Cancel hook upgrade
cast send $HOOK_PROXY "cancelUpgrade()" --private-key $HOOK_PROXY_ADMIN_KEY

# Cancel exchange upgrade
cast send $EXCHANGE_PROXY "cancelUpgrade()" --private-key $EXCHANGE_ADMIN_KEY
```

### Enable refund mode (market-level emergency)

```bash
cast send $DIAMOND "enableRefundMode(uint256)" $MARKET_ID \
  --private-key $ADMIN_KEY  # requires multisig
```

---

*Last updated: 2026-04-28. Review before every deployment.*
