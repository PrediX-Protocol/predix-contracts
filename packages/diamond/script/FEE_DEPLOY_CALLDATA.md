# Fee System — Calldata Playbook (PRINT-ONLY, no broadcast)

> Companion to `README_FEE_DEPLOY.md`. Every tx below is submitted by the **human/Safe** with explicit
> "MAINNET APPROVED". The deploy tooling only **prints calldata + verifies read-only** — nothing here broadcasts.
> Ordering + authorities are in the runbook. Timelock kept at **1h** (operator decision).

Live (unchanged): Diamond `0xC8F12AF2a396c9C906ac36Bc0AC2279BBb69Ef96` · Exchange proxy `0x506367C7c48C95A4843F45d5C2F177B35e69594E` · Timelock `0xC5c64967CAA46e588cCe3eA97F761B5282e98882` · TEAM_SAFE `0xf10Ad39CeD9CaDb74627063b4671f8AEc6F1F36A`.
Fill after Phase A: `BUILDER_REGISTRY_ADDRESS`, `NEW_EXCHANGE_IMPL`, `NEW_MARKET_FACET`, `NEW_ROUTER`, `<TREASURY>`, `<BUILDER_CODE>`, `<BUILDER_RECIPIENT>`.

---

## Phase A — deploy artifacts (deployer EOA)
Dry-run (no broadcast) to confirm + get gas, then broadcast on human go (record each address):
```bash
cd packages/diamond
forge script script/DeployBuilderRegistry.s.sol:DeployBuilderRegistry --rpc-url "$UNICHAIN_RPC_PRIMARY" --sender "$DEPLOYER_ADDRESS"   # -> BUILDER_REGISTRY_ADDRESS
forge script script/DeployExchangeImpl.s.sol:DeployExchangeImpl       --rpc-url "$UNICHAIN_RPC_PRIMARY" --sender "$DEPLOYER_ADDRESS"   # -> NEW_EXCHANGE_IMPL
BUILDER_REGISTRY_ADDRESS=<...> forge script script/DeployRouterV2.s.sol:DeployRouterV2 --rpc-url "$UNICHAIN_RPC_PRIMARY" --sender "$DEPLOYER_ADDRESS"   # -> NEW_ROUTER
# NEW_MARKET_FACET: deploy via the cut printer's facet, or `forge create MarketFacet`.
```

## Phase B — diamond cut via Timelock (1h)  [authority: Timelock]
**Generate the exact calldata** (reads the live diamond, prints `diamondCut` + Timelock `schedule`/`execute`):
```bash
NEW_MARKET_FACET=<deployed> SALT=<random bytes32> DELAY=3600 \
forge script script/ProtocolFeeMarketCutMainnet.s.sol:ProtocolFeeMarketCutMainnet --rpc-url "$UNICHAIN_RPC_PRIMARY"
```
Output = `Replace=32 / Add=6` + 3 calldata blobs. Safe submits:
1. `schedule(...)` calldata → **Timelock** (`0xC5c649…`).
2. wait **≥ 3600s (1h)**.
3. `execute(...)` calldata → **Timelock**.
Add list = the 6 fee selectors: `0x4e0f140d setDefaultProtocolFeeRateBps · 0x94d02687 setPerMarketProtocolFeeRateBps · 0x2cf56971 clearPerMarketProtocolFee · 0x61573ccc setProtocolMakerRebateBps · 0xa6f60a19 effectiveProtocolFee · 0xc8b7cdb5 getFeeConfig`.
Verify (read-only): `cast call <DIAMOND> "facetAddress(bytes4)(address)" 0x4e0f140d` == `NEW_MARKET_FACET`.

## Phase C — Exchange proxy upgrade (48h)  [authority: proxy admin = TEAM_SAFE] → proxy `0x506367…594E`
```bash
# propose (fill NEW_EXCHANGE_IMPL):
cast calldata "proposeUpgrade(address)" <NEW_EXCHANGE_IMPL>
# execute (FIXED, no args, after >= 48h):
0x7e896214
```
Verify: `pendingImplementation()==NEW_EXCHANGE_IMPL` + `upgradeReadyAt()==propose_ts+172800`; post-execute `implementation()==NEW_EXCHANGE_IMPL`, `paused()` unchanged.

## Phase D — ADMIN wiring  [authority: diamond ADMIN_ROLE = TEAM_SAFE] (immediate)
```bash
# exchange proxy 0x506367…594E:
cast calldata "setBuilderRegistry(address)"      <BUILDER_REGISTRY_ADDRESS>
cast calldata "setProtocolFeeRecipient(address)" <TREASURY>
# diamond 0xC8F1…Ef96 (P10 launch = inert):
setDefaultProtocolFeeRateBps(0) : 0x4e0f140d0000000000000000000000000000000000000000000000000000000000000000
setProtocolMakerRebateBps(0)    : 0x61573ccc0000000000000000000000000000000000000000000000000000000000000000
# registry BUILDER_REGISTRY_ADDRESS (per integrator, e.g. Phemex taker 100 / maker 0):
cast calldata "setBuilder(bytes32,address,uint16,uint16)" <BUILDER_CODE> <BUILDER_RECIPIENT> 100 0
```

## Phase E — router cutover
FE/BE/bots repoint to `NEW_ROUTER` (pass `builder=bytes32(0)` until enrolled). OLD router stays live; decommission after drain.

---

## Function selector reference
| Function | Selector |
|---|---|
| `executeUpgrade()` | `0x7e896214` |
| `proposeUpgrade(address)` | `0xc915fc93` |
| `setBuilderRegistry(address)` | `0xbd322efa` |
| `setProtocolFeeRecipient(address)` | `0xe521cb92` |
| `setDefaultProtocolFeeRateBps(uint256)` | `0x4e0f140d` |
| `setProtocolMakerRebateBps(uint16)` | `0x61573ccc` |
| `setBuilder(bytes32,address,uint16,uint16)` | `0xe661856f` |
| `diamondCut((address,uint8,bytes4[])[],address,bytes)` | `0x1f931c1c` |
| Timelock `schedule(address,uint256,bytes,bytes32,bytes32,uint256)` | `0x01d5062a` |
| Timelock `execute(address,uint256,bytes,bytes32,bytes32)` | `0x134008d3` |

## Read-only live-state (verified on chain-130 at authoring; re-check at deploy time)
chain id 130 · proxy `admin()`==TEAM_SAFE · `pendingImplementation()`==0 · proxy `UPGRADE_DELAY()`==172800 (48h) · Timelock `getMinDelay()`==3600 (1h) · `facetAddress(0x4e0f140d)`==0x0 (cut not yet live).
