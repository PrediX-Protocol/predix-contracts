# hook/test/fork

Narrow fork test that verifies the real Uniswap v4 `PoolManager` on the
target chain exposes the interface the hook compiles against. The goal is to
catch ABI drift between the `v4-core` headers pinned under
`lib/uniswap-hooks/lib/v4-core` (pragma `0.8.26`, interface only) and the
deployed bytecode.

## Required env

```
UNICHAIN_RPC_PRIMARY=https://...
POOL_MANAGER_ADDRESS=0x00B036B58a818B1BC34d502D3fE730Db729e62AC   # Unichain Sepolia v4 PoolManager
```

Missing env fails loud via `vm.envAddress`.

## Run

```bash
cd packages/hook
forge test --match-path 'test/fork/*'
```

## Coverage

- `test_PoolManager_Deployed` — non-empty extcodesize at the configured
  address.
- `test_PoolManager_OwnerReadable` — `owner()` returns a non-zero address.
- `test_PoolManager_GetSlot0_EmptyPool_ReturnsZero` — the `getSlot0`
  ABI matches and returns the zero tuple for an un-initialised key.
- `test_PoolManager_Extsload_AnySlot_DoesNotRevert` — verifies the
  `extsload(bytes32)` off-chain-read ABI is present.

## Deliberately NOT covered

- CREATE2 hook-address mining with `Hooks.validateHookPermissions`. This is
  tied to on-chain CREATE2 pre-computation and is verified indirectly by
  the unit suite against `TestHookHarness`.
- Actual `PoolManager.initialize` + `beforeSwap` round-trip. Requires a
  live mined hook address; running that end-to-end during fork tests is
  possible but the failure modes it catches are already covered by the
  unit suite. Flagged as a future enhancement once Unichain Sepolia has
  a canonical v4 router + periphery deployment stable enough to rely on.
