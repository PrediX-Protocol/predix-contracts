# Redemption Fee — implementation spec

> **Read first**: this spec is self-contained but you MUST also read
> `SC/CLAUDE.md` (hard rules for the entire smart-contract subtree) before
> writing a single line of code. Anything in `CLAUDE.md` overrides this
> spec. You should ALSO skim
> [src/facets/market/MarketFacet.sol](../src/facets/market/MarketFacet.sol)
> and [src/libraries/LibConfigStorage.sol](../src/libraries/LibConfigStorage.sol)
> before you start — you will be modifying both.

---

## 0. What you are building

PrediX charges no protocol fee at launch — every external function is
free. This spec adds **the protocol's primary revenue mechanism**: a
**redemption fee**, charged on the winning payout when a user calls
`MarketFacet.redeem(marketId)`.

The fee design is modeled on Polymarket: a single fee at redemption
time, invisible to the price discovery layer, paid only by users who
won (losers and refund-mode markets pay nothing).

Two layers of configurability:

1. **Default fee** (`defaultRedemptionFeeBps`) — one global rate
   applied to every market that does not have an explicit override.
2. **Per-market override** — `(uint16 perMarketRedemptionFeeBps, bool
   redemptionFeeOverridden)` stored on each `MarketData`. When
   `redemptionFeeOverridden == true`, the per-market value is used
   verbatim (including 0%). When `false`, the default applies.

Both layers are admin-controlled via `ADMIN_ROLE`. Both default to
zero at deploy — the protocol launches fee-free, and the team enables
the fee via an admin transaction once they decide it is time.

---

## 1. Hard rules (subset of `SC/CLAUDE.md`)

- **Toolchain**: Solidity `0.8.30`, `evm_version = cancun`,
  `via_ir = true`, `optimizer_runs = 200`. Do not change `foundry.toml`.
- **Boundary §2**: this work lives entirely inside
  `SC/packages/diamond/` and `SC/packages/shared/`. No other package is
  touched. The shared interface change must be append-only and
  backwards-compatible.
- **Storage layout append-only §6.7**: every storage struct change is a
  trailing append. Never reorder existing fields.
- **Custom errors**, no `require(string)`. Errors declared in the
  interface, not the implementation.
- **Events** declared in the interface, indexed where it helps
  off-chain indexing.
- **NatSpec** on every external/public function, struct, event, error.
  Implementation contracts use `@inheritdoc` once the interface has the
  doc.
- **No `tx.origin`**, no inline assembly except the diamond-storage
  slot helper that already exists, no `selfdestruct`, no `unchecked`.
- **SafeERC20 always** — `safeTransfer` to fee recipient.
- **Tests**: every new external function gets ≥1 happy + ≥1 revert
  test; every new custom error must be triggered; the fee math is
  fuzz-tested; the existing redemption tests get extended for fee
  enabled / disabled / per-market-override paths; existing invariants
  must continue to hold.
- **§5.5 scope discipline**: build exactly what this spec asks for. If
  you find something else that "would be nice", **stop and ask**
  instead of widening scope.

---

## 2. What already exists (do not rebuild)

- **`MarketFacet.redeem`** ([src/facets/market/MarketFacet.sol](../src/facets/market/MarketFacet.sol))
  — the function you will modify. Currently burns winning + losing
  tokens, decrements `totalCollateral` by `winningBurned`, and
  transfers `winningBurned` USDC to the user.
- **`LibConfigStorage`** — already holds `feeRecipient`,
  `marketCreationFee`, `defaultPerMarketCap`. You will append
  `defaultRedemptionFeeBps`.
- **`LibMarketStorage.MarketData`** — append-only struct, already at
  v1.2 (with `eventId` from the EventFacet round). You will append
  two more fields here.
- **`LibAccessControl`** — `checkRole(Roles.ADMIN_ROLE)` for the
  setters.
- **`Roles.ADMIN_ROLE`** — already in
  `@predix/shared/constants/Roles.sol`.
- **`feeRecipient`** — already wired into `LibConfigStorage` and the
  market creation fee path. Redemption fee will reuse the same
  `feeRecipient` address. **No new recipient address is added.** The
  protocol team will deploy with `feeRecipient = <their EOA / Gnosis
  Safe>` and may swap to a Vault contract later via
  `setFeeRecipient`.

---

## 3. Files to touch

