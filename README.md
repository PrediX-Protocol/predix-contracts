# PrediX V2 — Smart Contracts

Production-grade prediction-market protocol combining an **EIP-2535 Diamond core**, a **native Uniswap v4 hook**, and an **on-chain central limit order book** behind a stateless aggregator router. Built for **Unichain** (OP Stack L2, chainId `130` mainnet / `1301` Sepolia testnet).

**Status**: live on Unichain Sepolia since 2026-04-17 (Phase 7 staging). Internal security review completed across six packages with per-finding regression locks. **Pending external audit.** Mainnet deploy is gated on audit sign-off.

---

## 1. What PrediX does

PrediX lets anyone open a binary prediction market ("Will X happen by date Y?") backed by USDC collateral. Each market mints two fungible ERC20s — `YES` and `NO` — that together redeem 1:1 against collateral once the market resolves. Traders exchange those outcome tokens against:

- the **PrediX CLOB** — a maker/taker limit-order book with four-way waterfall matching (direct, synthetic mint, synthetic merge) that preserves `YES.supply == NO.supply == collateral` by construction;
- a **Uniswap v4 pool** bound to the market via a custom hook, with a time-decaying dynamic fee and anti-sandwich identity commit.

A stateless **aggregator router** routes each user trade across both venues with Permit2, guarantees zero custody on the router, and enforces a non-custody invariant on every call.

**Market shapes supported** (all built on the binary YES/NO primitive):
- Binary markets — `MarketFacet.createMarket`.
- Multi-outcome events ("US president 2028: Trump / Harris / Other") — `EventFacet.createEvent` atomically spawns N sibling markets that share an end time and resolve under an exactly-one-winner invariant.
- Scalar and sports markets — rendered at the display layer by composing multiple binary markets.

**Resolution** is oracle-mediated via a pluggable adapter layer:
- `ManualOracle` — reporter-driven with `endTime`-gated publication, revoke-with-tombstone, and a diamond binding at construction.
- `ChainlinkOracle` — Chainlink feed adapter that pins a specific `roundId` straddling the market's `snapshotAt`, rejects cross-phase round pairs, and guards the L2 sequencer uptime feed.

If the oracle never resolves, admins can flip the market into **refund mode**, where holders swap their YES+NO back to collateral at 1:1 without waiting.

---

## 2. Architecture

```
shared  ← oracle ← diamond ← hook
                          ← exchange
                          ← router → exchange, hook, diamond
```

Each arrow is a one-way dependency. Cross-package imports flow **exclusively** through `@predix/shared/interfaces/` (plus a local interface copy where a downstream package must reference upstream types without inheritance). No package imports another package's implementation; contracts communicate by address and interface at runtime.

| Package | Role |
|---|---|
| [`shared`](packages/shared/) | Diamond/oracle interfaces, `OutcomeToken` (ERC20 + EIP-2612 Permit), `TransientReentrancyGuard` (EIP-1153), `Roles`, `Modules` |
| [`oracle`](packages/oracle/) | `ManualOracle` (reporter-driven, diamond-bound, endTime-gated) and `ChainlinkOracle` (round-pinned, sequencer-aware) |
| [`diamond`](packages/diamond/) | EIP-2535 proxy + six facets: `DiamondCut` (timelock-gated), `DiamondLoupe`, `AccessControl`, `Pausable` (module-keyed), `MarketFacet`, `EventFacet` |
| [`hook`](packages/hook/) | Uniswap v4 hook behind an ERC1967 proxy with a 48-hour timelock on implementation rotation, two-step admin rotation, dynamic LP fee, sandwich detection, and permissionless market→pool binding |
| [`exchange`](packages/exchange/) | On-chain CLOB with mixin-composed maker/taker/views, 4-way match waterfall (complementary + synthetic mint + synthetic merge), strict USDC/YES/NO solvency |
| [`router`](packages/router/) | Stateless aggregator — CLOB + AMM routing, Permit2 exact-amount consumption, revert-and-decode quoting, zero-balance invariant |

### Key design decisions

