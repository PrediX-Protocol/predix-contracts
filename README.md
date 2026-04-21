# PrediX V2

**A prediction market protocol where a Uniswap v4 AMM and an on-chain CLOB share the same liquidity — aggregated atomically.**

PrediX lets anyone create a market on any future event, backed by USDC, traded with the depth of a Uniswap AMM and the precision of a central limit order book — routed in a single transaction. Live on Unichain Sepolia since 2026-04-17. Mainnet gated on external audit sign-off.

---

## Why PrediX

Prediction markets are the purest price-discovery mechanism humans have ever built. They turn questions about the future — elections, sports, economic indicators, company outcomes — into tradeable probabilities. But today, every major prediction market protocol either runs its order book off-chain, uses a single-venue AMM with shallow liquidity, or locks tokens in non-composable ERC-1155 wrappers that cut them off from the rest of DeFi.

PrediX fixes all three.

| | PrediX V2 | Polymarket (2026) |
|---|---|---|
| **Liquidity venue** | Hybrid CLOB **+** Uniswap v4 AMM, router-aggregated atomically | CLOB only, off-chain order matching |
| **Outcome tokens** | ERC-20 YES/NO (composable with the rest of DeFi) | ERC-1155 Conditional Tokens (Gnosis CTF) |
| **Oracle** | Pluggable: manual + Chainlink (round-pinned, sequencer-aware, MEV-resistant) | UMA optimistic (dispute-based, challenge-window latency) |
| **Trading fee** | Time-decaying dynamic fee (50 bps → 500 bps as expiry nears; protects LPs from informed flow) | Taker fee up to ~1.80% at 50¢ price; 0% maker; 0% on sell orders |
| **Fee on winnings** | Configurable, **snapshotted at market creation** (cannot be raised retroactively), 15% hard cap | 0% on winnings |
| **Anti-MEV** | EIP-1153 transient-storage identity commit + same-block sandwich detector inside the hook | Off-chain sequencing (not on-chain enforced) |
| **Architecture** | EIP-2535 Diamond + ERC1967 hook proxy (modular, upgradeable behind 48h timelocks) | Monolithic contracts |
| **Chain** | Unichain (OP Stack L2) | Polygon |

Composable YES/NO tokens are the unlock. A bet on "Will BTC close above $200k by EOY?" is now an ERC-20 you can **lend, stake, collateralise, or hedge against** — exactly like any other token. That's impossible with conditional-token wrappers, which force every integration to understand an ERC-1155 positionId bitmap.

---

## What the protocol does

### One-line

> Users deposit USDC, receive a pair of YES/NO ERC-20 tokens that redeem 1:1 when the market resolves, and trade those tokens on a hybrid CLOB + AMM aggregator with MEV-resistant pricing.

### User journey

1. **Create** — `MarketFacet.createMarket("Will X happen by date Y?", endTime, oracle)` mints a fresh pair of YES and NO ERC-20 outcome tokens for the market.
2. **Mint positions** — `splitPosition(marketId, usdcAmount)` locks USDC and returns an equal amount of YES and NO. Anyone can do this at any time before `endTime`.
3. **Trade** — the router routes each trade across both venues:
   - **CLOB** first — price-time-priority limit-order book with four-way waterfall matching (direct, synthetic mint, synthetic merge) that preserves the `YES.supply == NO.supply == collateral` invariant by construction.
   - **AMM** for the remainder — a Uniswap v4 pool bound to the market through a custom hook, with a **time-decaying dynamic fee** and **anti-sandwich identity commit**.
4. **Resolve** — any caller triggers `resolveMarket(marketId)`; the market's pre-approved oracle adapter publishes the winning outcome.
5. **Redeem** — `redeem(marketId)` burns both legs, pays the winning leg 1:1 against locked collateral minus a protocol fee (capped at 15%, snapshotted at market creation).

**If the oracle stalls**, admins flip the market into **refund mode** — holders swap their YES+NO back 1:1 to collateral without waiting.