| File | Change |
|---|---|
| `packages/shared/src/interfaces/IMarketFacet.sol` | Append error, event(s), function signatures, struct field on `MarketView` |
| `packages/diamond/src/libraries/LibConfigStorage.sol` | Append `defaultRedemptionFeeBps` |
| `packages/diamond/src/libraries/LibMarketStorage.sol` | Append `perMarketRedemptionFeeBps` and `redemptionFeeOverridden` to `MarketData` |
| `packages/diamond/src/facets/market/MarketFacet.sol` | Add 4 setters + 1 helper + modify `redeem` math + update `getMarket` view + new constant |
| `packages/diamond/test/utils/MarketFixture.sol` | Selector list grows by 4 (new external functions) |
| `packages/diamond/test/unit/MarketCreate.t.sol` | Add admin setter tests |
| `packages/diamond/test/unit/MarketRedeemRefund.t.sol` | Extend redemption tests with fee scenarios |
| `packages/diamond/test/invariant/MarketInvariant.t.sol` | Update solvency invariant to account for fee outflow |

**No file outside `diamond/` and `shared/` is touched.** No router /
exchange / hook / oracle / event work in this round.

---

## 4. Storage changes

### 4.1 `LibConfigStorage`

Append **one** field at the end of `Layout`:

```solidity
struct Layout {
    IERC20 collateralToken;
    address feeRecipient;
    uint256 marketCreationFee;
    uint256 defaultPerMarketCap;
    mapping(address => bool) approvedOracles;
    // append-only: added in v1.2 to support the protocol redemption fee.
    // Value is in basis points (10000 = 100%). Hard-capped at
    // MAX_REDEMPTION_FEE_BPS in `MarketFacet.setDefaultRedemptionFeeBps`.
    // 0 = no protocol fee on redemption (the launch default).
    uint256 defaultRedemptionFeeBps;
}
```

Add a NatSpec block above the field stating it is append-only (v1.2).

### 4.2 `LibMarketStorage.MarketData`

Append **two** fields at the end:

```solidity
struct MarketData {
    string question;
    uint256 endTime;
    address oracle;
    address creator;
    address yesToken;
    address noToken;
    uint256 totalCollateral;
    uint256 perMarketCap;
    uint256 resolvedAt;
    uint256 refundEnabledAt;
    bool isResolved;
    bool outcome;
    bool refundModeActive;
    uint256 eventId;
    // append-only: added in v1.3 to support per-market redemption fee override.
    // When `redemptionFeeOverridden == true`, `perMarketRedemptionFeeBps` is
    // used verbatim (including 0). When false, the default from
    // LibConfigStorage applies. uint16 is sufficient because
    // MAX_REDEMPTION_FEE_BPS = 1500 << 65535.
    uint16 perMarketRedemptionFeeBps;
    bool redemptionFeeOverridden;
}
```

Solidity packs `uint16` + `bool` adjacently into the same storage
slot as the existing trailing `bool refundModeActive` if Solidity's
struct packing has room — verify with `forge inspect MarketFacet
storage-layout` after the change. If they spill into a fresh slot,
that is acceptable (one new slot per market is cheap).

---

## 5. Interface changes — `IMarketFacet`

### 5.1 New error

```solidity
/// @notice Reverts when an admin tries to set a redemption fee above
///         `MAX_REDEMPTION_FEE_BPS` (15%).
error Market_FeeTooHigh();
```

### 5.2 New events

```solidity
/// @notice Emitted when an admin updates the global default redemption fee.
event DefaultRedemptionFeeUpdated(uint256 previous, uint256 current);

/// @notice Emitted when an admin sets or clears a per-market redemption fee
///         override. `overridden == false` means the market reverted to
///         using the default; in that case `bps` is reported as 0 for clarity.
event PerMarketRedemptionFeeUpdated(uint256 indexed marketId, uint16 bps, bool overridden);
```

### 5.3 Modify existing event `TokensRedeemed`

The current event is:

```solidity
event TokensRedeemed(
    uint256 indexed marketId, address indexed user, uint256 winningBurned, uint256 losingBurned, uint256 payout
);
```

Add a fee field so off-chain indexers can see the fee directly without
re-deriving it from `winningBurned - payout`:

```solidity
event TokensRedeemed(
    uint256 indexed marketId,
    address indexed user,
    uint256 winningBurned,
    uint256 losingBurned,
    uint256 fee,
    uint256 payout
);
```

