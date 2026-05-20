# Test Taxonomy

**Audience:** engineers, auditors
**Status:** Reference
**Last reviewed:** 2026-05-19

PrediX uses a 5-layer testing strategy. Every code change must clear the
relevant layers before mainnet deployment. This document defines what each
layer covers, where the tests live, and how to run them.

---

## Layer overview

| Layer | Type | Dependencies | Runtime | When |
|---|---|---|---|---|
| **L1** | Unit | None (mocks) | <1 min | Every PR |
| **L2** | Integration | Fresh PrediX stack, no external | <5 min | Every PR |
| **L3** | Fork tests | Mainnet RPC + canonical addrs | <15 min | Per push to develop/master + nightly |
| **L4** | Staging smoke | Live Unichain Sepolia deploy | Manual ~30 min | Before each mainnet candidate |
| **L5** | Mainnet smoke | Live mainnet deploy (paused) | Manual ~1 hour | Immediately post-deploy |

---

## Layer 1 — Unit tests

**Purpose:** Verify single-function logic correctness.

**Location:** `packages/*/test/unit/`, `packages/*/test/*.t.sol` (non-fork)

**Dependencies:** All external contracts mocked via `MockERC20`, `MockOracle`,
`MockDiamond`, etc. No RPC required.

**Runtime:** ~15 minutes total across 7 packages.

**Run locally:**
```bash
make test
# OR per-package
cd packages/diamond && forge test --no-match-path 'test/fork/*' --no-match-path 'test/e2e/*'
```

**CI:** `build-test` job, runs on every PR.

**What it catches:**
- Logic bugs in single functions (math, state transitions, access control).
- Reentrancy via local mocks that exhibit known reentry behavior.
- Invariants that hold even with mocked external dependencies.

**What it does NOT catch:**
- Real USDC behavior quirks (blacklist, no-fee transfer assumptions).
- Real Uniswap V4 PoolManager edge cases (transient storage, exact revert
  messages, callback ordering).
- Real Permit2 EIP-712 signature flow.

---

## Layer 2 — Integration tests

**Purpose:** Cross-facet / cross-package interaction within the PrediX stack.

**Location:** `packages/*/test/integration/`, `packages/diamond/test/integration/`

**Dependencies:** Fresh-deployed PrediX stack via fixtures (`DiamondFixture`,
`MarketFixture`, `EventFixture`, `RouterFixture`). External dependencies
mocked.

**Runtime:** ~30 minutes total.

**Run locally:**
```bash
cd packages/diamond && forge test --match-path 'test/integration/*'
```

**CI:** Same `build-test` job as L1.

**What it catches:**
- Bugs in diamond cut wiring (selector clashes, init data, immutable
  selectors).
- Bugs in cross-facet calls (MarketFacet ↔ EventFacet via shared storage).
- Bugs in cross-package interface usage (Router → Exchange, Hook → Diamond).
- Invariants that hold with the full PrediX stack deployed.

**What it does NOT catch:**
- Behavior differences between mocked and real external contracts.

---

## Layer 3 — Fork tests

**Purpose:** Validate PrediX code against REAL external infrastructure.

**Location:**
- `packages/diamond/test/e2e/` — full-stack integration tests using
  `MainnetForkFixture`.
- `packages/{shared,exchange,hook}/test/fork/` — scope-narrow tests against
  individual canonical contracts.

**Dependencies:**
- Unichain mainnet RPC.
- Canonical contract addresses (USDC, PoolManager, V4Quoter, Permit2).
- A pinned block (for reproducibility).

**Runtime:** ~15 minutes total.

**Required env vars:**
```bash
export UNICHAIN_RPC_PRIMARY=https://mainnet.unichain.org
export UNICHAIN_MAINNET_PIN_BLOCK=$(grep PIN_BLOCK .env.example | cut -d= -f2)
```

Optional (canonical defaults in `MainnetForkFixture.sol`):
```bash
export UNICHAIN_RPC_SECONDARY=...   # Failover RPC
export USDC_ADDRESS=0x078D78...     # Real USDC by Circle
export POOL_MANAGER_ADDRESS=0x1F9840...
export V4_QUOTER_ADDRESS=0x333E3C...
export PERMIT2_ADDRESS=0x000000...22D473
```

**Run locally:**
```bash
make test-fork
# OR per-package
cd packages/diamond && forge test --match-path 'test/e2e/*'
```

**CI:** `fork-tests-mainnet` job, runs on every push to develop/master + non-
draft PRs. `fork-tests-nightly` runs extended invariant campaigns at 02:00 UTC.

