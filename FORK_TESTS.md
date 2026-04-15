# SC Fork Tests

Per-package Foundry fork tests that exercise the protocol against **real
external contracts** on a live chain instead of the mocks used in the unit
suite. The goal is to catch drift between what the mocks assume and what
the real dependencies actually do — ERC-20 quirks, Permit2 signature
format, v4 `PoolManager` ABI, Chainlink feed shape.

Fork tests run an in-memory clone of the target chain's state via
`vm.createSelectFork`. Zero gas cost, zero on-chain state change.

## Target chain

Unichain Sepolia (chain id **1301**).

## Research findings

| Dependency | Address | Status | Notes |
|---|---|---|---|
| **USDC** (Circle) | `0x31d0220469e10c4E71834a79b1f276d740d3768F` | ✅ verified | `symbol()="USDC"`, `decimals()=6` |
| **Permit2** | `0x000000000022D473030F116dDEE9F6B43aC78BA3` | ✅ verified | Canonical address, `DOMAIN_SEPARATOR()` non-zero |
| **Uniswap v4 PoolManager** | `0x00B036B58a818B1BC34d502D3fE730Db729e62AC` | ✅ verified | `owner()` non-zero, `getSlot0` / `extsload` ABI match |
| **Uniswap v4 V4Quoter** | — | ❌ not confirmed | Router E2E fork test shipped as placeholder |
| **Chainlink feeds** | — | ❌ not deployed | ChainlinkOracle fork test shipped as placeholder |

## Coverage matrix

| Package | Fork tests | Real deps used | Skipped tests |
|---|---|---|---|
| `shared` | 10 (USDC 5 + Permit2 5) | USDC, Permit2 | — |
| `oracle` | 0 | — | ChainlinkOracle (no Chainlink on Sepolia) |
| `diamond` | 3 | USDC | — |
| `hook` | 4 | Uniswap v4 PoolManager (interface only) | Full pool register + swap (requires CREATE2 hook-address mining) |
| `exchange` | 2 | USDC | — |
| `router` | 0 | — | E2E (V4Quoter not confirmed on Sepolia) |
| **Total** | **19** | | 3 placeholder skip files |

## Required env vars

Set in the shell before running `make test-fork`:

```bash
export UNICHAIN_RPC_PRIMARY="https://<your-rpc-endpoint>"

# Chain-specific addresses
export USDC_ADDRESS=0x31d0220469e10c4E71834a79b1f276d740d3768F
export PERMIT2_ADDRESS=0x000000000022D473030F116dDEE9F6B43aC78BA3
export POOL_MANAGER_ADDRESS=0x00B036B58a818B1BC34d502D3fE730Db729e62AC
```

**Sensitive values** (RPC tokens, private keys) stay in the shell. Do NOT
commit them — `.env.example` is a template with all values blank.

Missing env vars cause `vm.envAddress` / `vm.envString` to revert loudly.
That is the intended behavior: fork tests are off the default path and
must refuse to fall back to mocks on bad configuration.

## Run

```bash
cd SC

# All packages (iterates like `make test`)
make test-fork

# Single package
cd packages/shared
forge test --match-path 'test/fork/*' -vv
```

## Skip files

Two placeholder files explain what is intentionally NOT tested and carry
a re-enablement checklist:

- `packages/oracle/test/fork/ChainlinkOracleForkTest.t.sol.no-chainlink-on-sepolia`
- `packages/router/test/fork/RouterE2EForkTest.t.sol.requires-v4-quoter`

Both use a file suffix that forge ignores at compile time so the rationale
lives in git without breaking the build.

## CI integration

Fork tests are deliberately **not** part of the default `make test` target
because (a) CI RPC rate limits are flaky and (b) they duplicate coverage
that the unit suite already provides for the happy path. Recommended usage:

- Developers run `make test-fork` locally after every dependency bump
  (OZ, v4-core, permit2).
- Release workflow runs `make test-fork` once against a paid RPC endpoint
  before each tagged release.

## Known limitations

- **Hook E2E against real v4 PoolManager**: requires on-chain CREATE2
  address mining (`HookMiner`) to place `PrediXHookV2` at an address whose
  low bits match the permissions flag. The current fork scope for the hook
  is narrowed to interface-ABI verification; the full register + swap
  round-trip stays covered by the unit suite against `TestHookHarness`
  until Unichain Sepolia has a stable v4 router + periphery deployment
  worth pinning against.
- **Router E2E**: blocked on V4Quoter address confirmation (see
  `packages/router/test/fork/README.md`).
- **Chainlink**: blocked on feed availability on Unichain Sepolia (see
  `packages/oracle/test/fork/README.md`).