This is a breaking event-signature change. Pre-production protocol with
no live indexers — acceptable. Update every test that uses
`vm.expectEmit` with `TokensRedeemed` (search the test files for the
event name and adjust).

### 5.4 New external functions

```solidity
/// @notice Set the global default redemption fee. Restricted to `ADMIN_ROLE`.
/// @param bps Fee in basis points (10000 = 100%). Must be ≤ 1500.
function setDefaultRedemptionFeeBps(uint256 bps) external;

/// @notice Override the redemption fee for a single market. Restricted to
///         `ADMIN_ROLE`. Setting `bps = 0` with this function explicitly
///         charges 0% to the market (NOT the same as falling back to the
///         default — see `clearPerMarketRedemptionFee` for that).
/// @param marketId Target market.
/// @param bps      Fee in basis points; must be ≤ 1500.
function setPerMarketRedemptionFeeBps(uint256 marketId, uint16 bps) external;

/// @notice Clear a per-market override so the market reverts to using the
///         global default. Restricted to `ADMIN_ROLE`. No-op if the market
///         currently has no override.
function clearPerMarketRedemptionFee(uint256 marketId) external;

/// @notice Read the global default redemption fee in basis points.
function defaultRedemptionFeeBps() external view returns (uint256);

/// @notice Read the effective redemption fee in basis points that the
///         given market currently charges. This collapses the
///         override / default decision into a single number for callers
///         that only care about the result.
function effectiveRedemptionFeeBps(uint256 marketId) external view returns (uint256);
```

### 5.5 `MarketView` struct expansion

Append the same two fields to `MarketView` so off-chain consumers can
read them via `getMarket`:

```solidity
struct MarketView {
    // ... existing fields ...
    uint256 eventId;
    // append-only: added in v1.3 along with the redemption fee.
    uint16 perMarketRedemptionFeeBps;
    bool redemptionFeeOverridden;
}
```

`getMarketStatus` does **not** include these fields — it stays a
hot-path 5-tuple optimised for exchange / router. Fee state is read
via `effectiveRedemptionFeeBps` (single uint256) when needed.

---

## 6. `MarketFacet` implementation

### 6.1 New constant

```solidity
/// @notice Hard ceiling on redemption fees. 1500 bps = 15%. Both
///         `defaultRedemptionFeeBps` and `perMarketRedemptionFeeBps`
///         are bounded by this constant.
uint256 internal constant MAX_REDEMPTION_FEE_BPS = 1500;

/// @notice Basis-point denominator. 10000 = 100%.
uint256 internal constant BPS_DENOMINATOR = 10000;
```

### 6.2 Setters

```solidity
/// @inheritdoc IMarketFacet
function setDefaultRedemptionFeeBps(uint256 bps) external override {
    LibAccessControl.checkRole(Roles.ADMIN_ROLE);
    if (bps > MAX_REDEMPTION_FEE_BPS) revert Market_FeeTooHigh();
    LibConfigStorage.Layout storage cfg = LibConfigStorage.layout();
    uint256 previous = cfg.defaultRedemptionFeeBps;
    cfg.defaultRedemptionFeeBps = bps;
    emit DefaultRedemptionFeeUpdated(previous, bps);
}

/// @inheritdoc IMarketFacet
function setPerMarketRedemptionFeeBps(uint256 marketId, uint16 bps) external override {
    LibAccessControl.checkRole(Roles.ADMIN_ROLE);
    if (bps > MAX_REDEMPTION_FEE_BPS) revert Market_FeeTooHigh();
    LibMarketStorage.MarketData storage m = _market(marketId);
    m.perMarketRedemptionFeeBps = bps;
    m.redemptionFeeOverridden = true;
    emit PerMarketRedemptionFeeUpdated(marketId, bps, true);
}

/// @inheritdoc IMarketFacet
function clearPerMarketRedemptionFee(uint256 marketId) external override {
    LibAccessControl.checkRole(Roles.ADMIN_ROLE);
    LibMarketStorage.MarketData storage m = _market(marketId);
    m.perMarketRedemptionFeeBps = 0;
    m.redemptionFeeOverridden = false;
    emit PerMarketRedemptionFeeUpdated(marketId, 0, false);
}
```

`_market(marketId)` is the existing private helper that loads the
storage pointer and reverts `Market_NotFound` if absent. Reuse it.

### 6.3 Effective fee helper (private + public view)

