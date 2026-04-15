# PrediX V2 — Smart Contracts

Production-grade prediction market protocol built on Uniswap v4 with a diamond (EIP-2535) core, an on-chain CLOB, and a stateless aggregator router. Target chain: **Unichain** (OP Stack L2, chain IDs `130` mainnet / `1301` Sepolia testnet).

Users trade complementary YES/NO outcome tokens for binary questions (with display-layer support for scalar, multi-outcome, sports, and grouped markets). Settlement is on-chain via a pluggable oracle adapter layer (manual + Chainlink).

## Architecture

```
shared  ← oracle ← diamond ← hook
                          ← exchange
                          ← router ← exchange, hook
```

Each arrow is a one-way dependency. Cross-package imports flow **only** through `@predix/shared/interfaces/`; no package imports another package's implementation. Contracts communicate by address + interface at runtime.

| Package | Purpose |
|---|---|
| [`shared`](packages/shared/) | Interfaces, storage libraries, constants, utilities, `OutcomeToken` ERC20 + Permit |
| [`oracle`](packages/oracle/) | `IOracle` contract + `ManualOracle` (reporter-driven) and `ChainlinkOracle` (round-pinned) adapters |
| [`diamond`](packages/diamond/) | EIP-2535 proxy, market lifecycle facet, event coordinator facet, access control, pausable, upgrade facet |
| [`hook`](packages/hook/) | Uniswap v4 Hook with dynamic-fee pricing, permissionless pool registration, ERC-1967 proxy with 48-hour timelock |
| [`exchange`](packages/exchange/) | On-chain CLOB with complementary-pair matching, dust-safe solvency invariant |
| [`router`](packages/router/) | Stateless aggregator routing CLOB + AMM liquidity, Permit2 integration, revert-and-decode quoting |

### Key design decisions

- **Diamond core holds all collateral.** Every split/merge/redeem/refund path goes through `MarketFacet`. Cross-facet storage namespaced by `keccak256("predix.storage.<module>.v<n>")`.
- **Hook proxy is upgrade-gated** — 48-hour timelock on implementation rotation, two-step admin rotation. Diamond's `diamondCut` is behind a separate `CUT_EXECUTOR_ROLE` held by an OpenZeppelin `TimelockController`.
- **Redemption fee is snapshotted at market creation** — admins cannot retroactively raise the fee on pending redeems. Hard cap `MAX_REDEMPTION_FEE_BPS = 1500` (15%).
- **Reentrancy uses EIP-1153 transient storage** — a single shared `TransientReentrancyGuard` blocks cross-facet reentrancy inside one delegatecall context.
- **Hook caller identity is commit-bound** — `beforeSwap` reverts unless a trusted router committed the user's identity via transient storage in the same transaction. Prevents anti-sandwich bypass.
- **Chainlink oracle reads pinned rounds** — `resolve(marketId, roundIdHint)` rejects any hint whose round boundary does not straddle `snapshotAt`, eliminating the heartbeat-selection MEV window.
- **Manual oracle is diamond-bound + endTime-gated** — a reporter cannot publish an outcome before the market's `endTime`, and `revoke` leaves a tombstone flag so the reporter cannot re-publish an opposite answer.

## Toolchain

- **Foundry** (forge 1.5+, via_ir, optimizer 200, `bytecode_hash = "none"`)
- **Solidity** `0.8.30` exact, EVM `cancun`
- **Uniswap v4** via `v4-core`, `v4-periphery`, and OpenZeppelin `uniswap-hooks`
- **OpenZeppelin Contracts** (ERC20, ERC20Permit, SafeERC20, AccessControl, ERC1967 proxy, TimelockController)
- **Chainlink** (`AggregatorV3Interface`, L2 sequencer uptime feed)

Shared dependencies live under [`lib/`](lib/) as git submodules. Each package has its own `foundry.toml`, `remappings.txt`, and `Makefile`; the monorepo `Makefile` at the root aggregates `build`, `test`, `fmt`, `clean`, and `snapshot` targets.

## Getting started

```bash
git clone --recurse-submodules <repo>
cd predix-contracts

# build every package
make build

# run the full test suite (>590 tests: unit + fuzz + invariant + integration)
make test

# format
make fmt

# per-package work
cd packages/diamond && forge test -vv
```

## Repository layout

