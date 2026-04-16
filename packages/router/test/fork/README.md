# router/test/fork

Fork-based integration tests for `PrediXRouter` against live Unichain Sepolia
state. These tests deploy a fresh router in-process and run it against the
real deployed `PoolManager`, `PrediXHookV2` proxy, `V4Quoter`, `PrediXDiamond`
and `PrediXExchange`, so the router's commit-gate alignment with the hook is
validated end-to-end.

## Running

**Default** — CI and local unit test runs skip the fork suite because the
in-process `forge` environment has no RPC:

```bash
forge test --no-match-path "test/fork/*"
```

**Explicit fork run** — requires two env vars:

```bash
export UNICHAIN_SEPOLIA_RPC="https://..."     # full RPC URL (or use .env)
export UNICHAIN_SEPOLIA_PIN_BLOCK=49446128    # pin block (see §Pin block below)
forge test --match-path "test/fork/*" -vvv
```

Both variables are read via fail-loud `vm.envString` / `vm.envUint` — missing
env reverts `setUp()` with a clear error. No silent fallback.

## Pin block

Fork tests pin to a specific Unichain Sepolia block to isolate them from:

- Sepolia reorgs or chain resets
- Ongoing AMM liquidity + pool state drift from other test activity
- Market creation / resolve events that may change `marketCount` or the
  pool binding

**Current pin block**: `49492445` (captured 2026-04-16 during Phase 5 fresh
deploy). This block contains the Phase 5 market 3 + pool initialization +
liquidity seed + hook trust bindings (router + V4Quoter both trusted via
`DeployAll` canonical pipeline).

**Maintenance**: re-pin annually OR when:

- Unichain Sepolia undergoes a state reset
- The live hook proxy is redeployed (Phase 5 hook upgrade cycle)
- Phase 3 pool 1 liquidity is withdrawn or the pool is re-initialized

To re-pin: pick a new block that contains all required setup state, update
`UNICHAIN_SEPOLIA_PIN_BLOCK` in your local `.env`, and update this README.

## Test matrix — Phase 4 Part 1 regression anchors

All 12 tests are now happy-path assertions (Phase 5 unblocked every path):

### AMM real swap

| Test | Path | Must PASS |
|---|---|---|
| `test_Fork_BuyYes_HappyPath` | router → AMM real swap | ✅ |
| `test_Fork_SellYes_HappyPath` | symmetric | ✅ |

### CLOB-only

| Test | Path | Must PASS |
|---|---|---|
| `test_Fork_BuyYes_ClobOnly_SmallAmount` | CLOB fill only, no AMM spillover | ✅ |
| `test_Fork_SellYes_ClobOnly_SmallAmount` | symmetric | ✅ |
| `test_Fork_BuyNo_ClobOnly_SmallAmount` | virtual-NO via CLOB, no spillover | ✅ |
| `test_Fork_SellNo_ClobOnly_SmallAmount` | symmetric | ✅ |

### Quote paths (Phase 5 — `commitSwapIdentityFor`)

| Test | Path | Must PASS |
|---|---|---|
| `test_Fork_QuoteBuyYes_EndToEnd` | quote returns non-zero output | ✅ |
| `test_Fork_QuoteSellYes_EndToEnd` | symmetric | ✅ |
| `test_Fork_QuoteBuyNo_EndToEnd` | symmetric | ✅ |
| `test_Fork_QuoteSellNo_EndToEnd` | symmetric | ✅ |

### Virtual-NO AMM spillover (Phase 5 — restored compute helpers)

| Test | Path | Must PASS |
|---|---|---|
| `test_Fork_BuyNo_AmmSpillover_EndToEnd` | buyNo with AMM spillover | ✅ |
| `test_Fork_SellNo_AmmSpillover_EndToEnd` | sellNo with AMM spillover | ✅ |

## Historical note

Prior to Phase 4, `packages/router/test/fork/` shipped a placeholder
`RouterE2EForkTest.t.sol.requires-v4-quoter` (still present for reference).
That placeholder was blocked on the V4Quoter deployment address for Unichain
Sepolia — now confirmed as `0x56DCD40A3F2d466F48e7F48bDBE5Cc9B92Ae4472` and
consumed by `PrediXRouter_HookCommit.fork.t.sol`. The placeholder can be
deleted or kept as a doc artifact at the team's discretion.

## Why no in-process real PoolManager

`@uniswap/v4-core/src/PoolManager.sol` pins `pragma solidity 0.8.26;` (exact).
The router package is on `solc_version = "0.8.30"` and cannot import the
PoolManager contract type directly. Attempting an in-process deploy fails
with `Encountered invalid solc version` at compile time. Fork tests side-step
this entirely by calling the already-deployed PoolManager via interface —
interfaces use permissive `^0.8.0` pragma and compile cleanly against 0.8.30.

An alternative pattern — extending `MockPoolManager` to forward `beforeSwap`
calls to the real hook — is tracked as a future CI-hardening task but not
required for Phase 4 Part 1 ship. The fork suite alone provides the full
regression coverage.