```solidity
function _effectiveRedemptionFee(LibMarketStorage.MarketData storage m) private view returns (uint256) {
    return m.redemptionFeeOverridden
        ? m.perMarketRedemptionFeeBps
        : LibConfigStorage.layout().defaultRedemptionFeeBps;
}

/// @inheritdoc IMarketFacet
function effectiveRedemptionFeeBps(uint256 marketId) external view override returns (uint256) {
    return _effectiveRedemptionFee(_market(marketId));
}

/// @inheritdoc IMarketFacet
function defaultRedemptionFeeBps() external view override returns (uint256) {
    return LibConfigStorage.layout().defaultRedemptionFeeBps;
}
```

### 6.4 Modify `redeem`

The current redeem (paraphrased):

```solidity
function redeem(uint256 marketId) external nonReentrant returns (uint256 payout) {
    LibPausable.enforceNotPaused(Modules.MARKET);
    LibMarketStorage.MarketData storage m = _market(marketId);
    if (!m.isResolved) revert Market_NotResolved();

    IOutcomeToken yes = IOutcomeToken(m.yesToken);
    IOutcomeToken no = IOutcomeToken(m.noToken);
    uint256 yesBal = yes.balanceOf(msg.sender);
    uint256 noBal = no.balanceOf(msg.sender);
    if (yesBal + noBal == 0) revert Market_NothingToRedeem();

    uint256 winningBurned;
    uint256 losingBurned;
    if (m.outcome) { winningBurned = yesBal; losingBurned = noBal; }
    else            { winningBurned = noBal; losingBurned = yesBal; }

    if (yesBal > 0) yes.burn(msg.sender, yesBal);
    if (noBal > 0)  no.burn(msg.sender, noBal);

    payout = winningBurned;
    if (payout > 0) {
        m.totalCollateral -= payout;
        LibConfigStorage.layout().collateralToken.safeTransfer(msg.sender, payout);
    }

    emit TokensRedeemed(marketId, msg.sender, winningBurned, losingBurned, payout);
}
```

Refactor it like this — keep the burn logic identical, change the
payout math:

```solidity
function redeem(uint256 marketId) external override nonReentrant returns (uint256 payout) {
    LibPausable.enforceNotPaused(Modules.MARKET);

    LibMarketStorage.MarketData storage m = _market(marketId);
    if (!m.isResolved) revert Market_NotResolved();

    IOutcomeToken yes = IOutcomeToken(m.yesToken);
    IOutcomeToken no = IOutcomeToken(m.noToken);
    uint256 yesBal = yes.balanceOf(msg.sender);
    uint256 noBal = no.balanceOf(msg.sender);
    if (yesBal + noBal == 0) revert Market_NothingToRedeem();

    uint256 winningBurned;
    uint256 losingBurned;
    if (m.outcome) {
        winningBurned = yesBal;
        losingBurned = noBal;
    } else {
        winningBurned = noBal;
        losingBurned = yesBal;
    }

    if (yesBal > 0) yes.burn(msg.sender, yesBal);
    if (noBal > 0) no.burn(msg.sender, noBal);

    uint256 fee;
    if (winningBurned > 0) {
        uint256 feeBps = _effectiveRedemptionFee(m);
        fee = (winningBurned * feeBps) / BPS_DENOMINATOR;
        payout = winningBurned - fee;

        // Effects: decrement collateral by the FULL winning amount —
        // both the fee and the user payout come from the market's collateral
        // pool, so the invariant `totalCollateral` ≥ outstanding obligations
        // is preserved.
        m.totalCollateral -= winningBurned;

        // Interactions
        LibConfigStorage.Layout storage cfg = LibConfigStorage.layout();
        if (fee > 0) {
            cfg.collateralToken.safeTransfer(cfg.feeRecipient, fee);
        }
        if (payout > 0) {
            cfg.collateralToken.safeTransfer(msg.sender, payout);
        }
    }

    emit TokensRedeemed(marketId, msg.sender, winningBurned, losingBurned, fee, payout);
}
```

**Critical invariants preserved**:

1. `totalCollateral` decreases by exactly `winningBurned` — the same
   as today. Fee + payout sum to `winningBurned` (integer math is
   exact: `payout = winningBurned - fee` by construction).
2. The fee is a transfer **out** of the diamond's USDC balance to
   `feeRecipient`, just like the user payout. Total USDC out =
   `winningBurned`.
