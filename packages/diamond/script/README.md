# PrediX V2 — Deployment scripts

Foundry deployment scripts for the full PrediX V2 protocol stack. Every script is
**env-driven** — no per-chain constants are hardcoded in Solidity; to switch chain,
edit `SC/.env`, do not edit `.s.sol`.

## Contents

| File | Role |
|---|---|
| `DeployTimelock.s.sol` | OpenZeppelin `TimelockController` (48h delay, multisig proposer + executor, admin `address(0)`). |
| `DeployDiamond.s.sol` | Diamond proxy, 6 facets, `DiamondInit`, `MarketInit`. Deployer holds every admin role until optional finalize. |
| `DeployAll.s.sol` | End-to-end orchestrator: Timelock → Diamond → Oracles → Hook → Exchange → Router → governance handover. |
| `lib/DiamondDeployLib.sol` | Shared building blocks for the diamond deploy. Consumed by both `DeployDiamond` and `DeployAll`. |
| `../oracle/script/DeployOracles.s.sol` | `ManualOracle` + (optional) `ChainlinkOracle`. |
| `../hook/script/DeployHook.s.sol` | `PrediXHookV2` implementation + CREATE2-salt-mined `PrediXHookProxyV2`. |
| `../exchange/script/DeployExchange.s.sol` | Standalone `PrediXExchange`. |
| `../router/script/DeployRouter.s.sol` | `PrediXRouter` with 9 immutables. |
| `../shared/script/DeployTestUSDC.s.sol` | Testnet-only restricted ERC20 with mainnet USDC metadata. Owner-only mint, transfer-restricted (at least one side must be whitelisted protocol contract). Deploy once per testnet before `DeployAll`. |
| `../shared/script/DeployFaucet.s.sol` | `FaucetRelayedV2` — testnet faucet dispensing USDC + optional ETH. Deploy after `DeployAll`. |
| `../router/script/DeployMarketFactory.s.sol` | `PrediXMarketFactory` — batches market creation + AMM pool in 1 tx. Deploy after `DeployAll`. |
| `PostDeployWiring.s.sol` | Post-deploy wiring: whitelist protocol contracts on TestUSDC, grant CREATOR_ROLE, fund faucet + deployer. |

## Environment setup

1. `cp SC/.env.example SC/.env`
2. Fill every field. The ones that change per chain:
   - `USDC_ADDRESS` — see §Testnet USDC below for testnet, or Circle's canonical address for mainnet
   - `POOL_MANAGER_ADDRESS`
   - `V4_QUOTER_ADDRESS`
   - `CHAINLINK_ENABLED` and, if `true`, `CHAINLINK_SEQUENCER_UPTIME_FEED`
3. `PERMIT2_ADDRESS` is canonical (`0x000000000022D473030F116dDEE9F6B43aC78BA3`) on every chain — the template already has it.
4. Governance keys (`MULTISIG_ADDRESS`, `HOOK_PROXY_ADMIN`, `HOOK_RUNTIME_ADMIN`, `REPORTER_ADDRESS`, `REGISTRAR_ADDRESS`, `FEE_RECIPIENT`) must all be set even for testnet — they are required by `vm.envAddress`.

## Testnet USDC

Circle's public USDC testnet faucets are rate-limited and can't cover a full
end-to-end flow (split 100k + CLOB + AMM + redeem). The repo ships a
testnet-only restricted token at
`packages/shared/script/DeployTestUSDC.s.sol` that matches mainnet USDC
metadata exactly (name `USD Coin`, symbol `USDC`, 6 decimals, EIP-2612
permit). **Only the owner can mint.** Transfers are restricted: at least one
side (sender or receiver) must be a whitelisted protocol contract —
user-to-user transfers are blocked. **Never deploy on mainnet.**

**Step 0 (testnet only):**

```bash
source SC/.env
forge script packages/shared/script/DeployTestUSDC.s.sol:DeployTestUSDC \
    --rpc-url "$UNICHAIN_RPC_PRIMARY" \
    --broadcast
```

Copy the resulting `TestUSDC` address from the broadcast summary and paste
it into `USDC_ADDRESS` in `SC/.env`. Then proceed with `DeployAll`.