- **Diamond core holds every dollar.** All `splitPosition` / `mergePositions` / `redeem` / `refund` / `sweepUnclaimed` flow through `MarketFacet`. Cross-facet storage is namespaced by `keccak256("predix.storage.<module>.v<n>")` and append-only by convention, enforced by repro tests.
- **Two independent timelocks.** (a) Diamond upgrades go through an OpenZeppelin `TimelockController` that holds `CUT_EXECUTOR_ROLE`; `DEFAULT_ADMIN_ROLE` cannot self-grant it (post-NEW-01 fix — `CUT_EXECUTOR_ROLE` is self-administered). (b) Hook proxy implementation rotations sit behind an independent 48-hour timelock enforced in the proxy itself; the admin key is rotated under a two-step accept-handshake.
- **Redemption fee is snapshotted at market creation.** Admins cannot raise the fee retroactively on pending redeems. Hard cap `MAX_REDEMPTION_FEE_BPS = 1500` (15%), enforced in `LibMarket` and invariant-tested.
- **Reentrancy uses EIP-1153 transient storage.** A single shared `TransientReentrancyGuard` blocks cross-facet reentrancy inside a delegatecall context; no per-contract storage slots and no cross-call state leakage.
- **Hook caller identity is commit-bound.** `beforeSwap` reverts unless a trusted router pre-committed the end-user's identity in transient storage inside the same transaction. Prevents trusted-router identity poisoning and anti-sandwich bypass; the sandwich detector then uses the committed identity (not `msg.sender`) to bucket same-block opposite-direction swaps.
- **Chainlink reads pinned rounds.** `resolve(marketId, roundIdHint)` rejects any hint whose round boundary does not straddle `snapshotAt`, rejects cross-phase round pairs, and reverts under an L2 sequencer outage — eliminating the heartbeat-selection MEV window.
- **Router holds no funds.** `balanceOf(router) == 0` is asserted at the end of every entry function via `_finalizeAndAssertAllZero`. Permit2 consumption is exact-amount (post-NEW-M5 fix) so residual allowances cannot accumulate.
- **Hook does not hold user funds long-term.** Referral credit is emit-only; outcome-token custody is never taken by the hook; the proxy's reentrancy surface is exercised by a 190-broadcast live smoke on Unichain Sepolia.

---

## 3. Live deployment — Unichain Sepolia (chainId 1301)

Staging deployment of 2026-04-20 (block `49799033`). Governance handover to multisig/timelock is **deferred** for staging — the deployer retains admin roles while live-smoke testing completes. Source verified on the Etherscan V2 unified API.