3. Order: burns first → state update → external transfers (CEI). Same
   as before; the fee transfer is added between state update and the
   user transfer, which is fine because `nonReentrant` covers the
   whole function and `feeRecipient` is admin-controlled (trusted).
4. When `winningBurned == 0` (user only held losing tokens), no fee,
   no payout, no transfers. Existing `Market_NothingToRedeem` check
   on `yesBal + noBal == 0` is preserved.
5. `refund(...)` is **NOT** modified. Refund-mode payouts are not
   subject to the redemption fee — users in a broken market should
   not be charged.

### 6.5 `getMarket` view update

`getMarket` returns the full `MarketView`. Add the two new fields to
the struct literal:

```solidity
return MarketView({
    // ... all existing fields ...
    eventId: m.eventId,
    perMarketRedemptionFeeBps: m.perMarketRedemptionFeeBps,
    redemptionFeeOverridden: m.redemptionFeeOverridden
});
```

`getMarketStatus` does **NOT** change. Fee state is not on the
hot path.

---

## 7. Test fixture update

`packages/diamond/test/utils/MarketFixture.sol` currently lists 22
selectors in `_marketSelectors()`. After this change there are **26**:

```solidity
function _marketSelectors() internal pure returns (bytes4[] memory s) {
    s = new bytes4[](26);  // was 22
    // ... existing 22 selectors ...
    s[22] = IMarketFacet.setDefaultRedemptionFeeBps.selector;
    s[23] = IMarketFacet.setPerMarketRedemptionFeeBps.selector;
    s[24] = IMarketFacet.clearPerMarketRedemptionFee.selector;
    s[25] = IMarketFacet.defaultRedemptionFeeBps.selector;
    // Note: effectiveRedemptionFeeBps is also new, count = 27.
}
```

Wait — that's 5 new functions: `setDefaultRedemptionFeeBps`,
`setPerMarketRedemptionFeeBps`, `clearPerMarketRedemptionFee`,
`defaultRedemptionFeeBps`, `effectiveRedemptionFeeBps`. So the array
length is **27** and the selectors fill indices 22..26. Verify the
count carefully — an off-by-one here will cause silent test failures
because the diamond proxy won't route the selector and tests will
revert with `Diamond_FunctionNotFound`.

---

## 8. Tests

### 8.1 New unit tests

Add to `test/unit/MarketCreate.t.sol` (or create a new file
`test/unit/MarketRedemptionFee.t.sol` if MarketCreate is getting
crowded):

**Default fee setters / views**:
- `test_SetDefaultRedemptionFeeBps_HappyPath`
- `test_SetDefaultRedemptionFeeBps_AtCeiling` — set exactly 1500, succeeds
- `test_Revert_SetDefaultRedemptionFeeBps_AboveCeiling` — set 1501, reverts `Market_FeeTooHigh`
- `test_Revert_SetDefaultRedemptionFeeBps_NotAdmin` — non-admin caller reverts with `AccessControl_MissingRole`
- `test_DefaultRedemptionFeeBps_StartsZero`
- `test_SetDefaultRedemptionFeeBps_EmitsEvent` — `vm.expectEmit` `DefaultRedemptionFeeUpdated`

**Per-market override setters / views**:
- `test_SetPerMarketRedemptionFeeBps_HappyPath`
- `test_SetPerMarketRedemptionFeeBps_ExplicitZero` — set 0 with override, asserts `effectiveRedemptionFeeBps == 0` even when default > 0
- `test_SetPerMarketRedemptionFeeBps_OverridesDefault`
- `test_Revert_SetPerMarketRedemptionFeeBps_AboveCeiling`
- `test_Revert_SetPerMarketRedemptionFeeBps_NotAdmin`
- `test_Revert_SetPerMarketRedemptionFeeBps_NotFound` — unknown marketId
- `test_ClearPerMarketRedemptionFee_RestoresDefault`
- `test_ClearPerMarketRedemptionFee_NoopIfNoOverride` — should not revert; idempotent
- `test_PerMarketRedemptionFeeBps_EmitsEvent`
- `test_EffectiveRedemptionFeeBps_FollowsOverrideThenDefault` — full state machine: default 0, set default 200, override market to 500, clear override → assert 0/200/500/200 at each step
- `test_GetMarket_IncludesPerMarketFeeFields` — the existing `getMarket` returns the new struct fields populated

### 8.2 Extend existing redemption tests

