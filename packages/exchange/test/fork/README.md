# exchange/test/fork

CLOB fork tests with the real canonical USDC deployment. The diamond stays
a local mock because the exchange only interacts with the diamond via
`splitPosition` / `mergePositions` callbacks, and those have no real-chain
state dependency. The point of the fork scope is strictly the ERC-20
transfer path between user, exchange and protocol-deployed outcome tokens.

## Required env

```
UNICHAIN_RPC_PRIMARY=https://...
USDC_ADDRESS=0x31d0220469e10c4E71834a79b1f276d740d3768F
```

## Run

```bash
cd packages/exchange
forge test --match-path 'test/fork/*'
```

## Coverage

- `test_ComplementaryMatch_WithRealUSDC` — alice + bob sell complementary
  legs, exchange synthetically routes into a mint via the mock diamond.
  Asserts balances land correctly with real USDC transfer semantics.
- `test_Solvency_AfterSeedAndCancel` — BUY_YES place + cancel round-trip.
  Asserts exchange holds exactly the locked deposit while resting and
  zero after cancel (strict INV-2 check against real USDC).
