# Indexer audit on-chain validation — 2026-05-23

These scripts execute the on-chain test scenarios that validate the indexer
P1 fix bundle (`audits/AUDIT_INDEXER_2026-05-23.md`). Target: Unichain
mainnet chainId 130, dev-beta deployment.

## Run order

All scripts read addresses + signing keys from `.env`. Run from
`packages/diamond/` with `--rpc-url $UNICHAIN_RPC_PRIMARY --broadcast --slow`.

```bash
cd packages/diamond
set -a && source ../../.env && set +a

# One-time setup: mint USDC + send ETH to 6 test wallets (HD 9-14)
forge script script/audit-indexer/_Funding.s.sol --rpc-url $UNICHAIN_RPC_PRIMARY --broadcast --slow

# Scenario 1: NO-side trade coverage (validates P1-E)
forge script script/audit-indexer/Scenario1_Setup.s.sol --rpc-url $UNICHAIN_RPC_PRIMARY --broadcast --slow
# WAIT 8 minutes (market endTime)
export S1_MARKET_ID=<from setup log>
forge script script/audit-indexer/Scenario1_Resolve.s.sol --rpc-url $UNICHAIN_RPC_PRIMARY --broadcast --slow

# Scenario 3: direct-Exchange takers (validates P1-A + P1-H)
forge script script/audit-indexer/Scenario3.s.sol --rpc-url $UNICHAIN_RPC_PRIMARY --broadcast --slow

# Scenario 4: event lifecycle (validates R3-A + R3-B + P1-G)
forge script script/audit-indexer/Scenario4_Setup.s.sol --rpc-url $UNICHAIN_RPC_PRIMARY --broadcast --slow
# WAIT 10 min (endTime) + 5 min hold (for R3-B "ended-unresolved" bucket)
export S4_EVENT_ID=<from setup log>
forge script script/audit-indexer/Scenario4_Resolve.s.sol --rpc-url $UNICHAIN_RPC_PRIMARY --broadcast --slow

# Scenario 5: refund flow (validates R3-A activeMarkets path)
forge script script/audit-indexer/Scenario5_Setup.s.sol --rpc-url $UNICHAIN_RPC_PRIMARY --broadcast --slow
# WAIT 5 min (endTime)
# SAFE TX A: grantRole(ADMIN_ROLE, deployer) on diamond — collect 3-of-3 sigs
export S5_MARKET_ID=<from setup log>
forge script script/audit-indexer/Scenario5_Refund.s.sol --rpc-url $UNICHAIN_RPC_PRIMARY --broadcast --slow
# SAFE TX B: revokeRole(ADMIN_ROLE, deployer) — close elevation window
```

## Scenario 2 (paymaster meta-tx)

Skipped per task fallback. P1-F end-to-end validation deferred until
a working backend signing service is wired (paymaster contract is deployed
but signing infra not exercised in this round).

## Safe tx calldata

For Scenario 5, the team Safe (`0xf10Ad39CeD9CaDb74627063b4671f8AEc6F1F36A`)
must call `Diamond.grantRole` / `Diamond.revokeRole`:

```
Target  : DIAMOND_ADDRESS (0xC8F12AF2a396c9C906ac36Bc0AC2279BBb69Ef96)
Value   : 0
Calldata grant : 0x2f2ff15d
                 0x84a7a283e0c6a5fad33db915b75d08b15ef8d1518fee8b50b4ed333b61701db5  (ADMIN_ROLE)
                 0x0000000000000000000000000c80f2e7372b669005c9db68ab7c704739cd9b82  (deployer)
Calldata revoke: 0xd547741f
                 0x84a7a283e0c6a5fad33db915b75d08b15ef8d1518fee8b50b4ed333b61701db5  (ADMIN_ROLE)
                 0x0000000000000000000000000c80f2e7372b669005c9db68ab7c704739cd9b82  (deployer)
```

Full grant calldata:
`0x2f2ff15d84a7a283e0c6a5fad33db915b75d08b15ef8d1518fee8b50b4ed333b61701db50000000000000000000000000c80f2e7372b669005c9db68ab7c704739cd9b82`

Full revoke calldata:
`0xd547741f84a7a283e0c6a5fad33db915b75d08b15ef8d1518fee8b50b4ed333b61701db50000000000000000000000000c80f2e7372b669005c9db68ab7c704739cd9b82`

## Output handoff

After each script:
- Tx hashes live in `packages/diamond/broadcast/<Script>.s.sol/130/run-latest.json`
- Market / event IDs printed via `console2.log` (capture from stdout)
- Indexer team queries `predix_indexer_mainnet` to verify expectations
