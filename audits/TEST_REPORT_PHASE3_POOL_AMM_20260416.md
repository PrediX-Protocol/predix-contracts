# PrediX V2 — Phase 3 Pool Init + Router AMM Execution Report

**Date**: 2026-04-16
**Chain**: Unichain Sepolia (1301)
**Plan reference**: [TEST_PLAN_UNICHAIN_SEPOLIA_20260415.md](TEST_PLAN_UNICHAIN_SEPOLIA_20260415.md) §6.I (Group RT) + §11 (pool init recipe)
**Prior phase**: [TEST_REPORT_UNICHAIN_SEPOLIA_20260415.md](TEST_REPORT_UNICHAIN_SEPOLIA_20260415.md) (Phase 2, 22/24 pass)
**Outcome**: **PARTIAL PASS with BLOCKERS** — prerequisite wiring and pool init both succeeded; Group RT execution halted at RT-on-02 after discovering two critical router/hook integration bugs (Findings #1 and #2) that collapse the entire router-swap path on chain.
**Scripts**: `scripts/testnet/80_phase3_pool.sh` (idempotent setup + wiring, reproducible)

## 1. Executive summary

| Metric | Value |
|---|---|
| Prerequisite wiring | ✅ 2/2 escapes applied (router + V4Quoter trust) |
| AMM test market created | ✅ market #19 (primary) + #20 (idempotency-test re-run) |
| Pool initialized | ✅ pool ID `0x5d163bd700b68c82fe36f7f0c7f6cca547b29d78bd6fa419cd05200a0fac09fd` (market 19) |
| Liquidity seeded | ✅ L = 18,700,000,000 @ range [-7080, -6780] around tick -6932 |
| Group RT cases attempted | 2/8 (RT-on-01 quote, RT-on-02 real buy) |
| Group RT cases passed | **0/8** |
| Group RT cases blocked | **8/8** by Finding #2 |
| Deployer ETH | 0.50234 → ~0.48 (~20 mETH spent incl. Phase 3 re-run cost) |
| Wall clock | ~60 min (incl. halt + debug + reporting) |
| Findings | 2 critical protocol-level bugs + 1 test-harness gap |

**Verdict**: ❌ **Phase 3 HALTED** — not a test failure, an integration bug discovery. Group RT cannot run on the deployed router until Phase 4 router source patches land. Pool init + liquidity seed are permanent testnet artifacts usable by any future Phase 3.5 re-run once the router is fixed.

## 2. Prerequisite wiring (§Out-of-band deploy pipeline gaps)

Two governance fixes were required before Phase 3 could even attempt Group RT. Both were approved by main session before broadcast, both match the "missing post-deploy binding" pattern, both are 1-tx operator-signed no-security-risk fixes. **These must be folded into `DeployAll.s.sol` as a permanent deploy-pipeline fix** — tracked as backlog #44 (deploy script escapes #5 and #6).

### §Prerequisite wiring

#### Escape #5 — hook.setTrustedRouter(router, true)

- **Why**: `PrediXHookV2._resolveIdentity` (line 561) reverts with `Hook_UntrustedCaller(sender)` unless the caller is in `_trustedRouters`. At deploy time neither `DeployAll.s.sol` nor `DeployHook.s.sol` calls `setTrustedRouter` for the deployed router, so every swap attempt through the router reverts before reaching the commit-identity check.
- **Before**: `hook.isTrustedRouter(router) = false`
- **After**: `hook.isTrustedRouter(router) = true`
- **Tx**: `0xad5cd6aba5e1c824592d8a50653afd89ddb439668f09e1dd9c9524c7eaab0ac8`
- **Gas**: 53,422
- **Signer**: operator EOA `0x0eC2bFb36BB59C736d7b770eacaFAa43a184De34` (hook admin)

#### Escape #6 — hook.setTrustedRouter(V4Quoter, true)

- **Why**: The v4-periphery `V4Quoter` uses a simulate-and-revert pattern — it calls `PoolManager.swap` inside a callback and reverts with the result. The hook sees `V4Quoter` as `sender` during simulation and rejects it as untrusted. Quotes (and, as Finding #2 revealed, every spot-price helper inside the router) cannot simulate without quoter trust.
- **Before**: `hook.isTrustedRouter(V4Quoter) = false`
- **After**: `hook.isTrustedRouter(V4Quoter) = true`
- **Tx**: `0xbae9283cd22846f91cae7213ece28670eb2cc4ad1f539538c2eff34453007e9b`
- **Gas**: 53,422
- **Signer**: operator EOA (hook admin)
- **Security**: V4Quoter uses simulate-and-revert — every swap it triggers is rolled back by the PoolManager before state commits. Trusting it unlocks only the simulation path; it cannot execute a real swap.

#### Backlog item #44 — canonical deploy pipeline fix

`DeployAll.s.sol` should call, after router deployment and before governance handover:

```solidity
hook.setTrustedRouter(address(router), true);
hook.setTrustedRouter(V4Quoter_ADDR, true);
```

Not applied in Phase 3 per scope discipline (contract source + deploy scripts are out of scope for a test execution task). Tracked separately.

## 3. Pool init flow — all steps succeeded

Reproducible via `bash scripts/testnet/80_phase3_pool.sh` from a pristine `/tmp/predix_phase3_state.json` state.

| # | Step | Tx | Gas | Signer |
|---|---|---|---|---|
| 1 | `createMarket("AMM smoke test — YES if PrediX v4 pool init succeeds", now+86400, ManualOracle)` — market 19 (deployer is also the creator for this AMM artifact) | `0xe71557517620…084da` | — | deployer |
| 2 | `hook.registerMarketPool(19, poolKey)` | `0x4635a01b98f5…9f19` | **122,235** | deployer (permissionless) |
| 3 | `PoolManager.initialize(poolKey, sqrtPriceX96=56022770974786143748341366784)` — sqrt(0.5)·2^96, targets yesPrice = $0.50 | `0xf3ff33d2990e…6fde5` | **67,083** | deployer |
| 4 | `usdc.approve(diamond, 200e6)` | `0x77e0b5a1369e…1152` | — | deployer |
| 5 | `diamond.splitPosition(19, 200e6)` → 200 YES + 200 NO | `0xd59e6cc80df2…4d923` | — | deployer |
| 6 | `yes.approve(PoolModifyLiquidityTest, 200e6)` | `0xf3dffded2e45…50df` | — | deployer |
| 7 | `usdc.approve(PoolModifyLiquidityTest, 200e6)` | `0x2d9ab26611b6…3668` | — | deployer |
| 8 | `PoolModifyLiquidityTest.modifyLiquidity(poolKey, (-7080, -6780, 18_700_000_000, 0x0), 0x)` — 200 YES + ~98 USDC consumed | `0x149427e41fd8…6853` | **339,507** | deployer |

### Pool state verification via StateView (`0xc199f1072a74d4e905aba1a84d9a45e2546b6222`)

```
getSlot0(poolId)   → sqrtPriceX96 = 56022770974786143748341366784 (= sqrt(0.5)·2^96)
                     tick = -6932 (= price 0.5)
                     protocolFee = 0, lpFee = 0 (dynamic, hook-controlled)
getLiquidity(poolId) → 18,700,000,000 (active, since range brackets current tick)
```

Pool ID `0x5d163bd700b68c82fe36f7f0c7f6cca547b29d78bd6fa419cd05200a0fac09fd` is a permanent testnet artifact. It remains initialized with seeded liquidity and can be consumed by any future Phase 3.5 re-run once the router is patched.

### Token ordering

Market 19's `yesToken = 0x05e46C0Ea291C059a9E1cFB001B5d92DC55D68aa` is numerically **less than** `USDC = 0x2D56777Af1B52034068Af6864741a161dEE613Ac`, so `yesIsCurrency0 = true`. This matters for `_sqrtPriceToYesPrice` and the sqrtPriceX96 calculation — sqrt(0.5)·2^96 gives YES price = $0.50 in the yesIsCurrency0 orientation. The hook's `_INIT_PRICE_MIN/MAX = [475_000, 525_000]` range validated the init successfully at exactly 500_000 (=$0.50).

### Idempotency retest — market 20

`80_phase3_pool.sh` was re-run with a fresh `/tmp/predix_phase3_state.json` to validate reproducibility. It created market 20 (`yesToken = 0x55b8BC6A0364602b253f7EEC1083a01100966Ff9`), which is **numerically greater than** USDC (so `yesIsCurrency1 = true` in that pool). The script computed sqrtPriceX96 = sqrt(2)·2^96 = 112045541949572287496682733568 correctly, initialized pool `0x8a6f18cbc7d45f564880f9f5089a0c2e96fc8e0bb5b4b515f94d2356a2fb4152`, current tick = 6931. **Known script limitation**: the hardcoded liquidity range [-7080, -6780] is only correct for yesIsCurrency0 pools (market 19 shape). For market 20 (yesIsCurrency1, tick ≈ +6931) the hardcoded range is entirely below the current tick, so `modifyLiquidity` returned success but placed zero active liquidity (`getLiquidity(pool20) = 0`). Market 19 remains the canonical pool with real liquidity for any Phase 3.5 resume. A future script iteration should compute tick range from the current tick dynamically.

## 4. Group RT execution — halted at RT-on-02

### RT-on-01 — `router.quoteBuyYes(19, 10e6, 5)` — ❌ FAIL (Finding #1)

```
cast call router quoteBuyYes(19, 10000000, 5)
  → revert: UnexpectedRevertBytes(WrappedError(hook, HookCallFailed, ..., Hook_MissingRouterCommit()))
```

### RT-on-02 — `router.buyYes(19, 10e6, 0, deployer, 5, deadline)` — ❌ FAIL (Finding #2 — root cause)

```
cast send router buyYes(19, 10000000, 0, deployer, 5, deadline)
  → approval OK
  → gas-estimation revert: UnexpectedRevertBytes(WrappedError(hook, HookCallFailed, ..., Hook_MissingRouterCommit()))
```

No transaction was broadcast for RT-on-02 (revert at `eth_estimateGas`), so **zero gas** was spent on this failed case. `router.buyYes`'s internal call path:

```
buyYes
 └─ _buyYesExecute
     ├─ _clobBuyYesLimit(yesToken)
     │   └─ _ammSpotPriceForBuy(yesToken)
     │       └─ quoter.quoteExactInputSingle(...)          ← reverts here
     │           └─ V4Quoter (simulate-and-revert)
     │               └─ PoolManager.swap
     │                   └─ hook.beforeSwap
     │                       └─ _resolveIdentity(V4Quoter, poolId)
     │                           ├─ _trustedRouters[V4Quoter] = true   (escape #6 OK)
     │                           └─ _commitSlot(V4Quoter, poolId) = 0  ❌
     │                               → revert Hook_MissingRouterCommit()
     └─ _executeAmmBuyYes  (never reached, despite correctly committing identity at line 553)
```

### RT-on-03..08 — ❌ BLOCKED (same root cause)

Not attempted — confirmed mechanically reachable via source inspection. All of them hit the same `_ammSpotPrice*` quoter calls before any real swap path.

| Case | Plan scenario | Status | Reason |
|---|---|---|---|
| RT-on-01 | `quoteBuyYes` preview | ❌ | Finding #1 — direct quoter call without pre-commit |
| RT-on-02 | `buyYes` real swap | ❌ | Finding #2 — `_clobBuyYesLimit → _ammSpotPriceForBuy → quoter` reverts before `_executeAmmBuyYes` commits identity |
| RT-on-03 | `sellYes` real swap | 🚫 blocked | Same path via `_clobSellYesLimit → _ammSpotPriceForSell → quoter` |
| RT-on-04 | slippageBps = 0 strict | 🚫 blocked | Depends on RT-on-02 executing |
| RT-on-05 | price-impact revert | 🚫 blocked | Depends on RT-on-02 executing |
| RT-on-06 | hook pause gates swap | 🚫 blocked | Depends on RT-on-02 executing |
| RT-on-07 | `balanceOf(router) == 0` post-swap (C03) | 🚫 blocked | Depends on RT-on-02..03 executing |
| RT-on-08 | Sequential swaps, fee recalculation | 🚫 blocked | Depends on RT-on-02 executing |

## 5. Findings

### Finding #1 — Router quote path incompatible with hook commit gate

| Attribute | Value |
|---|---|
| **Severity** | Critical for FE preview UX, blocking for Phase 3 quote coverage |
| **Detected** | 2026-04-16 RT-on-01 execution |
| **Revert** | `Hook_MissingRouterCommit()` selector `0x9227ffd8` |
| **Root cause** | `PrediXRouter.quoteBuyYes` (line 309-332) forwards to `V4Quoter.quoteExactInputSingle` without first calling `hook.commitSwapIdentity(msg.sender, poolId)`. During simulation the hook's FINAL-H06 commit gate fires and reverts. |
| **Affected functions** | `quoteBuyYes`, `quoteSellYes`, `quoteBuyNo`, `quoteSellNo` |
| **FE workaround** | Use `Exchange.previewFillMarketOrder` (CLOB-only, no AMM component) OR compute price client-side from `StateView.getSlot0` + tick math (approximate). |

### Finding #2 — Router real-swap spot-price helpers ALSO go through V4Quoter (root cause, wider blast radius)

| Attribute | Value |
|---|---|
| **Severity** | **Critical, production-blocking** — the entire router swap path is unusable against the deployed hook |
| **Detected** | 2026-04-16 RT-on-02 execution (after initial Finding #1 analysis was revised) |
| **Revert** | Same `Hook_MissingRouterCommit()` via `UnexpectedRevertBytes(WrappedError(hook, HookCallFailed, …))` bubble chain |
| **Root cause** | Four internal helpers in `PrediXRouter` all call `IV4Quoter.quoteExactInputSingle/quoteExactOutputSingle` without first committing identity to the hook. Each one is reachable from the `_buyYesExecute`/`_sellYesExecute`/`_buyNoExecute`/`_sellNoExecute` real-swap path via the CLOB price-cap computation (`_clobBuyYesLimit`, `_clobSellYesLimit`, `_clobBuyNoLimit`, `_clobSellNoLimit`). |

#### §Scope — affected helpers and entry points

| Helper | Source | Used by |
|---|---|---|
| `_ammSpotPriceForBuy(yesToken)` | [PrediXRouter.sol:765-773](packages/router/src/PrediXRouter.sol#L765) | `_clobBuyYesLimit` → `_buyYesExecute` (called from `buyYes`, `buyYesWithPermit`, `quoteBuyYes`); also `_clobSellNoLimit` → `_sellNoExecute` |
| `_ammSpotPriceForSell(yesToken)` | [PrediXRouter.sol:776-782](packages/router/src/PrediXRouter.sol#L776) | `_clobSellYesLimit` → `_sellYesExecute` (called from `sellYes`, `sellYesWithPermit`, `quoteSellYes`); also `_clobBuyNoLimit` → `_buyNoExecute` |
| `_computeBuyNoMintAmount(yesToken, usdcIn)` | [PrediXRouter.sol:822-837](packages/router/src/PrediXRouter.sol#L822) | `_buyNoExecute` (called from `buyNo`, `buyNoWithPermit`, `quoteBuyNo`) |
| `_computeSellNoMaxCost(yesToken, noIn)` | [PrediXRouter.sol:840-849](packages/router/src/PrediXRouter.sol#L840) | `_sellNoExecute` (called from `sellNo`, `sellNoWithPermit`, `quoteSellNo`) |

**Reachability map — every router entry point → at least one uncommitted quoter call:**

| Entry point | First-reached quoter helper |
|---|---|
| `buyYes` / `buyYesWithPermit` | `_ammSpotPriceForBuy` |
| `sellYes` / `sellYesWithPermit` | `_ammSpotPriceForSell` |
| `buyNo` / `buyNoWithPermit` | `_ammSpotPriceForSell` (via `_clobBuyNoLimit`), then `_computeBuyNoMintAmount` |
| `sellNo` / `sellNoWithPermit` | `_ammSpotPriceForBuy` (via `_clobSellNoLimit`), then `_computeSellNoMaxCost` |
| `quoteBuyYes` | `quoter.quoteExactInputSingle` direct |
| `quoteSellYes` | `quoter.quoteExactInputSingle` direct |
| `quoteBuyNo` | `quoter.quoteExactInputSingle` direct |
| `quoteSellNo` | `quoter.quoteExactOutputSingle` direct |

**Net**: Against the deployed `PrediXHookV2`, the deployed `PrediXRouter` cannot execute any buy/sell/quote. The hook's `_resolveIdentity` (line 560-565) is a hard gate and correctly enforces FINAL-H06 — the bug is 100% on the router side.

#### §Test harness gap

The existing Foundry router test suite (`packages/router/test/unit/PrediXRouter_*.t.sol`) passes because it constructs a **mock** `PoolManager` and either (a) skips the hook entirely or (b) uses a no-op hook mock. The real `PrediXHookV2` with its identity-commit gate is never plumbed into the unit test harness, so the router → quoter → PoolManager → hook.beforeSwap → `_resolveIdentity` chain is never exercised under the real commit constraint.

**Recommendation for the Phase 4 fix PR**: Add a new test file `packages/router/test/integration/PrediXRouter_HookCommit.t.sol` that:
1. Deploys real `PrediXHookV2` implementation + proxy via the canonical CREATE2-mining path used in `DeployHook.s.sol`
2. Deploys a real `PoolManager` instance (not a mock)
3. Calls `hook.setTrustedRouter(router, true)` + `hook.setTrustedRouter(quoter, true)` (exercising what escape #5/#6 do on chain)
4. Runs `router.buyYes(marketId, usdcIn, minOut, recipient, maxFills, deadline)` end-to-end against the real hook
5. Asserts the call succeeds with real deltas

Any router source change must pass this integration test, not just the existing unit tests. The absence of such a test is the reason both findings went undetected until live Unichain Sepolia execution.

#### §Phase 4 blocker

The fix direction (**do not apply in Phase 3 — out of scope**) is straightforward but requires a router redeploy:

1. **Router source change**: every `_ammSpotPrice*` / `_compute*` helper should pre-commit identity before calling the quoter. The router is already a trusted caller (escape #5), so `hook.commitSwapIdentity(msg.sender, poolId)` will succeed and be visible in transient storage for the duration of the same transaction, including inside the simulate-and-revert quoter frames. Repeat the same pattern in the 4 public `quote*` methods.
2. **Integration test coverage**: add the Foundry integration test described in §Test harness gap.
3. **Redeploy router** with the fixed source, update `.env` + all downstream references (FE, BE indexer, docs), re-run Phase 3 against the new router address.
4. **Fold escapes #5 + #6 into the canonical deploy pipeline** (backlog #44): `DeployAll.s.sol` should call `setTrustedRouter(router, true)` and `setTrustedRouter(V4Quoter, true)` as part of the post-deploy wiring before governance handover.

**Phase 4 scope estimate**: ~4-8h for the fix (router patch + integration test + redeploy script diff + rerun). Not attempted in this Phase 3 task per scope discipline (contract source + deploy scripts off-limits for a test execution task).

## 6. State after Phase 3

| Quantity | Value |
|---|---|
| `marketCount` (Phase 2 end: 18) | **20** (markets 19 and 20 added) |
| Market 19 | AMM smoke test primary (yesIsCurrency0, fully seeded pool, 200 YES + ~98 USDC LP) |
| Market 20 | AMM idempotency re-run (yesIsCurrency1, pool initialized but zero active liquidity due to known script range limitation — see §3 idempotency retest) |
| Pool 1 (`0x5d163bd7…fd`) | initialized, seeded, ready for Phase 3.5 resume once router is patched |
| Pool 2 (`0x8a6f18cb…52`) | initialized, 0 liquidity — harmless testnet artifact |
| Hook trusted routers | `PrediXRouter` + `V4Quoter` (both granted this session) |
| Hook paused | `false` |
| Operator admin roles | unchanged (DEFAULT_ADMIN, ADMIN, OPERATOR, PAUSER on diamond + DEFAULT_ADMIN on ManualOracle + hook runtime admin + hook proxy admin) |
| Deployer admin roles | unchanged (none) |
| Diamond fees | unchanged (marketCreationFee=0, defaultRedemptionFeeBps=0) |
| Deployer ETH | ~0.48 ETH remaining (from 0.50234 start — ~20 mETH spent on Phase 3 wallet funding + market creation + pool init + liquidity seed + re-run) |
| Operator ETH | ~0.04487 ETH (two governance txs, ~107 µETH total) |

## 7. Findings summary vs. Phase 2 findings

Phase 2 also discovered design/documentation gaps (e.g., `refund` being gated by MARKET pause contrary to the `test_EnableRefundMode_BypassesPause` Foundry-test name). Phase 3's findings are **fundamentally different**:

| Phase | Finding class | Severity |
|---|---|---|
| Phase 2 | Documentation/assumption corrections — contracts are correct, plan doc was wrong | info / nice-to-have |
| Phase 3 Finding #1 | Router quote path bug — preview UX broken, workaround available | critical for FE, non-blocking for core |
| Phase 3 Finding #2 | **Router entire swap path bug — no user can buy/sell via router on chain** | **blocking, production-critical** |
| Phase 3 (both) | Test harness gap — router unit tests mock the hook, miss integration bugs | critical process gap |

Phase 3 caught **exactly the kind of bug the audit firm will ask about**: a discrepancy between the deployed hook's design invariant (FINAL-H06 identity commit) and the router's implementation that only a real on-chain integration test could surface.

## 8. Out of scope (not touched in Phase 3)

- ❌ Router source code (`packages/router/src/PrediXRouter.sol`) — Phase 4 fix scope
- ❌ Hook source code (`packages/hook/src/hooks/PrediXHookV2.sol`) — design is correct, no change needed
- ❌ Deploy scripts (`packages/*/script/`) — backlog #44 fix scope
- ❌ New Foundry integration tests — recommended in §5 but deferred to the fix PR
- ❌ Router redeploy — Phase 4 scope
- ❌ BE, INDEXER, FE subtrees

## 9. Backlog items emitted by Phase 3

1. **Backlog #44** — Deploy pipeline fix: `DeployAll.s.sol` should call `hook.setTrustedRouter(router, true)` + `hook.setTrustedRouter(V4Quoter, true)` after router deploy, before governance handover. Canonical fix for escapes #5 and #6.
2. **Backlog #45** — Router source patch: pre-commit identity in all 4 internal quoter helpers (`_ammSpotPriceForBuy`, `_ammSpotPriceForSell`, `_computeBuyNoMintAmount`, `_computeSellNoMaxCost`) and the 4 public `quote*` methods. Redeploy router, rewire all references, rerun Phase 3.
3. **Backlog #46** — Router integration test: `packages/router/test/integration/PrediXRouter_HookCommit.t.sol` using real `PrediXHookV2` + real `PoolManager` to catch this regression class.
4. **Backlog #47** — Phase 3.5 re-run after backlog #45 lands: re-execute Group RT against the patched router + existing pool 1 (market 19 liquidity is still there, no re-seed needed).
5. **Backlog #48** — `80_phase3_pool.sh` script improvement: compute tick range dynamically from current tick instead of hardcoding `[-7080, -6780]`, so idempotency re-runs work regardless of YES/USDC ordering.

## 10. Artifacts

| Path | Purpose |
|---|---|
| [scripts/testnet/80_phase3_pool.sh](scripts/testnet/80_phase3_pool.sh) | Idempotent Phase 3 setup: escapes #5/#6 → market create → pool register → PoolManager init → liquidity seed. **Reproducible** — any future Phase 3.5 can re-run this as-is. |
| [scripts/testnet/lib/common.sh](scripts/testnet/lib/common.sh) | Shared helpers (from Phase 2, reused) |
| `/tmp/predix_phase3_state.json` | Process-local state marker (marketId, poolId, currencies, sqrtPriceX96) |
| Phase 3 on-chain state | Permanent: pools 1 + 2 initialized, hook trust state updated, markets 19 + 20 created |

## 11. Next step

1. **Main session**: ingest backlogs #44, #45, #46, #47, #48; prioritize #45 + #46 as blocking for Phase 3.5 completion.
2. **Phase 4 dispatch** (separate task): router source patch + integration test + redeploy + rewire.
3. **Phase 3.5 re-run** after Phase 4: `bash scripts/testnet/80_phase3_pool.sh` (idempotent, will reuse pool 1) + Group RT execution on the patched router.
4. **Audit firm pack**: this report + Phase 2 report + Plan doc + all `scripts/testnet/*.sh`. Phase 3 is strong audit evidence even in its halted state — it caught two critical protocol bugs that unit tests missed.

**Phase 3 halted honestly. No autonomous contract patches. No redeploys. Awaiting Phase 4 authorization for the router fix.**