### Market shapes

- **Binary** — "Will X happen by date Y?" — the native primitive.
- **Multi-outcome events** — "US president 2028: Trump / Harris / Other" — `EventFacet.createEvent` atomically spawns N sibling markets sharing an end time, under an exactly-one-winner invariant enforced at resolution.
- **Scalar + sports** — rendered at the display layer by composing multiple binary markets (e.g. "GDP > 3%", "GDP > 4%", "GDP > 5%").

---

## What makes PrediX different

### 1. Hybrid liquidity — deep AMM meets precision CLOB

Most prediction markets pick one side. Polymarket is CLOB-only: great for makers, but liquidity depends on market-maker presence. Augur was AMM-only: always-on, but thin near extremes.

PrediX runs both, atomically. The **stateless aggregator router** queries both venues on every trade:

```
openPosition(usdcIn = 100)
   ├── Try CLOB first — match against resting limit orders at best price
   │      → filled: 60 USDC at $0.42
   ├── Route remainder to AMM (Uniswap v4 pool + hook)
   │      → filled: 40 USDC at $0.43 (dynamic fee applied)
   └── Total fill: 100 USDC → 234.5 YES, single tx, single signature
```

The router holds no funds between calls — `balanceOf(router) == 0` is asserted on every exit path.

### 2. Native Uniswap v4 hook — pricing that understands prediction markets

The `PrediXHookV2` plugs directly into the v4 `PoolManager` and customises three callbacks:

- **`beforeSwap`** — validates that a trusted router committed the user's identity in transient storage (EIP-1153) in the same tx, then flags same-block opposite-direction swaps from the same user as sandwich attempts and reverts. MEV bots can't wrap a user's transaction.
- **`afterSwap`** — applies a **time-decaying dynamic fee**: wide near `endTime` (informed flow is expensive for LPs as outcomes crystallise), tight at market creation (bootstrap cheap liquidity). `FeeTiers` ladders through `FEE_NORMAL → FEE_MEDIUM → FEE_HIGH → FEE_VERY_HIGH` as `timeToExpiry` shrinks.
- **`afterAddLiquidity`** — blocks liquidity provision after a market enters `refundMode` so LPs can't be gamed by last-minute toxic deposits.

Uniswap v4 launched on mainnet in January 2025, and its hook system is being exercised by a rapidly growing ecosystem. PrediX is one of the early prediction-market protocols built natively on that system — the hook is not an external plugin sitting next to an AMM, it **is** the AMM's pricing and safety surface.

### 3. ERC-20 outcome tokens — composable with the entire DeFi stack

Every YES and NO token is a bog-standard ERC-20 with EIP-2612 permit. That means:

- **Lending**: borrow against a YES position on Aave without unwinding.
- **Options & perps**: write a put on your conviction, hedge with a perp.
- **Leverage**: pair YES/NO tokens in a stablecoin-collateralised vault for directional leverage.
- **Structured products**: aggregate multiple binary bets into a single "election basket" ERC-20.
- **Transfers**: send a bet as a gift, splitting across wallets is trivial.

None of this works with Polymarket's ERC-1155 conditional-token wrappers, which need a custom integration for every downstream protocol.

### 4. Pluggable, MEV-resistant oracle adapters

Prediction markets live or die on resolution. PrediX ships **two production adapters** behind a common `IOracle` interface, and any team can author more:

- **`ChainlinkOracle`** — binds a market to a specific Chainlink feed at creation time. On `resolve(marketId, roundIdHint)` the adapter pins the exact round whose boundary straddles `snapshotAt`, **rejects cross-phase round pairs**, and reverts under an L2 sequencer outage. This eliminates the heartbeat-selection MEV window that plagues naive Chainlink integrations, and crosses-checks against a separate sequencer uptime feed with a 1-hour grace period.
- **`ManualOracle`** — reporter-driven. Bound to a specific diamond at construction so a single oracle can't be reused across deployments with colliding market IDs. `report(marketId, outcome)` is gated by `endTime` — a reporter can't pre-publish. `revoke(marketId)` leaves a tombstone flag, preventing a compromised reporter from flipping an outcome after the fact.

