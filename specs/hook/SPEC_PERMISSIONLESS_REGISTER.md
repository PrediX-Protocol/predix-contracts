# PrediXHookV2 — Permissionless `registerMarketPool` patch

> **Read first**: this spec is self-contained but you MUST also read
> `SC/CLAUDE.md` (hard rules for the entire smart-contract subtree)
> before writing a single line of code. Anything in `CLAUDE.md`
> overrides this spec. You should ALSO have your existing context on
> [src/hooks/PrediXHookV2.sol](../src/hooks/PrediXHookV2.sol) and
> [src/interfaces/IPrediXHook.sol](../src/interfaces/IPrediXHook.sol)
> from the previous hook rounds.

---

## 0. What you are fixing

The reviewer found an architectural gap during router R1-R2 verification:

- `PrediXHookV2.registerMarketPool(uint256 marketId, PoolKey calldata key)` is
  gated by an `onlyDiamond` modifier.
- **No facet in `packages/diamond/src/` ever calls
  `registerMarketPool`** — verified by grep.
- The S3 design decision from Phase A locked in: *"diamond chỉ deploy
  OutcomeToken + emit event. Hook package (hoặc script deploy) tự init
  pool khi thấy event."* — i.e. the diamond is intentionally unaware
  of v4 / hook / pool integration.
- The result: **pool registration is currently impossible**. Every new
  market is created without a hook binding, every subsequent v4 swap
  reverts at `_beforeInitialize` with `Hook_PoolNotRegistered`, and
  the router cannot integration-test against a real stack.

The reviewer evaluated three resolution options:
- **A** — drop `onlyDiamond`, validate via diamond read at call time
- **B** — add a new facet function on the diamond that wraps the call
- **C** — auto-register inside `MarketFacet.createMarket`

User confirmed **Option A** because:
1. Smallest code change (1 modifier deletion)
2. Preserves the S3 decision that the diamond is unaware of v4
3. The existing currency-validation logic inside `registerMarketPool`
   already proves the caller passed a real `(marketId, yesToken,
   USDC)` triple — it is the security barrier, not the role check
4. Aligns with V2's permissionless philosophy (taker path, oracle
   resolve, event create, expired-order cancel)
5. Hook upgrade pattern (proxy timelock + 2-step admin) is already
   shipped and tested

This spec describes that single change.

---

## 1. Hard rules (subset of `SC/CLAUDE.md`)

- **Toolchain**: Solidity `0.8.30`, `evm_version = cancun`,
  `via_ir = true`, `optimizer_runs = 200`. Do not change `foundry.toml`.
- **Boundary §2**: changes are entirely inside
  `SC/packages/hook/`. No other package is touched. The interface
  change in `IPrediXHook.sol` is backwards-compatible (function
  signature unchanged, only NatSpec).
- **Custom errors**: existing errors (`Hook_OnlyDiamond`,
  `Hook_PoolAlreadyRegistered`, `Hook_MarketNotFound`,
  `Hook_InvalidPoolCurrencies`, `Hook_NotInitialized`) are preserved.
  No new errors needed.
- **NatSpec** updated on the modified function and on the now-orphan
  `Hook_OnlyDiamond` error (still kept for other diamond-only
  functions if any — verify and remove only if truly unused).
- **No `tx.origin`**, no inline assembly, no `selfdestruct`.
- **Tests**: every new test follows the existing hook test conventions
  (use `TestHookHarness` + `MockDiamond`).
- **§5.5 scope discipline**: this is a **1-line code change** plus
  tests and NatSpec updates. Do NOT widen scope to other hook
  improvements. If you find something else to fix, stop and ask.

---

## 2. What exists, what to read

- [src/hooks/PrediXHookV2.sol](../src/hooks/PrediXHookV2.sol) — the
  contract you'll edit. Find `function registerMarketPool` (around
  line 190 based on the previous round). Note the `onlyDiamond`
  modifier on its declaration.
- [src/interfaces/IPrediXHook.sol](../src/interfaces/IPrediXHook.sol)
  — declares the function signature. **Signature does NOT change.**
  Only NatSpec on the function and on `Hook_OnlyDiamond` error change.
- [test/PrediXHookV2.t.sol](../test/PrediXHookV2.t.sol) — existing
  unit tests. Find the `registerMarketPool` test block. There is
  almost certainly a `test_Revert_RegisterMarketPool_OnlyDiamond` or
  similar — that test must be **removed** (it asserts the wrong
  behaviour after this patch).
