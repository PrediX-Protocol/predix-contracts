# Fee System — Mainnet Deploy / Upgrade Runbook (chain-130 Unichain)

> **Sub-plan 05 Task 5. DOCUMENTED, NOT executed.** No transaction here is broadcast by an agent. Each script is
> dry-run (no `--broadcast`) to print calldata + gas; a **human/Safe** submits every state-changing tx after
> review. Agents only verify read-only (`cast call`).

The fee system (builder fee + protocol fee + Mức-1 config) ships as **ONE combined upgrade** (GỘP). At launch
all params are 0 ⇒ **P10 byte-identical** to today (proven by `FeeSystemForkE2E` + the 815-test suite).

## Live addresses (verified read-only; do NOT change)
| Thing | Address | Note |
|---|---|---|
| Diamond | `0xC8F12AF2a396c9C906ac36Bc0AC2279BBb69Ef96` | **UNCHANGED** by this upgrade (cut in place) |
| Exchange proxy | `0x506367C7c48C95A4843F45d5C2F177B35e69594E` | **UNCHANGED** (impl swapped behind it) |
| Timelock | `0xC5c64967CAA46e588cCe3eA97F761B5282e98882` | diamond cut authority; `getMinDelay()` = 1h today |
| TEAM_SAFE | `0xf10Ad39CeD9CaDb74627063b4671f8AEc6F1F36A` | diamond `ADMIN_ROLE` + Exchange proxy `_ADMIN_SLOT` admin |
| TestUSDC | `0xB3FCA863dD0F6b496cCDDf6497Da5Dad67857F56` | collateral |

The **four NEW addresses** to publish after deploy: `BUILDER_REGISTRY_ADDRESS`, `NEW_EXCHANGE_IMPL` (behind the
unchanged proxy), `NEW_MARKET_FACET` (behind the unchanged diamond), `NEW_ROUTER`. **Only the router address
changes for integrators.**

## ⚠️ Prerequisites & ordering constraints (load-bearing)
1. **OPS — clm6.1 FIRST:** raise the diamond Timelock `getMinDelay()` 1h → 48h + split PROPOSER/EXECUTOR before
   the fee cut (the cut rides this Timelock). Verify `cast call <timelock> "getMinDelay()(uint256)"`; the
   Phase-B wait below = whatever this returns at deploy time (1h today, 48h after clm6.1).
2. **DIAMOND-CUT-FIRST (proven):** the new Exchange impl + new Router decode `getMarket()` as the **17-field**
   `MarketView`; the live diamond returns the **15-field** struct until the cut lands. Executing the Exchange
   upgrade (Phase C) **before** the MarketFacet cut (Phase B) is live would brick `getMarket` reads.
   `ProtocolFeeMarketCutForkSim` empirically confirms this. → **Phase B must EXECUTE before Phase C executes.**
   (Old contracts read the 15-field prefix fine, so the cut is safe for the live router/exchange in the gap.)
3. **Storage-safety (proven):** `FeeStorageLayoutForkSim` ran the real 48h proxy upgrade on a chain-130 fork —
   `paused`@slot-8 + diamond/usdc/feeRecipient survive byte-identical, ERC-7201 fee namespaces read zero, old
   orders survive with `builder == 0` (appended field). No proxy brick.

## Safe order: deploy → cut (Timelock) → upgrade (48h) → wire → router → migrate

### Phase A — deploy artifacts (deployer EOA; HIGH-RISK = explicit human go)
Dry-run each first (prints sim address + gas), announce, then broadcast `--broadcast --slow`:
```bash
cd packages/diamond
# dry-run (no broadcast):
forge script script/DeployBuilderRegistry.s.sol:DeployBuilderRegistry --rpc-url "$UNICHAIN_RPC_PRIMARY" --sender "$DEPLOYER_ADDRESS"
forge script script/DeployExchangeImpl.s.sol:DeployExchangeImpl   --rpc-url "$UNICHAIN_RPC_PRIMARY" --sender "$DEPLOYER_ADDRESS"
BUILDER_REGISTRY_ADDRESS=<from above> \
forge script script/DeployRouterV2.s.sol:DeployRouterV2           --rpc-url "$UNICHAIN_RPC_PRIMARY" --sender "$DEPLOYER_ADDRESS"
# broadcast (ONLY after human go), record each address:
#   DeployBuilderRegistry --broadcast --slow   -> BUILDER_REGISTRY_ADDRESS
#   DeployExchangeImpl    --broadcast --slow   -> NEW_EXCHANGE_IMPL
#   DeployRouterV2        --broadcast --slow   -> NEW_ROUTER   (needs BUILDER_REGISTRY_ADDRESS)
```
The MarketFacet for the cut is deployed via `ProtocolFeeMarketCut.deployMarketFacet()` (build the Timelock
`schedule`/`execute` calldata from `ProtocolFeeMarketCut.buildCuts(diamond, NEW_MARKET_FACET)` → the
`diamondCut(cuts, address(0), "")` calldata). Record `NEW_MARKET_FACET`.