### 5. Production-grade security architecture

- **EIP-2535 Diamond core** — six facets (market, event, access, pausable, cut, loupe) behind a single proxy; upgrades flow through an OpenZeppelin `TimelockController` holding `CUT_EXECUTOR_ROLE`, self-administered so `DEFAULT_ADMIN_ROLE` cannot self-grant the upgrade role (NEW-01 fix).
- **Independent hook timelock** — 48-hour delay on `PrediXHookV2` implementation rotation, two-step admin handover, separate key domain from diamond governance.
- **EIP-1153 transient reentrancy guard** — a single cross-facet lock instead of per-contract storage slots. No cross-call state leakage.
- **Module-keyed pause** — the diamond can pause a single module (market, exchange, diamond-cut) without taking down the whole protocol. Cancel-only paths (order cancellation, refund mode) stay open even while paused so user funds are never trapped.
- **Snapshotted redemption fees** — the effective fee on a market is frozen at creation. Admins cannot retroactively raise fees on already-minted positions. Hard cap 15%.

---

## Architecture

```
                       ┌──────────────┐
                       │   Router     │  stateless aggregator, Permit2, zero custody
                       └──────┬───────┘
             ┌────────────────┼────────────────┐
             ▼                ▼                ▼
        ┌────────┐      ┌──────────┐     ┌─────────┐
        │Exchange│      │ v4 Pool  │────▶│  Hook   │  dynamic fee, anti-sandwich
        │ (CLOB) │      │ (v4-core)│     └─────────┘
        └────┬───┘      └─────┬────┘          │
             │                │               │
             └────────┬───────┴───────────────┘
                      ▼
                ┌─────────────┐
                │   Diamond   │  EIP-2535 core
                │  (6 facets) │
                └──────┬──────┘
                       │
              ┌────────┴────────┐
              ▼                 ▼
      ┌──────────────┐   ┌──────────────┐
      │ OutcomeToken │   │    Oracle    │
      │ (ERC20+P)    │   │  Manual or   │
      │ factory-mint │   │  Chainlink   │
      └──────────────┘   └──────────────┘
```

Six independent packages, one-way dependency graph. Contracts communicate by address + interface at runtime — no cross-package inheritance.

| Package | Role |
|---|---|
| [`shared`](packages/shared/) | Common interfaces, `OutcomeToken` (ERC20 + Permit), `TransientReentrancyGuard` (EIP-1153), role & module constants |
| [`oracle`](packages/oracle/) | `ManualOracle` and `ChainlinkOracle` adapters behind `IOracle` |
| [`diamond`](packages/diamond/) | EIP-2535 proxy + market lifecycle facet + event coordinator facet + access/pause/cut facets |
| [`hook`](packages/hook/) | Uniswap v4 hook + ERC1967 proxy with 48h timelock + 2-step admin rotation |
| [`exchange`](packages/exchange/) | On-chain CLOB with 4-way match waterfall + strict solvency invariants |
| [`router`](packages/router/) | Stateless CLOB + AMM aggregator with Permit2 and revert-and-decode quoting |

---

## Live on Unichain Sepolia

Staging deployment of 2026-04-20, block `49799033`. Full E2E flows validated across ~195 live transactions.

