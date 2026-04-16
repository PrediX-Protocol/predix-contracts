# Router Redeploy — Unichain Sepolia (2026-04-16)

**Chain**: Unichain Sepolia (1301)
**Justification**: Phase 4 Part 1 narrow fix (backlog #45a) — drop quoter calls from CLOB spot-price helpers to unblock router's real-swap path against the deployed PrediXHookV2 with its FINAL-H06 identity commit gate.

## Addresses

| Contract | Old address | New address |
|---|---|---|
| PrediXRouter | `0x86df43645d1d1ee2e0b5679480a3df4bba8927a3` | `0x526827De2df83cE7150C49b1d3c15D0f96D87b81` |

All other contracts (diamond, hook proxy, exchange, oracles, USDC, Timelock) are **unchanged**. The new router points at the same 9 immutables (poolManager, diamond, usdc, hook, exchange, quoter, permit2, lpFeeFlag, tickSpacing) as the old one — only the bytecode is different.

## Transaction log

| # | Action | Tx hash | Gas | Signer |
|---|---|---|---|---|
| 1 | `new PrediXRouter(...)` deploy | `0x5fa0f0c08de84b9cd16f9f3206d597c1253b3d6df4047831af871697b6067a9e` | ~4,323,410 | deployer |
| 2 | `hook.setTrustedRouter(newRouter, true)` | `0xb3dccf68b8f3f81a0c59db0628b8db1086264185fda8b3f0cdd364f72c742976` | ~53k | operator |
| 3 | `hook.setTrustedRouter(oldRouter, false)` | `0x0fd0b484da419d688b0200a498bbbf43e456739db6b7a10d9946a1ab2f0a6dd7` | ~29k | operator |

## Post-redeploy verification

```
hook.isTrustedRouter(newRouter) = true   ✅
hook.isTrustedRouter(oldRouter) = false  ✅ (revoked — prevents split-brain)
hook.isTrustedRouter(V4Quoter)  = true   ✅ (escape #6 still intact)
```

## Bytecode change summary

The new router bytecode differs from the old in exactly the code-change described by commit `844c85d`:

- **Deleted**: `_ammSpotPriceForBuy`, `_ammSpotPriceForSell`, `_complementPrice` (3 internal helpers that called V4Quoter)
- **Simplified**: `_clobBuyYesLimit` → `return PRICE_PRECISION`, `_clobSellYesLimit` → `return 0`, `_clobBuyNoLimit` → `return PRICE_PRECISION`, `_clobSellNoLimit` → `return 0`
- **Untouched**: `_computeBuyNoMintAmount`, `_computeSellNoMaxCost`, 4 public `quote*` methods, the `_executeAmm*` paths with commit calls at lines 553/618/666/720, constructor, all entry points

## Downstream impact (for main session)

The following systems reference the router address and must be updated separately:

| System | Env var | Action needed |
|---|---|---|
| FE `.env.local` | `NEXT_PUBLIC_ROUTER_ADDRESS` | Update to `0x526827De2df83cE7150C49b1d3c15D0f96D87b81` |
| BE `.env` | `PREDIX_ROUTER_ADDRESS` | Update to `0x526827De2df83cE7150C49b1d3c15D0f96D87b81` |
| INDEXER `.env.local` | Router address (if indexed) | Update; may need re-backfill decision depending on event continuity |
| SC `.env` | `PREDIX_ROUTER_ADDRESS` | Updated locally this session |

## Old router fate

The old router (`0x86df4364...`) remains deployed on chain. Its hook trust has been revoked, so:
- `buyYes`/`sellYes` via old router will revert with `Hook_UntrustedCaller(oldRouter)` — enforced by the hook's `_resolveIdentity`
- Old router has infinite USDC approval to diamond + exchange from its constructor — no fund risk because the router is stateless and the approval only covers transfers FROM the router, which has zero balance
- No need to self-destruct or brick the old contract; revoked trust is sufficient

## References

- Router source fix commit: `844c85d` (Phase 4 Part 1)
- Fork test harness: `packages/router/test/fork/PrediXRouter_HookCommit.fork.t.sol` (12 tests pass against this fix)
- DeployAll canonical fix: `1703476` (folds trust wiring into the deploy pipeline for future deploys)
- Phase 3 report: `SC/audits/TEST_REPORT_PHASE3_POOL_AMM_20260416.md` (documents Finding #1 + #2 that motivated this redeploy)
