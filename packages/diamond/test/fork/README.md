# diamond/test/fork

Full market-lifecycle fork tests that deploy the diamond + MarketFacet against
a live chain RPC and drive `createMarket → splitPosition → resolveMarket →
redeem` (and the refund-mode branch) using the **real canonical USDC**
deployment instead of `MockUSDC`. The oracle stays a protocol-internal mock
because the oracle adapters don't need on-chain state.

## Required env

```
UNICHAIN_RPC_PRIMARY=https://...
USDC_ADDRESS=0x31d0220469e10c4E71834a79b1f276d740d3768F   # Unichain Sepolia canonical
```

Both are required — `vm.envString` / `vm.envAddress` revert loudly on missing.

## Run

```bash
cd packages/diamond
forge test --match-path 'test/fork/*' -vv
```

## Coverage

- `test_FullLifecycle_SplitResolveRedeem` — happy path across real USDC.
- `test_RefundMode_WithRealUSDC` — admin refund-mode branch round-trip.
- `test_Gas_SplitPositionAgainstRealUSDC` — gas probe with a soft regression
  ceiling (surfaces drift vs unit-test mock snapshots when the real USDC
  upgrades its storage layout).

## Not covered here

- ChainlinkOracle / ManualOracle — see `packages/oracle/test/fork/README.md`.
- Hook v4 pool registration — see `packages/hook/test/fork/`.
- Router E2E aggregation — see `packages/router/test/fork/`.