### Phase B — diamond MarketFacet cut via Timelock  [authority: Timelock]
```
SALT = <random bytes32, recorded>
delay = cast call <TIMELOCK> "getMinDelay()(uint256)"      # 1h today / 48h after clm6.1
# Safe submits:
schedule(diamond, 0, diamondCutData, 0, SALT, delay)
# wait >= delay, then:
execute(diamond, 0, diamondCutData, 0, SALT)
```
Verify read-only (must pass BEFORE Phase C executes):
```bash
cast call <DIAMOND> "facetAddress(bytes4)(address)" <setDefaultProtocolFeeRateBps_sig> --rpc-url "$UNICHAIN_RPC_PRIMARY"   # == NEW_MARKET_FACET
cast call <DIAMOND> "getMarket(uint256)" <knownId> --rpc-url "$UNICHAIN_RPC_PRIMARY"                                        # decodes 17 fields, 2 new == 0
```

### Phase C — Exchange proxy upgrade (48h)  [authority: proxy admin = TEAM_SAFE]
```
# Safe (proxy admin):
proposeUpgrade(NEW_EXCHANGE_IMPL)            # to proxy 0x506367...594E
# verify pendingImplementation()==NEW_EXCHANGE_IMPL ; upgradeReadyAt()==propose_ts + 48h
# wait >= 48h (UPGRADE_DELAY), then:
executeUpgrade()
```
Verify: `implementation()==NEW_EXCHANGE_IMPL`, `paused()` unchanged, `accruedProtocolFee()==0`.

### Phase D — ADMIN wiring  [authority: diamond ADMIN_ROLE = TEAM_SAFE] (immediate, one Safe tx each)
```
exchange.setBuilderRegistry(BUILDER_REGISTRY_ADDRESS)
exchange.setProtocolFeeRecipient(<treasury>)
market.setDefaultProtocolFeeRateBps(0)        # P10 launch: inert (coef 0)
market.setProtocolMakerRebateBps(0)           # P10 launch: inert
registry.setBuilder(<code>, <recipient>, 100, 0)   # per integrator, e.g. Phemex taker 100 / maker 0
```

### Phase E — router cutover
- Real-USDC mainnet: no whitelist needed. The OLD router stays live; FE/BE/bots migrate to `NEW_ROUTER`.
- Decommission OLD router only after traffic drains.

## Address-migration list (downstream)
| Consumer | Change | Action |
|---|---|---|
| **FE / FE_admin** | router addr old → `NEW_ROUTER` | swap addr + ABI (entries gain trailing `bytes32 builder`); add `BUILDER_REGISTRY_ADDRESS` for the register/rotate-builder admin UI |
| **BE** | router addr + exchange ABI | new router ABI; new exchange views `accruedBuilderFee`/`accruedProtocolFee`; registry reads |
| **INDEXER** | exchange + router + registry ABIs | index new events (`BuilderFeeAccrued`/`ProtocolFeeCharged`/`AmmSkipped`) + `Trade.builder` + widened `MarketView` arity; add `BUILDER_REGISTRY_ADDRESS` source |
| **bots / liquidity** | router addr → `NEW_ROUTER` | repoint; pass `builder=bytes32(0)` until enrolled |

## Rollback
- Pre-Phase-C: the diamond cut is Replace+Add only; a reverse cut (Replace back to the old MarketFacet) restores it. Old markets unaffected (new fields read 0).
- Exchange upgrade is 2-step + 48h: cancel by NOT executing, or re-propose the old impl. The proxy admin can always re-`proposeUpgrade(OLD_IMPL)`.
- Router is a fresh address; rollback = keep pointing FE/bots at the OLD router.

## Caveats
- This runbook is the only place `--broadcast` appears. Per `foundry-broadcast-permission`: announce gas + the exact tx, get explicit human "MAINNET APPROVED", then broadcast. Agents verify read-only only.
- Confirm `getMinDelay()` and the proxy `UPGRADE_DELAY()` (48h) at deploy time — do not assume.