- [test/utils/TestHookHarness.sol](../test/utils/TestHookHarness.sol)
  and [test/utils/MockDiamond.sol](../test/utils/MockDiamond.sol) —
  the test fixture. Use as-is.

---

## 3. The change

### 3.1 `PrediXHookV2.sol` — delete the modifier

Find:

```solidity
function registerMarketPool(uint256 marketId, PoolKey calldata key) external override onlyDiamond {
    if (!_initialized) revert Hook_NotInitialized();
    PoolId poolId = key.toId();
    PoolBinding storage binding = _poolBinding[poolId];
    if (binding.marketId != 0) revert Hook_PoolAlreadyRegistered();

    IMarketFacet.MarketView memory mkt = IMarketFacet(_diamond).getMarket(marketId);
    if (mkt.yesToken == address(0)) revert Hook_MarketNotFound();
    // ... currency validation ...
}
```

Replace with:

```solidity
/// @inheritdoc IPrediXHook
function registerMarketPool(uint256 marketId, PoolKey calldata key) external override {
    if (!_initialized) revert Hook_NotInitialized();
    PoolId poolId = key.toId();
    PoolBinding storage binding = _poolBinding[poolId];
    if (binding.marketId != 0) revert Hook_PoolAlreadyRegistered();

    // Permissionless registration: anyone may call. The security barrier
    // is the validation block below, NOT a caller-address check. The hook
    // requires that:
    //   - `marketId` exists in the diamond (yesToken != address(0))
    //   - the supplied `key` references the diamond-deployed yesToken
    //     and the configured USDC quote currency
    // A caller cannot register a junk binding because the diamond is the
    // only source of yesTokens and the currency check rejects every other
    // ERC20.
    IMarketFacet.MarketView memory mkt = IMarketFacet(_diamond).getMarket(marketId);
    if (mkt.yesToken == address(0)) revert Hook_MarketNotFound();
    // ... existing currency validation + binding write — DO NOT MODIFY ...
}
```

**Diff**:
1. Remove `onlyDiamond` from the function declaration.
2. Add a `// Permissionless registration: ...` block as inline NatSpec
   right above the validation.
3. **Nothing else inside the function body changes.** The validation
   logic was already correct; we are simply lifting the role gate.

### 3.2 `IPrediXHook.sol` — NatSpec update

Find the NatSpec block above `registerMarketPool` in the interface:

```solidity
/// @notice Diamond-only. Binds `poolId` (derived from `key`) to `marketId`, ...
function registerMarketPool(uint256 marketId, PoolKey calldata key) external;
```

Replace with:

```solidity
/// @notice Permissionless. Binds `poolId` (derived from `key`) to `marketId`,
///         verifying that one leg is the market's YES outcome token and the
///         other is the configured quote token. Must be called BEFORE
///         `poolManager.initialize(key, ...)` for the same key. Anyone can
///         call this — the hook validates that `marketId` exists in the
///         diamond and the currency pair is correct, so a junk binding
///         cannot be planted. The deploy script is the expected caller.
function registerMarketPool(uint256 marketId, PoolKey calldata key) external;
```

### 3.3 `IPrediXHook.sol` — `Hook_OnlyDiamond` error

Search the interface for `Hook_OnlyDiamond` and check whether any
function still uses it. If `registerMarketPool` was the **only**
diamond-only function, the error becomes orphan after this patch.

- If it has other uses → keep it. Update its NatSpec to reflect the
  remaining caller surface.
- If it has no other uses → **delete it** from the interface AND from
  the implementation, AND remove any test that references it. Per
  CLAUDE.md §5.3, dead errors get removed.

To verify usage, run:
```bash
grep -rn "Hook_OnlyDiamond" SC/packages/hook/src
```
in the package root after your code change. If the only result is the
declaration line itself, it's orphan.

### 3.4 Test changes

Open [test/PrediXHookV2.t.sol](../test/PrediXHookV2.t.sol) and find the
`registerMarketPool` test block. Apply the following changes:

