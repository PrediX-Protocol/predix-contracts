# Router Fork Tests

End-to-end router integration tests live in `packages/diamond/test/e2e/`
because the router test suite must deploy the full diamond + hook + exchange
stack, and the `diamond` package is the only package whose remappings include
every PrediX package source.

## Locations

| Suite | Location |
|---|---|
| Router happy-path trades | `packages/diamond/test/e2e/RouterHappyPath_Fork.t.sol` |
| Fork-fixture smoke validation | `packages/diamond/test/e2e/MainnetForkFixture_Smoke.t.sol` |
| Shared self-deploying fixture | `packages/diamond/test/utils/MainnetForkFixture.sol` |

## Running

```bash
export UNICHAIN_RPC_PRIMARY=https://mainnet.unichain.org
export UNICHAIN_MAINNET_PIN_BLOCK=<see .env.example>

cd packages/diamond
forge test --match-path 'test/e2e/*' -vv
```

See [`docs/TEST_TAXONOMY.md`](../../../../docs/TEST_TAXONOMY.md) for the
full layered test strategy and [`docs/MAINNET_DEPLOY_REHEARSAL.md`](../../../../docs/MAINNET_DEPLOY_REHEARSAL.md)
for the pin-block-freeze procedure that precedes each mainnet release.