In `test/unit/MarketRedeemRefund.t.sol`, every existing `redeem` test
must still pass. Add new scenarios on top:

- `test_Redeem_NoFee_PayoutFull` — default 0, no override, user gets full winningBurned
- `test_Redeem_DefaultFee_DeductedAndForwarded` — set default 200 (2%), redeem 1000 winning, user gets 980, feeRecipient gets 20
- `test_Redeem_PerMarketFee_OverridesDefault` — default 200, override market 500, redeem 1000, user gets 950, feeRecipient gets 50
- `test_Redeem_PerMarketFee_ExplicitZeroOverride` — default 200, override market 0 explicit, redeem 1000, user gets 1000, fee 0
- `test_Redeem_FeeAtCeiling` — set 1500, redeem 1000, user gets 850, feeRecipient gets 150
- `test_Redeem_RoundingDown_NoLeftover` — fee = floor(amount × bps / 10000), assert sum exact
- `test_Redeem_OnlyLosingTokens_NoFee` — user only has losing tokens, no fee, no payout, balances clean
- `test_Redeem_FeeEvent_FieldsCorrect` — `vm.expectEmit` `TokensRedeemed` with the new 6-field signature
- `test_Refund_NoFee_EvenWhenRedemptionFeeSet` — set default 1500, enable refund mode, refund returns full amount (refund path is intentionally fee-free)
- `test_Sweep_StillWorks` — sweep behaviour unchanged regardless of fee setting

### 8.3 Fuzz tests

Add to the fee test file:

- `testFuzz_FeeMath_PayoutPlusFeeEqualsBurned(uint256 winningAmount, uint16 bps)` — bound `winningAmount` to `[0, 1e15]` and `bps` to `[0, 1500]`; assert `(winning * bps / 10000) + (winning - winning * bps / 10000) == winning` (no rounding leak)
- `testFuzz_DefaultBpsRoundtrip(uint256 bps)` — bound to `[0, 1500]`, set, read back, assert equality
- `testFuzz_PerMarketBpsRoundtrip(uint16 bps)` — same for per-market
- `testFuzz_Revert_OutOfRange(uint256 bps)` — bound to `[1501, type(uint256).max]`, assert always reverts `Market_FeeTooHigh`

### 8.4 Invariant updates

Existing `MarketInvariantTest` has `invariant_collateralBackedByUsdc`:
> `m.totalCollateral` ≤ `usdc.balanceOf(diamond)`

This invariant **still holds** after the fee work because fee transfers
happen **after** the collateral decrement: when the fee leaves the
contract, the invariant ratio is `m.totalCollateral - winningBurned ≤
usdc.balanceOf(diamond) - winningBurned`, which is the same inequality.

Add a NEW invariant to the suite:

```solidity
function invariant_FeeRecipientBalanceMonotonic() public view {
    // The fee recipient's USDC balance never decreases due to redemption
    // (only direction is in). If the recipient is also a market participant
    // who happens to redeem, this invariant breaks — fixture must use a
    // dedicated fee recipient address with no other role.
    assertGe(usdc.balanceOf(feeRecipient), feeRecipientBaseline);
}
```

Where `feeRecipientBaseline` is captured in the handler's setUp. The
fee recipient address used in the invariant fixture should be a
non-participant — pick a fresh `makeAddr("feeRecipient")`.

If the existing invariant handler does not already exercise `redeem`,
extend it to randomly burn-and-redeem a fraction of a user's position
each step. Cap at small amounts so the handler converges.

---

## 9. Definition of done

Run from `SC/packages/diamond/`:

- [ ] `forge build` — green, no new warnings.
- [ ] `forge test` — green. Existing 184 tests still pass + all new
      fee tests pass.
- [ ] `forge fmt --check` — clean.
- [ ] Shared package builds (`cd ../shared && forge build`) — the
      interface change is backwards compatible for callers (events
      added new field, struct grew by 2 fields).
- [ ] Hook + Oracle + (Exchange if applicable) packages still build
      cleanly. They consume `IMarketFacet` and must not regress.
- [ ] Every new external function has ≥1 happy + ≥1 revert test.
- [ ] Every new custom error (`Market_FeeTooHigh`) has a test that
      triggers it.
- [ ] All four new fuzz tests run with default fuzz runs and pass.
- [ ] The new `invariant_FeeRecipientBalanceMonotonic` runs in the
      256×500-call invariant suite with 0 reverts.