**Remove**:
- `test_Revert_RegisterMarketPool_OnlyDiamond` (or whatever it's named)
  — this test asserted that non-diamond callers revert with
  `Hook_OnlyDiamond`. After the patch, it must be deleted because the
  function is now callable by anyone with a valid market+currency
  combo.

**Add**:
- `test_RegisterMarketPool_PermissionlessFromAnyAddress` — happy path:
  deploy hook + mock diamond + create a market in the mock; have a
  random EOA (`makeAddr("randomCaller")`) call `registerMarketPool`
  with a valid key; assert the binding is stored and
  `Hook_PoolRegistered` event fires.
- `test_RegisterMarketPool_PermissionlessFromRouter` — same as above
  but use a "router-shaped" address; just to document that the
  router will be the production caller.

**Keep** (verify still pass after the patch):
- `test_RegisterMarketPool_HappyPath` — was probably calling from the
  diamond mock. Still works because the diamond is also "anyone" now.
- `test_Revert_RegisterMarketPool_NotInitialized`
- `test_Revert_RegisterMarketPool_AlreadyRegistered`
- `test_Revert_RegisterMarketPool_MarketNotFound` — a `marketId` not
  present in the mock diamond's storage should still revert.
- `test_Revert_RegisterMarketPool_InvalidCurrencies` — a key whose
  currencies don't match (yesToken, usdc) should still revert.

If `Hook_OnlyDiamond` was deleted in §3.3, also remove any
`test_Revert_OnlyDiamond_*` tests for it.

**Total test count change**: roughly `-1` (deleted onlyDiamond test) `+2`
(two new permissionless tests) = `+1` net. From 94 to 95.

---

## 4. Definition of done

Run from `SC/packages/hook/`:

- [ ] `forge build` — green, no new warnings.
- [ ] `forge test` — green, all existing tests still pass plus the
      new permissionless tests.
- [ ] `forge fmt --check` — clean.
- [ ] Test count: 95 (or 94 if you only added one new test instead
      of two — that's acceptable, just document the choice).
- [ ] `grep -rn "onlyDiamond" src/` returns ZERO matches in the hook
      package — the modifier is gone everywhere.
- [ ] `grep -rn "Hook_OnlyDiamond" src/` returns matches only if the
      error has surviving consumers in functions other than
      `registerMarketPool`. Otherwise zero.
- [ ] No imports outside `@uniswap/`, `@openzeppelin/`, `@predix/shared`,
      and local files. Boundary §2 unchanged.
- [ ] NatSpec on `registerMarketPool` reflects the permissionless
      semantics + validation rationale.
- [ ] Cross-package regression: `cd ../shared && forge test` and
      `cd ../diamond && forge test` and
      `cd ../oracle && forge test` and
      `cd ../exchange && forge test` (if it exists) — every package
      still passes.
- [ ] Report written in `CLAUDE.md §10.4` format with a
      `Requirement → Evidence` mapping for every numbered section in
      §3.

---

## 5. Hook upgrade flow (ops-side, NOT your responsibility)

This patch changes the hook's implementation contract. Production
upgrade requires a 48-hour timelock via the proxy:

1. Deploy the new `PrediXHookV2` implementation. Per the M1 refactor
   from round 2, the implementation can be deployed at **any address**
   — no salt mining required. Only the proxy needs a salt-mined address.
2. The proxy admin calls `PrediXHookProxyV2.proposeUpgrade(newImpl)`.
3. Wait `timelockDuration()` (default 48h, minimum 24h).
4. The proxy admin calls `PrediXHookProxyV2.executeUpgrade()`.
5. Existing pool bindings in `_poolBinding[poolId]` are preserved
   because the proxy's storage is separate from the impl's address.

**Pre-production shortcut**: until launch there are no live markets
or stored bindings. A fresh proxy can be deployed with the new impl
instead of running the timelock. The deploy script will build the
right thing.

You do not need to write the upgrade script — that is part of the
deployment work tracked separately by the user. Just ship the new
implementation and tests; ops handles the rollout.

---

## 6. Out of scope — do NOT build any of these

- **Adding `setHookAddress` to the diamond.** The diamond is
  intentionally unaware of the hook (S3 decision). This patch
  preserves that.
- **Auto-registering pools inside `MarketFacet.createMarket`.** That
  was Option C, rejected.
- **A new diamond facet function that wraps `registerMarketPool`.**
  That was Option B, rejected.
- **Adding `tickSpacing` / `fee` to `MarketData`.** The router stores
  these as deploy-time immutables; the hook does not need them. If a
  future spec wants per-market overrides, that is a separate work
  item.
- **Permissioned variants** (e.g. an additional `ADMIN_ROLE`-gated
  registration path). Permissionless is the intent, not a
  compromise.
- **Touching anything outside `SC/packages/hook/`.** Including
  `IMarketFacet`, `LibConfigStorage`, deploy scripts, README, etc.
- **Re-mining the proxy address.** The proxy address stays the same;
  only the impl behind it changes.
- **Adding a `MultiRegisterMarketPool` batch helper.** Single-call
  registration is enough; deploy scripts can loop.

---

## 7. Locked decisions (don't re-open)

The reviewer + user pre-confirmed these:

1. **Option A is the chosen resolution.** Drop `onlyDiamond`, keep
   currency validation. Locked.
2. **Permissionless registration is intentional.** The currency
   check (yesToken belongs to a real market in the diamond, USDC is
   the configured quote) is the security barrier. Locked.
3. **No diamond changes.** Diamond stays unaware of hook. S3 decision
   from Phase A holds. Locked.
4. **Hook upgrade via proxy timelock** — same flow used in earlier
   hook rounds. Locked.
5. **No new errors, no new events.** Existing surface is sufficient.
   Locked.
6. **Hook test count grows by ~1** (94 → 95). Locked.
7. **Backwards-compatible interface change.** `IPrediXHook.registerMarketPool`
   signature does not change; only NatSpec changes. Locked.

---

## 8. Things to pause and ask if you're stuck

If you hit any of these, **stop and ask the reviewer**:

1. `Hook_OnlyDiamond` is used by another function you didn't expect.
   Don't silently change other functions to permissionless — only
   `registerMarketPool` is in scope.
2. The existing `test_Revert_RegisterMarketPool_OnlyDiamond` test (or
   equivalent) does something you don't understand before deletion.
   Ask before nuking.
3. A cross-package test breaks (shared / diamond / oracle / exchange).
   The interface signature didn't change so this should not happen.
   If it does, find the dependency before working around it.
4. You discover the hook actually does need to know which address
   called register (e.g. for an audit trail). The current spec emits
   `Hook_PoolRegistered(marketId, poolId, yesToken, quoteToken,
   yesIsCurrency0)` without a caller field. Adding `address indexed
   registrar` is a tempting "while I'm here" but **out of scope** —
   ask before touching the event.
5. The currency validation has a corner case where a non-PrediX ERC20
   could pass (e.g. via a malicious diamond proxy). Verify your
   reasoning before claiming the validation is sufficient.

---

## 9. Report format

After you finish, write the report per `SC/CLAUDE.md §10.4`:

```
## Summary
Permissionless registerMarketPool patch. Single 1-line modifier
deletion plus NatSpec + tests + (possibly) orphan error cleanup.

## Requirement → Evidence
- §3.1 Modifier removal → src/hooks/PrediXHookV2.sol:<line>
- §3.2 IPrediXHook NatSpec update → src/interfaces/IPrediXHook.sol:<line>
- §3.3 Hook_OnlyDiamond cleanup → "still used by N functions" OR
  "deleted, src/interfaces/IPrediXHook.sol:<line>"
- §3.4 New tests → test/PrediXHookV2.t.sol:<line list>
- §3.4 Removed tests → list of test names
- §4 Cross-package regression → "shared N tests, diamond N tests,
  oracle N tests, exchange N tests, all passing"

## Files
- Modified: src/hooks/PrediXHookV2.sol, src/interfaces/IPrediXHook.sol,
  test/PrediXHookV2.t.sol
- Possibly modified: same set if Hook_OnlyDiamond removed
- Added: none

## Tests
- Unit: 95 (was 94; +2 permissionless, -1 onlyDiamond)
  — or equivalent count adjusted for your removals
- Fuzz: unchanged
- Invariant: unchanged
- Full-suite status: X passed / 0 failed across hook + cross-package

## Deviations from spec
- <anywhere you diverged with written justification>

## Out-of-scope findings (NOT fixed)
- <anything you noticed but did not address>

## Open questions
- <anything still needing user confirmation>

## Checklist §10.3 (A–F)
- A. Requirement tracing: ✅ / ❌
- B. Build & test: ✅ / ❌
- C. Clean code: ✅ / ❌
- D. Security: ✅ / ❌
- E. Boundary: ✅ / ❌
- F. Documentation: ✅ / ❌
```

Push back on anything in this spec that looks wrong once you're back
in the code. The reviewer is another agent — you have the full picture
after building it. Just document the disagreement.