| Component | Address |
|---|---|
| Diamond (core) | [`0x7689E9bf4b2107E2Fd0f1DDA940E2f1143434E39`](https://sepolia.uniscan.xyz/address/0x7689E9bf4b2107E2Fd0f1DDA940E2f1143434E39) |
| Exchange (CLOB) | [`0xE425698e1835DA0A6086eEB85137A36275993F41`](https://sepolia.uniscan.xyz/address/0xE425698e1835DA0A6086eEB85137A36275993F41) |
| Hook proxy | [`0x89830AC92Ff936f39C2D11D1fd821c6f977fAAE0`](https://sepolia.uniscan.xyz/address/0x89830AC92Ff936f39C2D11D1fd821c6f977fAAE0) |
| Router (user-facing) | [`0x6698253F38F4A4bbBC4A223309B4E560d83D7ee0`](https://sepolia.uniscan.xyz/address/0x6698253F38F4A4bbBC4A223309B4E560d83D7ee0) |
| Timelock (upgrade governance) | `0x578D2a308BB0aa5d30E6BC08A7975ccA7e88af61` (48h delay) |
| ManualOracle | `0x7887f07AF62CE0a4Cf836136135a61b59c36A9d2` |
| TestUSDC (6-decimals) | `0x2D56777Af1B52034068Af6864741a161dEE613Ac` |

Diamond facet breakdown and external pins (Uniswap v4 `PoolManager`, `V4Quoter`, canonical `Permit2`) are in the environment template and in the on-chain `DiamondLoupeFacet.facets()` view.

**Mainnet (Unichain, chainId 130)**: not yet deployed. Gated on external audit sign-off and governance handover to a multisig.

---

## Quick start

```bash
git clone --recurse-submodules <repo>
cd predix-contracts

# build every package
make build

# run the full suite (unit + fuzz + invariant + integration — no RPC required)
make test

# fork tests against live Unichain Sepolia (requires UNICHAIN_RPC_PRIMARY in env)
make test-fork

# per-package work
cd packages/diamond && forge test -vv
```

### Integrate as a consumer

PrediX is designed to be integrated, not wrapped. The router exposes four exact-in trade primitives — `buyYes`, `sellYes`, `buyNo`, `sellNo` — plus Permit2 variants that pull the input token via an off-chain signature instead of a pre-approved allowance. CLOB + AMM routing happens atomically inside each call; the return tuple reports how much came from each venue.

```solidity
// One-signature buy: spend 100 USDC, get at least 230 YES on market 42.
// Router splits the fill across CLOB and AMM in a single transaction.

IPrediXRouter router = IPrediXRouter(0x6698253F38F4A4bbBC4A223309B4E560d83D7ee0);

(uint256 yesOut, uint256 clobFilled, uint256 ammFilled) = router.buyYesWithPermit({
    marketId:     42,
    usdcIn:       100e6,                     // 100 USDC (6 decimals)
    minYesOut:    230e6,                     // slippage bound (YES is 6 decimals too)
    recipient:    msg.sender,
    maxFills:     5,                         // cap CLOB matches per tx
    deadline:     block.timestamp + 300,
    permitSingle: permitData,                // Permit2 PermitSingle struct
    signature:    permitSig                  // off-chain Permit2 EIP-712 signature
});

// `yesOut` YES tokens are now held by `msg.sender`, composable with everything.
// `clobFilled + ammFilled == yesOut`; unused USDC, if any, is refunded (zero-custody).
```

Non-Permit2 variants (`buyYes`, `sellYes`, `buyNo`, `sellNo`) take the same parameters without the final two permit fields — caller pre-approves the router on the input token. Quote-only views (`quoteBuyYes`, `quoteSellYes`, `quoteBuyNo`, `quoteSellNo`) return `(total, clobPortion, ammPortion)` without executing.

Full interface surface: [`packages/router/src/interfaces/IPrediXRouter.sol`](packages/router/src/interfaces/IPrediXRouter.sol).

---

## Tech stack

- **Foundry** (forge 1.5+), `via_ir = true`, `optimizer_runs = 200`, `bytecode_hash = "none"`
- **Solidity** `0.8.30` pinned, EVM target `cancun` (EIP-1153 transient storage required)
- **Uniswap v4** — `v4-core`, `v4-periphery`, OpenZeppelin `uniswap-hooks`
- **OpenZeppelin Contracts** — ERC20, ERC20Permit, SafeERC20, AccessControl, ERC1967 proxy, TimelockController
- **Chainlink** — `AggregatorV3Interface`, L2 sequencer uptime feed
- **Permit2** — canonical `0x000000000022D473030F116dDEE9F6B43aC78BA3`

All third-party dependencies vendored as git submodules under [`lib/`](lib/).

---

## Security

Prediction markets hold user collateral until resolution, sometimes for months. Security isn't a feature — it's the protocol.

**What we've done:**

- **Internal security review** across all six packages, with per-finding **regression locks** under `packages/*/test/repro/` (20 files). Every High and Medium finding from the review has a dedicated test that fails on the pre-fix code and passes post-fix.
- **691 tests** covering unit, fuzz, invariant, integration, and fork suites. Solvency invariants run at 128,000 ops per invariant per run.
- **~195 live broadcasts** on Unichain Sepolia exercising every happy path, every revert path, reentrancy surface, storage slot invariants (`cast storage`), gas benchmarks, ERC-20 allowance edge cases, and multi-market isolation.
- **Findings status at audit snapshot `audit-v3-20260421`**: **0 Critical open · 0 High open · 2 Medium open** (both griefing-class, no fund-loss, scoped for external review).

**External audit is in progress.** Mainnet deploy is gated on a clean external sign-off.

Full engagement brief for the external auditor is [specs/AUDIT_SPEC.md](specs/AUDIT_SPEC.md).

---

## Roadmap

- **Now** — external audit · Unichain Sepolia live smoke · multisig + timelock handover rehearsal
- **Post-audit** — Unichain mainnet deploy · frontend launch · first liquid markets
- **Q3 2026** — multi-chain expansion (OP Stack chains first) · third-party oracle adapters · composability integrations (Aave listings for active YES/NO markets, perpetual wrappers)
- **Q4 2026** — native multi-outcome event UI · sports vertical · institutional API with Permit2 batching

---

## Repository layout

```
.
├── lib/                  # forge submodules (v4-core, v4-periphery, openzeppelin, chainlink, ...)
├── Makefile              # monorepo build/test aggregator
├── foundry.toml          # shared Solidity 0.8.30 / cancun / via_ir defaults
├── .env.example          # environment template
├── scripts/testnet/      # shell wrappers around Phase 7 bootstrap forge scripts
├── specs/                # protocol & audit specifications
│   └── AUDIT_SPEC.md     # engagement brief for external auditor
└── packages/
    ├── shared/           # interfaces, OutcomeToken, TransientReentrancyGuard, Roles
    ├── oracle/           # ManualOracle, ChainlinkOracle
    ├── diamond/          # EIP-2535 proxy + 6 facets + storage libraries
    ├── hook/             # PrediXHookV2 + ERC1967 proxy with timelock
    ├── exchange/         # CLOB — maker + taker + views mixins, MatchMath, PriceBitmap
    └── router/           # stateless CLOB+AMM aggregator
```

Each package is a self-contained Foundry project with its own `foundry.toml` and test suite. Cross-package imports flow **only** through `@predix/shared/interfaces/`; no package imports another package's implementation.

---

## Contributing

PrediX V2 is in pre-mainnet hardening. Issues and pull requests are welcome — especially around audit-surfaced edge cases, gas micro-optimisations with measurement, and additional oracle adapter implementations. Please open an issue to discuss before large changes.

---

## Links

- **Live deployment**: Unichain Sepolia (chainId 1301) — addresses above
- **Audit snapshot**: tag [`audit-v3-20260421`](releases/tag/audit-v3-20260421) (GitHub releases)
- **Spec**: [`specs/AUDIT_SPEC.md`](specs/AUDIT_SPEC.md)
- **Fork testing guide**: [`FORK_TESTS.md`](FORK_TESTS.md)

---

## License

MIT — see [`LICENSE`](LICENSE).