| Component | Address |
|---|---|
| Diamond | [`0x7689E9bf4b2107E2Fd0f1DDA940E2f1143434E39`](https://sepolia.uniscan.xyz/address/0x7689E9bf4b2107E2Fd0f1DDA940E2f1143434E39) |
| ├─ DiamondCut facet | `0xBD5Af6FAdD6B2e3bd5A84B7fD27F34a6Dd0cAc42` |
| ├─ DiamondLoupe facet | `0x61704bdFBC5c0D2995781E7288FDB36C33AC3F31` |
| ├─ AccessControl facet | `0xfBA0e94Bd45aaE8256e42d95f9920267b54E63b2` |
| ├─ Pausable facet | `0x4b025374A920fE11285F5e823Be348F3a04f35A9` |
| ├─ Market facet | `0xDa9e084439c4C6232ad2ceD8AFdbCb06fAd79BE4` |
| └─ Event facet | `0xC28Af5a51424af22eD6d1EF444B1b1Dcd8406822` |
| Exchange (CLOB) | [`0xE425698e1835DA0A6086eEB85137A36275993F41`](https://sepolia.uniscan.xyz/address/0xE425698e1835DA0A6086eEB85137A36275993F41) |
| Hook proxy | [`0x89830AC92Ff936f39C2D11D1fd821c6f977fAAE0`](https://sepolia.uniscan.xyz/address/0x89830AC92Ff936f39C2D11D1fd821c6f977fAAE0) |
| Hook implementation | `0x0dcB4624588316d9a8Dd7868EeFBF07532c29E02` |
| Router | [`0x6698253F38F4A4bbBC4A223309B4E560d83D7ee0`](https://sepolia.uniscan.xyz/address/0x6698253F38F4A4bbBC4A223309B4E560d83D7ee0) |
| TimelockController | `0x578D2a308BB0aa5d30E6BC08A7975ccA7e88af61` (48h delay) |
| ManualOracle | `0x7887f07AF62CE0a4Cf836136135a61b59c36A9d2` |
| TestUSDC (6-decimals) | `0x2D56777Af1B52034068Af6864741a161dEE613Ac` |

**External dependencies (Unichain Sepolia):**

| Dependency | Address |
|---|---|
| Uniswap v4 `PoolManager` | `0x00b036b58a818b1bc34d502d3fe730db729e62ac` |
| Uniswap v4 `Quoter` (V4Quoter) | `0x56dcd40a3f2d466f48e7f48bdbe5cc9b92ae4472` |
| Canonical Permit2 | `0x000000000022D473030F116dDEE9F6B43aC78BA3` |

**Router immutables**: `LP_FEE_FLAG = 0x800000` (Uniswap v4 dynamic-fee flag), `TICK_SPACING = 60`.

### Mainnet (Unichain, chainId 130)

**Not yet deployed.** Mainnet broadcast is gated on completion of the external audit and governance handover to a multisig (`DIAMOND_FINALIZE_GOVERNANCE=true` in deploy parameters).

---

## 4. Toolchain

- **Foundry** (forge 1.5+), `via_ir = true`, `optimizer_runs = 200`, `bytecode_hash = "none"`
- **Solidity** `0.8.30` pinned, EVM target `cancun` (EIP-1153 transient storage required)
- **Uniswap v4** via `v4-core`, `v4-periphery`, and OpenZeppelin `uniswap-hooks`
- **OpenZeppelin Contracts** — ERC20, ERC20Permit, SafeERC20, AccessControl, ERC1967 proxy, TimelockController
- **Chainlink** — `AggregatorV3Interface`, L2 sequencer uptime feed

All third-party dependencies are vendored as git submodules under [`lib/`](lib/). Each package has its own `foundry.toml`, `remappings.txt`, and `Makefile`; the monorepo [`Makefile`](Makefile) aggregates `build`, `test`, `test-fork`, `fmt`, and `clean`.

---

## 5. Getting started

```bash
git clone --recurse-submodules <repo>
cd predix-contracts

# build every package
make build

# unit + fuzz + invariant + integration (no network)
make test

# fork tests against live Unichain Sepolia RPC (requires env, see §7)
make test-fork

# format check across all packages
make fmt

# per-package work
cd packages/diamond && forge test -vv
```

---

## 6. Repository layout

```
.
├── lib/                             # forge submodules (forge-std, v4-core, v4-periphery,
│                                    #   uniswap-hooks, openzeppelin-contracts, chainlink)
├── Makefile                         # monorepo build/test aggregator
├── foundry.toml                     # shared Solidity 0.8.30 / cancun / via_ir defaults
├── .env.example                     # environment template (see §7)
├── scripts/testnet/                 # shell wrappers around Phase 7 bootstrap forge scripts
└── packages/
    ├── shared/
    │   ├── src/
    │   │   ├── interfaces/          # IDiamondCut, IDiamondLoupe, IAccessControlFacet,
    │   │   │                          IPausableFacet, IMarketFacet, IEventFacet,
    │   │   │                          IOracle, IOutcomeToken
    │   │   ├── tokens/              # OutcomeToken (ERC20 + EIP-2612 Permit)
    │   │   ├── utils/               # TransientReentrancyGuard (EIP-1153)
    │   │   └── constants/           # Roles, Modules
    │   └── test/
    ├── oracle/
    │   ├── src/
    │   │   ├── adapters/            # ManualOracle, ChainlinkOracle
    │   │   └── interfaces/          # IManualOracle, IChainlinkOracle
    │   └── test/                    # unit + fork + repro
    ├── diamond/
    │   ├── src/
    │   │   ├── proxy/               # Diamond (EIP-2535 proxy)
    │   │   ├── init/                # DiamondInit, MarketInit
    │   │   ├── libraries/           # LibDiamond, LibMarket, LibAccessControl, LibPausable,
    │   │   │                          Lib*Storage (namespaced append-only diamond storage)
    │   │   └── facets/
    │   │       ├── cut/             # DiamondCutFacet (CUT_EXECUTOR_ROLE + DIAMOND pause gate)
    │   │       ├── loupe/           # DiamondLoupeFacet
    │   │       ├── access/          # AccessControlFacet (OZ AccessControl via diamond storage)
    │   │       ├── pausable/        # PausableFacet (module-keyed + global)
    │   │       ├── market/          # MarketFacet (create/split/merge/resolve/redeem/refund/sweep)
    │   │       └── event/           # EventFacet (multi-outcome coordinator)
    │   ├── script/                  # DeployAll, DeployDiamond, DeployTimelock, Phase7*
    │   └── test/                    # unit + integration + invariant + repro + e2e + fork
    ├── hook/
    │   ├── src/
    │   │   ├── hooks/               # PrediXHookV2 (implementation — beforeSwap/afterSwap/
    │   │   │                          afterAddLiquidity, identity commit, sandwich detection)
    │   │   ├── proxy/               # PrediXHookProxyV2 (ERC1967 + 48h timelock + 2-step admin)
    │   │   ├── interfaces/          # IPrediXHook, IPrediXHookProxy
    │   │   └── constants/           # FeeTiers (dynamic-fee schedule by time-to-expiry)
    │   └── test/
    ├── exchange/
    │   ├── src/
    │   │   ├── PrediXExchange.sol   # public API — placeOrder, fillMarketOrder, cancelOrder
    │   │   ├── ExchangeStorage.sol  # base storage (orders, price bitmaps, diamond/USDC addrs)
    │   │   ├── IPrediXExchange.sol
    │   │   ├── mixins/              # MakerPath, TakerPath, Views (mixin-composed entry points)
    │   │   └── libraries/           # MatchMath, PriceBitmap
    │   └── test/                    # unit + fuzz + invariant + fork + dust repro
    └── router/
        ├── src/
        │   ├── PrediXRouter.sol     # stateless — only immutables, no storage slots
        │   └── interfaces/          # IPrediXRouter, IPrediXExchangeView, IPrediXHookCommit
        ├── script/                  # DeployRouter
        └── test/                    # unit + fork
```

---

## 7. Test suite

| Package | Tests | Focus |
|---|---|---|
| `shared` | **31** | OutcomeToken ERC20/Permit primitives, transient-storage reentrancy guard, USDC + Permit2 behaviour forks |
| `oracle` | **76** | Manual + Chainlink adapters, sequencer uptime, round-phase pinning, diamond binding |
| `diamond` | **272 pass, 5 skipped** | Full lifecycle, access control, module pause, cut-timelock, event coordinator, 4 critical invariants, 7 repro regression locks |
| `hook` | **137** | Dynamic fee, identity commit, sandwich detection, permissionless pool binding, proxy upgrade timelock, 2-step admin rotation |
| `exchange` | **101** | CLOB matching (complementary + synthetic mint/merge), dust filter, 4 strict solvency invariants at 128k ops per run, preview/execute parity |
| `router` | **74** | Permit2 exact-amount path, CLOB + AMM aggregation, virtual-NO flash-sell path, non-custody invariant |
| **Total** | **691** | |

Fork tests (shared, oracle, diamond, exchange, router) are segregated under `test/fork/*` and require live Unichain Sepolia RPC — run via `make test-fork` with env set per [FORK_TESTS.md](FORK_TESTS.md).

### Critical invariants

| ID | Invariant | Location |
|---|---|---|
| INV-1 | `YES.totalSupply == NO.totalSupply == market.totalCollateral` (unresolved markets) | `diamond/test/invariant/MarketInvariant.t.sol` |
| INV-2 | `market.totalCollateral ≤ USDC.balanceOf(diamond)` | `diamond/test/invariant/MarketInvariant.t.sol` |
| INV-3 | Exchange solvency: `Σ order.depositLocked ≤ USDC + YES + NO balances` (three strict variants) | `exchange/test/invariant/PrediXExchangeInvariant.t.sol` |
| INV-4 | Preview/execute parity: `previewFillMarketOrder(...) == fillMarketOrder(...)` tuple | `exchange/test/invariant/PreviewExecuteParity.t.sol` |
| INV-5 | Redemption fee bound: `effectiveFeeBps ≤ MAX_REDEMPTION_FEE_BPS (1500)` | `diamond/test/invariant/RedemptionFeeInvariant.t.sol` |
| INV-6 | Router non-custody: `balanceOf(router) == 0` post-call | enforced in-contract via `_finalizeAndAssertAllZero`, exercised by router unit + fork tests |
| INV-7 | Event coordinator: all children share `endTime`; resolved event has exactly one winner | `diamond/test/invariant/EventInvariant.t.sol` |

Ghost-based regression locks for every verified internal-review finding live under `packages/*/test/repro/` (F-D-01..03, FINAL-H02..H11, NEW-01..M8, E-01..02, H-H01..H03). Regressions that reintroduce a fixed bug fail the corresponding repro test.

---

## 8. Security

### Internal review

Comprehensive internal audit across all six packages is complete. Findings and remediations are recorded in private audit reports ([`audits/`](audits/) — gitignored); the public artefact of each fix is:

1. The code change in a `fix(sc/<pkg>): <summary> [<finding-id>]` commit.
2. A dedicated regression test under `packages/<pkg>/test/repro/<finding-id>_<slug>.t.sol` that fails on the pre-fix code and passes on the post-fix code.

**Findings status (as of 2026-04-21):**

| Severity | Open | Fixed |
|---|---:|---:|
| Critical | 0 | 1 (FINAL-C01) |
| High | 0 | 11 (FINAL-H01..H11, NEW-01 / F-D-01, H-H01..H03) |
| Medium | 2 | ~15 (NEW-M5, NEW-M6, NEW-M8, F-D-02..03, E-01..02, etc.) |
| Low / Info | documented | — |

The two remaining Mediums (NEW-M4 permissionless-register fee/tickSpacing validation; NEW-M7 virtual-NO execution-vs-quote front-run griefing) are scoped for external-audit review.

### Live smoke

**~195 live broadcasts** on Unichain Sepolia against the staging deployment covering happy-path flows, negative-path guards, reentrancy surface, storage-slot invariants under `cast storage`, gas benchmarks, fuzz-style stress, ERC20 allowance edge cases, and multi-market isolation. See audit reports in [`audits/SMOKE_PHASE7_LIVE_*`](audits/).

### External audit

**In progress.** Mainnet deploy is gated on a clean external sign-off. The codebase at the tag `audit-v3-20260421` is the snapshot under review.

---

## 9. Environment

Local development uses the **`testenv.*` convention**: all environment files are named `testenv.local` / `testenv.staging` / `testenv.production` and are gitignored. Framework toolchains (Foundry, etc.) read `.env` / `.env.local`, which is a symlink to the active `testenv.*` file:

```
SC/.env -> SC/testenv.local
```

Copy [`.env.example`](.env.example) to `testenv.local` and fill in the target network's RPC, deployer, and governance role addresses:

```bash
UNICHAIN_RPC_PRIMARY=<primary RPC endpoint>
UNICHAIN_RPC_BACKUP=<backup RPC endpoint>

DEPLOYER_PRIVATE_KEY=0x...
DEPLOYER_ADDRESS=0x...

MULTISIG_ADDRESS=0x...        # DEFAULT_ADMIN_ROLE recipient post-handover
OPERATOR_ADDRESS=0x...        # OPERATOR_ROLE recipient
PAUSER_ADDRESS=0x...          # PAUSER_ROLE recipient
REPORTER_ADDRESS=0x...        # ManualOracle ADMIN_ROLE recipient
FEE_RECIPIENT=0x...           # protocol fee sink

TIMELOCK_DELAY_SECONDS=172800 # 48h — enforced floor in DeployAll

USDC_ADDRESS=0x...
POOL_MANAGER_ADDRESS=0x...    # Uniswap v4 PoolManager on target chain
V4_QUOTER_ADDRESS=0x...       # Uniswap v4 Quoter (V4Quoter)
PERMIT2_ADDRESS=0x000000000022D473030F116dDEE9F6B43aC78BA3
LP_FEE_FLAG=8388608           # 0x800000 — v4 dynamic-fee flag
TICK_SPACING=60
```

**Never** commit the symlinked `.env` / `.env.local` or the `testenv.*` source file to Git — all are gitignored and secrets belong in the operator's local environment only.

---

## 10. Licence

MIT — see [`LICENSE`](LICENSE).