On mainnet skip this step entirely and use the real Circle USDC address.

### Unichain RPCs

The `.env.example` keeps `UNICHAIN_RPC_PRIMARY` and `UNICHAIN_RPC_BACKUP` blank on
purpose because the primary RPC is a tenant URL with an access token. Fill it in
locally; never commit the real value.

## Deployment order

### Full testnet flow (6 steps)

```
Step 1: DeployTestUSDC         → USDC_ADDRESS
Step 2: DeployAll              → DIAMOND_ADDRESS, HOOK_PROXY_ADDRESS, EXCHANGE_ADDRESS, ROUTER_ADDRESS, ...
Step 3: Deploy PoolModifyLiquidityTest (forge create) → LP_TEST_ADDRESS
Step 4: DeployFaucet           → FAUCET_ADDRESS
Step 5: DeployMarketFactory    → MARKET_FACTORY_ADDRESS
Step 6: PostDeployWiring       → whitelist, roles, funding
```

After each step, paste emitted addresses into `.env` before running the next step.

**Step 3 — PoolModifyLiquidityTest** is a Uniswap v4 test utility that
`PrediXMarketFactory` uses for LP operations. Deploy it via `forge create`
from the diamond package directory (which has the v4-core remapping):

```bash
cd SC/packages/diamond
forge create \
    @uniswap/v4-core/src/test/PoolModifyLiquidityTest.sol:PoolModifyLiquidityTest \
    --constructor-args $POOL_MANAGER_ADDRESS \
    --rpc-url $RPC_URL \
    --private-key $DEPLOYER_PRIVATE_KEY
```

### Core protocol (DeployAll)

`DeployAll.s.sol` is the canonical path and enforces this order in a single broadcast:

```
Timelock
    └── Diamond (+ 6 facets, DiamondInit, MarketInit)
            └── Oracles (ManualOracle, ChainlinkOracle when enabled)
                    └── approveOracle(...) on diamond
                            └── Hook impl + salt-mined Hook proxy
                                    └── Exchange
                                            └── Router
                                                    └── setTrustedRouter (router + quoter)
                                                            └── transferGovernance (multisig + Timelock)
```

During the middle steps the EOA deployer temporarily holds every admin role on the
diamond so it can wire `MarketInit` via a second `diamondCut` and call
`approveOracle`. The final step (`DiamondDeployLib.transferGovernance`) grants every
role to the multisig, grants `CUT_EXECUTOR_ROLE` to the Timelock, and renounces every
role from the deployer. `DiamondDeployLib.verifyPostDeploy` is called post-broadcast
and **will revert the simulation** if the final role layout is wrong.

### Production (mainnet)

On mainnet, skip Step 1 (use real Circle USDC), Step 3 (use canonical
PositionManager instead of PoolModifyLiquidityTest), and Step 6 (no testnet
wiring needed). Steps 4 and 5 are optional operational helpers.

## Dry-run (required before any live deploy)

```bash
cd SC/packages/diamond
forge script DeployAll \
  --rpc-url $UNICHAIN_RPC_PRIMARY \
  --sender $DEPLOYER_ADDRESS
```

Omitting `--broadcast` runs the script as a simulation against the forked state — no
transactions are submitted. The script prints every contract address and a formatted
summary block at the end.

## Live deploy (manual — never run automatically)

```bash
forge script DeployAll \
  --rpc-url $UNICHAIN_RPC_PRIMARY \
  --sender $DEPLOYER_ADDRESS \
  --broadcast \
  --verify
```

Live deploy must be done by the protocol operator, not by tooling. Hardware wallet is
mandatory for mainnet (`--ledger` plus `--hd-paths`).

## Individual scripts

Each `Deploy<X>.s.sol` can be run independently for iterative testnet work, for
example redeploying only the router when tweaking its constructor params:

```bash
cd SC/packages/router
forge script DeployRouter --rpc-url $UNICHAIN_RPC_PRIMARY --sender $DEPLOYER_ADDRESS
```