- [ ] NatSpec complete on every new external function, struct field,
      event, error.
- [ ] No imports outside `@openzeppelin`, `@predix/shared`,
      `@predix/diamond`.
- [ ] Report written in the `CLAUDE.md §10.4` format with a
      `Requirement → Evidence` mapping for every numbered section in
      this spec.

---

## 10. Execution phases

Build incrementally; run `forge build && forge test` after each
file so failures stay local.

1. **`IMarketFacet` update** — add `Market_FeeTooHigh`,
   `DefaultRedemptionFeeUpdated`, `PerMarketRedemptionFeeUpdated`,
   modify `TokensRedeemed`, append `MarketView` fields, add 5 function
   signatures. `forge build` — should fail in `MarketFacet.getMarket`
   and existing tests that emit `TokensRedeemed`. Keep going.
2. **`LibConfigStorage` update** — append `defaultRedemptionFeeBps`.
   `forge build`.
3. **`LibMarketStorage` update** — append `perMarketRedemptionFeeBps`
   and `redemptionFeeOverridden`. `forge build`.
4. **`MarketFacet` implementation** — add constants, 3 setters, 2
   views (one of which is `effectiveRedemptionFeeBps`, the other is
   `defaultRedemptionFeeBps`), private `_effectiveRedemptionFee`
   helper, modify `getMarket`, modify `redeem`. `forge build` — must
   compile. Existing tests will now fail because of the
   `TokensRedeemed` signature change.
5. **`MarketFixture` update** — bump selector array to 27 (5 new
   selectors). `forge build` again.
6. **Fix existing tests that emit `TokensRedeemed`** — add the new
   `fee` field to every `vm.expectEmit` block. Search the test
   directory for `TokensRedeemed`. There should be ~3–5 hits in
   `MarketRedeemRefund.t.sol`. `forge test --match-contract
   MarketRedeemRefund` — must pass.
7. **Add new unit tests** — §8.1 first (setters), then §8.2 (extended
   redeem). `forge test --match-test "RedemptionFee|DefaultFee"` to
   bisect.
8. **Add new fuzz tests** — §8.3.
9. **Add new invariant** — §8.4. Tune fixture if it doesn't hold
   trivially.
10. **Cross-package regression** — `cd ../shared && forge test`,
    `cd ../oracle && forge test`, `cd ../hook && forge test`,
    `cd ../exchange && forge test` (if it exists at that point).
11. **Final pass** — `forge fmt`, `forge build`, `forge test`, write
    the report.

---

## 11. Out of scope — do NOT build any of these

- **Fee on `splitPosition` / `mergePositions`**. These are 1:1
  collateral moves, no value extracted. Fee here would distort the
  binary invariant and break the market math.
- **Fee on `refund`**. Users in a broken market have already lost; the
  protocol will not double-charge them. Locked.
- **Fee on `createMarket` beyond the existing `marketCreationFee`**.
  The creation fee is already in place and admin-configurable; no
  separate redemption-tier fee on creation.
- **Hook-level AMM swap fee (Tier 3)**. Deferred. Future work needs a
  hook upgrade and is out of scope for this round.
- **Exchange taker / maker fee**. Locked NO — exchange stays
  permissionless and zero-fee on the trading path.
- **Router fee**. Locked NO.
- **Multi-recipient fee splitter**. The single `feeRecipient` is the
  only output. The protocol team will route to a vault / treasury /
  splitter externally if they want.
- **Per-event fee** (e.g. fee at the EventFacet level applied across
  all child markets). Each child market is its own redemption with
  its own fee rate. No event-level fee aggregation.
- **Time-decaying fee** (e.g. higher fee close to resolution). Static
  fee per market, per call. Deferred.
- **Vault contract**. Out of scope. The protocol team will deploy
  with `feeRecipient = <EOA / Gnosis Safe>` and may swap to a vault
  later via `setFeeRecipient`. No vault interface, no callbacks, no
  notification — vault is treated as an opaque address.
- **Touching `router/`, `exchange/`, `hook/`, `oracle/` source**. Only
  `diamond/` and `shared/` are modified.

---

## 12. Locked decisions (don't re-open)

The reviewer and user pre-confirmed these. Do NOT change without
explicit go-ahead:

1. **Fee mechanism**: protocol fee at redemption time only. No fee on
   trade time, on split/merge, on refund, on resolve. Locked Q1.