**What it catches:**
- Code-vs-real-USDC mismatch (blacklist, transfer fees, decimals quirks).
- Code-vs-real-V4 mismatch (unlock callback flow, swap delta semantics,
  hook permission bit validation).
- Code-vs-real-Quoter mismatch (simulate-revert + identity commit
  interaction).
- Code-vs-real-Permit2 mismatch (EIP-712 domain separator on the actual
  chainId).
- Real gas costs (compared to mocked PoolManager gas).

**What it does NOT catch:**
- Operational issues (multisig procedure, deploy artifacts).
- Real user behavior (UX, slippage, MEV).

**Pin block strategy:**
- Pin block is bumped quarterly (or before each mainnet release) via
  `scripts/bump-pin-block.sh`. Bumping is committed in a PR; CI runs the
  full fork suite against the new pin.
- Pin block = current block - 100 (buffer protects against reorgs).
- The fixture re-validates that all canonical external contracts (USDC,
  PoolManager, Quoter, Permit2) have code at the pin block. If not, setUp
  reverts with an explicit error — never silent.

---

## Layer 4 — Staging smoke

**Purpose:** End-to-end user flow validation by humans on live testnet.

**Location:** `scripts/testnet/`

**Dependencies:** Live Unichain Sepolia deployment (current canonical
deployment per `README.md`).

**Runtime:** Manual ~30 minutes.

**Run locally:**
```bash
./scripts/testnet/smoke-test.sh
```

**CI:** Not automated. Owner manually triggers before each mainnet release
candidate.

**What it catches:**
- Issues only visible with full off-chain stack (frontend, indexer, bot).
- Issues that appear at scale (concurrent trades, queue depths).
- Operational issues (RPC rate limits, gas estimation drift).

---

## Layer 5 — Mainnet smoke

**Purpose:** Verify deployment integrity before unpausing the protocol.

**Location:** Deploy runbook in `docs/MAINNET_DEPLOY_REHEARSAL.md`

**Dependencies:** Live Unichain mainnet deployment, contracts in PAUSED
state initially.

**Runtime:** Manual ~1 hour.

**Procedure:**
1. Deploy PrediX in PAUSED state.
2. Run smoke test against a small test market.
3. Verify all addresses verified on Uniscan.
4. Pass through multi-signer review.
5. Unpause.

**What it catches:**
- Final deployment integrity (bytecode match, address verification).
- Last-mile issues before users interact.

---

## Decision tree: where should a new test go?

```
Is the test exercising a single function with no cross-contract calls?
  → L1 (unit)

Is the test exercising multiple PrediX contracts with mocked external?
  → L2 (integration)

Is the test exercising against real external contracts (USDC, V4, Permit2)?
  → L3 (fork)

Is the test exercising the full off-chain stack (frontend, indexer)?
  → L4 (staging smoke, manual)

Is the test verifying a fresh deploy's bytecode and verification?
  → L5 (mainnet smoke, manual)
```

---

## Migration notes

Earlier fork tests hardcoded staging deployment addresses and pin blocks.
That pattern is superseded by the `MainnetForkFixture`-based suite, which
self-deploys the PrediX stack on every test run and depends only on
canonical external contracts (USDC, PoolManager, Quoter, Permit2).

| Deprecated | Replacement |
|---|---|
| `packages/router/test/fork/PrediXRouter_HookCommit.fork.t.sol` | `packages/diamond/test/e2e/RouterHappyPath_Fork.t.sol` |
| `packages/diamond/test/e2e/E2EForkBase.t.sol` (hardcoded Sepolia) | `packages/diamond/test/utils/MainnetForkFixture.sol` |
| Hardcoded `DIAMOND`, `EXCHANGE`, `HOOK_PROXY` addresses in E2E tests | Self-deployed in fixture |
| `UNICHAIN_SEPOLIA_PIN_BLOCK` env var | `UNICHAIN_MAINNET_PIN_BLOCK` (bumped via script) |

---

## Quick reference: env vars

| Var | Required? | Default | Purpose |
|---|---|---|---|
| `UNICHAIN_RPC_PRIMARY` | Yes for L3+ | none | Primary mainnet RPC |
| `UNICHAIN_MAINNET_PIN_BLOCK` | Yes for L3+ | none | Pin block for L3 reproducibility |
| `UNICHAIN_RPC_SECONDARY` | Optional | none | Failover RPC |
| `USDC_ADDRESS` | Optional | `0x078D78...` | Override for non-canonical test |
| `POOL_MANAGER_ADDRESS` | Optional | `0x1F9840...` | Override |
| `V4_QUOTER_ADDRESS` | Optional | `0x333E3C...` | Override |
| `PERMIT2_ADDRESS` | Optional | `0x000000...22D473` | Override |
