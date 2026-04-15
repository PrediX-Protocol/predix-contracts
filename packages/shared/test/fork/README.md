# shared/test/fork

Fork tests against a live chain RPC that verify external-contract assumptions
the protocol relies on: real USDC and the canonical Permit2 deployment.

## Required env

```
UNICHAIN_RPC_PRIMARY=https://...       # any Unichain-Sepolia JSON-RPC endpoint
USDC_ADDRESS=0x...                     # canonical Circle USDC on the target chain
PERMIT2_ADDRESS=0x000000000022D473030F116dDEE9F6B43aC78BA3
```

Unset env vars cause `vm.envAddress` / `vm.envString` to revert — that is the
intended behavior: these tests are off the default run path and must refuse
to fall back to mocks.

## Run

```bash
cd packages/shared
forge test --match-path 'test/fork/*'
```

Or from the repo root:

```bash
make test-fork
```

## Coverage

- `USDCBehaviorForkTest.t.sol` — decimals, symbol, transfer, transferFrom via
  SafeERC20, no fee-on-transfer.
- `Permit2IntegrationForkTest.t.sol` — deployment check, domain separator,
  allowance lifecycle (approve → transferFrom).

The full EIP-712 signed-permit flow is exercised in
`router/test/fork/RouterE2EForkTest.t.sol` where it is load-bearing for the
router entry points; duplicating it here would add no coverage.