2. **Hard ceiling**: `MAX_REDEMPTION_FEE_BPS = 1500` (15%). Both the
   default and any per-market override are bounded by this constant.
   Locked Q2.
3. **Launch defaults**: `defaultRedemptionFeeBps = 0` at deploy. The
   protocol launches fee-free; the team will enable the fee via an
   admin transaction later. Locked Q3.
4. **Per-market override**: yes, with explicit-0% support. The
   override uses a `bool redemptionFeeOverridden` flag. When
   `overridden == true`, the per-market value is used (including 0).
   When `false`, the default applies. Locked Q4 + Q-F2 (i).
5. **No fee on refund mode**. Locked Q5.
6. **Spec-only this round**. The reviewer is not implementing — a
   coding agent will build this from this document. Locked Q6.
7. **`feeRecipient` is a passive address**. No vault interface, no
   notification callback. The protocol team owns the address and may
   change it via the existing `setFeeRecipient`. Locked Q7.
8. **Storage layout**: append-only on `LibConfigStorage` and
   `LibMarketStorage.MarketData`. Locked Q-F1 (a).
9. **Override semantics**: bool flag (option i), not sentinel
   encoding. Locked Q-F2 (i).

---

## 13. Things to pause and ask if you're stuck

The reviewer has pre-answered the common ones (see §12). Do NOT
re-open them. Flag immediately if you find a technical reason any
locked decision cannot hold:

1. The `uint16` packing in `MarketData` doesn't pack adjacently with
   the existing trailing bool — `forge inspect` shows it spilling into
   a fresh slot. Acceptable, but document it.
2. The new `TokensRedeemed` event signature breaks an indexer or test
   you didn't expect. Search the entire repo for `TokensRedeemed` and
   list every consumer.
3. `_effectiveRedemptionFee` produces a different number than the
   integration test expects — likely a bps vs basis-point unit
   confusion. Always double-check that bps × amount is divided by
   10000, not 1e6 or 100.
4. The invariant suite handler doesn't exercise `redeem` enough for
   the new `invariant_FeeRecipientBalanceMonotonic` to be meaningful.
   Tune the handler's action weights — but if it's a structural
   issue, ask before refactoring the handler.
5. Cross-package regression breaks something in `shared/`, `hook/`,
   `oracle/`, or `exchange/`. The interface change should be
   append-only and backwards-compatible — if a consumer breaks,
   investigate before silencing.
6. You discover that fee math hits an overflow corner for very large
   `winningBurned` and very small bps. Solidity 0.8 catches this,
   but if the fuzz suite finds a real revert, raise it before
   touching the math.

---

## 14. Report format

After you finish, write the report per `SC/CLAUDE.md §10.4`:

```
## Summary
<1-2 sentences>

## Requirement → Evidence
- §4.1 LibConfigStorage append → src/libraries/LibConfigStorage.sol:<line>
- §4.2 LibMarketStorage append → src/libraries/LibMarketStorage.sol:<line>
- §5.1 Market_FeeTooHigh error → packages/shared/src/interfaces/IMarketFacet.sol:<line>
- §5.2 DefaultRedemptionFeeUpdated event → IMarketFacet:<line>
- §5.3 TokensRedeemed signature change → IMarketFacet:<line>
- §5.4 New external functions → IMarketFacet:<line ranges>
- §5.5 MarketView struct fields → IMarketFacet:<line>
- §6.1 MAX_REDEMPTION_FEE_BPS constant → MarketFacet.sol:<line>
- §6.2 Setters → MarketFacet.sol:<line ranges>
- §6.3 Effective fee helpers → MarketFacet.sol:<line>
- §6.4 redeem modification → MarketFacet.sol:<line range>
- §6.5 getMarket update → MarketFacet.sol:<line>
- §7 Fixture selector update → MarketFixture.sol:<line>
- §8.1–8.4 Tests → file:line for each test name
- §10 Cross-package regression → "X packages still pass: shared (N tests), oracle (N), hook (N), ..."

## Files
- Added: <list>
- Modified: <list>
- Shared additions: Market_FeeTooHigh, 2 events, 5 functions, 2 MarketView fields

## Tests
- Unit: <count>
- Fuzz: <count>
- Invariant: <names — must include invariant_FeeRecipientBalanceMonotonic>
- Full-suite status: X passed / 0 failed across diamond + shared + dependent packages

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
in the code. The author is another agent — you have the full picture
after building it. Just document the disagreement.