```
.
├── lib/                             # forge submodules (forge-std, v4-core, v4-periphery,
│                                    #   uniswap-hooks, openzeppelin-contracts, chainlink)
├── Makefile                         # monorepo build/test aggregator
├── foundry.toml                     # shared defaults (Solidity 0.8.30, via_ir, cancun)
├── .env.example                     # RPC endpoints, deployer key template
└── packages/
    ├── shared/
    │   ├── src/
    │   │   ├── interfaces/          # IDiamondCut, IDiamondLoupe, IAccessControlFacet,
    │   │   │                          IPausableFacet, IMarketFacet, IEventFacet,
    │   │   │                          IPrediXHook, IPrediXHookProxy, IPrediXExchange,
    │   │   │                          IPrediXRouter, IOracle, IOutcomeToken, IERC2612Permit
    │   │   ├── tokens/              # OutcomeToken (ERC20 + EIP-2612)
    │   │   ├── utils/               # TransientReentrancyGuard (EIP-1153)
    │   │   └── constants/           # Roles, Modules
    │   └── test/
    ├── oracle/
    │   ├── src/
    │   │   ├── adapters/            # ManualOracle, ChainlinkOracle
    │   │   └── interfaces/          # IManualOracle, IChainlinkOracle
    │   └── test/
    ├── diamond/
    │   ├── src/
    │   │   ├── proxy/               # Diamond (EIP-2535 proxy)
    │   │   ├── init/                # DiamondInit, MarketInit
    │   │   ├── libraries/           # LibDiamond, LibMarket, LibAccessControl, LibPausable,
    │   │   │                          Lib*Storage (namespaced diamond storage)
    │   │   └── facets/
    │   │       ├── cut/             # DiamondCutFacet (timelock-gated)
    │   │       ├── loupe/           # DiamondLoupeFacet
    │   │       ├── access/          # AccessControlFacet
    │   │       ├── pausable/        # PausableFacet (module-keyed pause)
    │   │       ├── market/          # MarketFacet (create, split, merge, resolve, redeem, refund, sweep)
    │   │       └── event/           # EventFacet (multi-outcome coordinator)
    │   └── test/
    │       ├── unit/
    │       ├── integration/
    │       ├── invariant/
    │       └── repro/               # regression locks for known findings
    ├── hook/
    │   ├── src/
    │   │   ├── hooks/               # PrediXHookV2 (implementation)
    │   │   ├── proxy/               # PrediXHookProxyV2 (ERC1967 + 48h timelock)
    │   │   └── constants/           # FeeTiers
    │   └── test/
    ├── exchange/
    │   ├── src/
    │   │   ├── PrediXExchange.sol
    │   │   ├── ExchangeStorage.sol
    │   │   ├── mixins/              # TakerPath, MakerPath, Views
    │   │   └── libraries/           # MatchMath, PriceBitmap
    │   └── test/
    └── router/
        ├── src/
        │   ├── PrediXRouter.sol
        │   └── interfaces/
        └── test/
```

## Test suite

| Package | Tests | Coverage focus |
|---|---|---|
| `shared` | 11 | OutcomeToken + reentrancy guard primitives |
| `oracle` | 60 | Manual + Chainlink adapters, sequencer uptime, round pinning |
| `diamond` | 252 | Full lifecycle, access control, pause, cut, event coordinator, invariants |
| `hook` | 113 | Dynamic fee, identity commit, permissionless pool binding, proxy upgrade timelock |
| `exchange` | 95 | CLOB matching, dust-safe solvency (4 strict invariants, 128k ops per run) |
| `router` | 65 | Permit2 paths, CLOB + AMM aggregation, non-custody invariant |
| **Total** | **596** | |

Critical invariants covered:

- `INV-1` diamond collateral solvency: `YES.totalSupply == NO.totalSupply == totalCollateral` for unresolved markets
- `INV-2` exchange solvency: `Σ order.depositLocked == USDC.balanceOf(exchange) + Σ outcomeToken.balanceOf(exchange)`
- `INV-3` router non-custody: `balanceOf(router) == 0` after every external call
- `INV-4` redemption fee bound: effective fee always `≤ MAX_REDEMPTION_FEE_BPS`
- `INV-5` hook identity commit: `beforeSwap` reverts without a committed caller identity
- `INV-6` resolution monotonicity: once resolved, outcome and `resolvedAt` are immutable
- `INV-7` outcome token supply bound: only the diamond factory can mint/burn outcome tokens

## Security

This codebase is pending external security audit. Internal review has been performed across all six packages; the `diamond/test/repro/` directory contains regression locks for every verified finding from the internal review so that regressions cannot reintroduce known bugs. Critical invariants are enforced both by Foundry invariant tests and by manual proofs for the three formally verified targets (redemption fee math, CLOB match math overflow, diamond storage slot uniqueness).

Do not deploy this code to mainnet without a passing external audit.

## Environment

Copy `.env.example` to `.env` and fill in the target network's RPC URL and deployer key.

```bash
UNICHAIN_SEPOLIA_RPC=https://sepolia.unichain.org
UNICHAIN_MAINNET_RPC=https://mainnet.unichain.org
DEPLOYER_PRIVATE_KEY=0x...
```

## License

MIT (see `LICENSE`).