Standalone scripts read **all** dependency addresses from env, so populate
`DIAMOND_ADDRESS`, `EXCHANGE_ADDRESS`, `HOOK_PROXY_ADDRESS` (etc.) in `.env` after the
first `DeployAll` run.

`DeployDiamond` has a `DIAMOND_FINALIZE_GOVERNANCE` env flag: leave it `false` for
iterative development so the deployer keeps admin roles, set to `true` for a one-shot
deploy that hands over at the end.

## Chainlink on Unichain Sepolia

Unichain Sepolia (chain id 1301) does not currently expose Chainlink data feeds or an
L2 sequencer uptime feed. Set `CHAINLINK_ENABLED=false` in the testnet `.env` — the
deploy skips `ChainlinkOracle` entirely and the diamond is approved for `ManualOracle`
only. When Chainlink goes live on Unichain mainnet, flip `CHAINLINK_ENABLED=true` and
fill `CHAINLINK_SEQUENCER_UPTIME_FEED` with the official L2 uptime feed address.

`ChainlinkOracle`'s constructor accepts `address(0)` for the sequencer feed as a
first-class design state documented in
`packages/oracle/src/adapters/ChainlinkOracle.sol` lines 24–27.

## Fail-loud guarantees

Every required env var is read via `vm.envAddress` / `vm.envUint` / `vm.envInt` /
`vm.envBool`, which revert if the variable is unset. `vm.envOr` is used only for the
single legitimate optional (sequencer uptime feed). Chain-id branching is not used
anywhere in the scripts.

`DiamondDeployLib.verifyPostDeploy` asserts:
- `multisig` has `DEFAULT_ADMIN_ROLE`, `ADMIN_ROLE`, `OPERATOR_ROLE`, `PAUSER_ROLE`
- `timelock` has `CUT_EXECUTOR_ROLE`
- the `diamondCut`, `createMarket`, and `createEvent` selectors route to the expected
  facet addresses

The CREATE2 hook deploy checks that `address(proxy) & ALL_HOOK_MASK == HOOK_PERMISSION_FLAGS`
and that the proxy address matches `HookMiner.find`'s prediction — either mismatch
reverts the broadcast.

## Post-deploy checklist (manual)

**Phase 4 Part 1 update (backlog #44 closed)**: the router + V4Quoter trust
bindings on the hook are now folded into `DeployAll.run()` directly — no more
manual `setTrustedRouter` operator txs after broadcast. The only remaining
manual step is the incoming hook runtime admin calling `acceptAdmin()` to
complete the two-step rotation proposed during the deploy.

After a live deploy, the protocol operator must:

1. Verify every address on the block explorer.
2. **Hook runtime admin rotation**: the address configured as
   `HOOK_RUNTIME_ADMIN` must call `PrediXHookV2.acceptAdmin()` on the hook
   proxy. `DeployAll.run()` deploys with the deployer as temporary runtime
   admin so `setTrustedRouter` calls can happen inline, then proposes
   rotation via `hook.setAdmin(HOOK_RUNTIME_ADMIN)` at the end. Until the
   new admin accepts, runtime admin rights remain with the deployer EOA.
3. Bind each new pool to the hook proxy via the router's pool creation path.
4. Register Chainlink market configs via `ChainlinkOracle.register(...)` (only on chains where Chainlink is enabled).
5. Confirm `TimelockController.getMinDelay() == TIMELOCK_DELAY_SECONDS`.
6. Confirm the multisig can successfully call `IAccessControlFacet.grantRole` through a dry `safe.txBuilder` simulation.
7. Confirm `HookProxy_TimelockDurationUpdated` event fired with the 48-hour default.
8. Confirm `hook.isTrustedRouter(router) == true` AND `hook.isTrustedRouter(V4_QUOTER_ADDRESS) == true`. These are set automatically by `DeployAll` post-Phase-4-Part-1 — this check is a verification, not an action.

## Tests

`packages/diamond/test/script/DiamondDeployLibTest.t.sol` exercises the full library
end-to-end against `MockUSDC`: facet deploy → diamond constructor → `MarketInit` wiring
→ governance handover → role assertions → facet routing assertions. No RPC required.

Run with:

```bash
cd SC/packages/diamond
forge test --match-path "test/script/*"
```
