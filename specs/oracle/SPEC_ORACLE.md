# Oracle package — implementation spec

> **Read first**: this spec is self-contained but you MUST also read
> `SC/CLAUDE.md` (hard rules for the entire smart-contract subtree) before
> writing a single line of code. Anything in CLAUDE.md overrides this spec.

---

## 0. What you are building

The PrediX V2 diamond (`SC/packages/diamond/`) settles binary prediction
markets by **pulling** the answer from an on-chain oracle contract chosen at
market creation time. Oracles live in this package (`SC/packages/oracle/`)
and are deployed independently from the diamond — they only have to satisfy
the `IOracle` interface defined in `@predix/shared/interfaces/IOracle.sol`.

You are implementing **two oracle adapters** in this phase:

1. **`ManualOracle`** — a multisig/EOA reporter submits the outcome by hand.
2. **`ChainlinkOracle`** — reads a Chainlink price feed at a snapshot time
   and resolves YES iff `price >= threshold` (or `<=` depending on config).

A third optimistic-style oracle is **out of scope** for this phase.

---

## 1. The contract you must satisfy

`SC/packages/shared/src/interfaces/IOracle.sol` (already shipped, do not edit):

```solidity
interface IOracle {
    function isResolved(uint256 marketId) external view returns (bool);
    function outcome(uint256 marketId) external view returns (bool);
}
```

Semantic contract:
- `isResolved(marketId)` returns `true` once the oracle has produced a final,
  immutable answer for `marketId`.
- `outcome(marketId)` returns `true` if YES wins, `false` if NO wins. **MUST
  revert** if `!isResolved(marketId)`.
- Once an oracle answers a market, the answer is final from the diamond's
  perspective: `MarketFacet.resolveMarket` reads it once, snapshots
  `isResolved/outcome` into market storage, and never queries the oracle
  again. So an oracle implementation may keep a "revoke before consumed"
  escape hatch as long as it is gated by a strong role and does not touch
  diamond storage.

How the diamond uses it (`SC/packages/diamond/src/facets/market/MarketFacet.sol`,
`resolveMarket`):

```solidity
IOracle oracle = IOracle(m.oracle);
if (!oracle.isResolved(marketId)) revert Market_OracleNotResolved();
bool result = oracle.outcome(marketId);
```

So the diamond passes its **own** `marketId` (the diamond's monotonic counter)
to the oracle. Each oracle must therefore key its state by `marketId`, not by
a separate id space.

To make a market use an oracle:
1. Deploy the oracle contract.
2. An admin calls `IMarketFacet.approveOracle(<oracle address>)` on the
   diamond.
3. A market creator calls `IMarketFacet.createMarket(question, endTime, oracle)`
   passing that address. Once stored on the market it is **immutable**.

---

## 2. Hard rules (subset of `SC/CLAUDE.md` — go read the full file)

- **Toolchain**: Solidity `0.8.30`, `evm_version = cancun`, `via_ir = true`,
  `optimizer_runs = 200`. Do not change `foundry.toml`.
- **Boundary §2**: `oracle/` may import from `@predix/shared/` and from
  `@openzeppelin/contracts/` and `@chainlink/contracts/`. It MUST NOT import
  anything from `@predix/diamond/`, `@predix/hook`, `@predix/exchange`, or
  `@predix/router`. Cross-package shared types live in `shared/`.
- **Custom errors**, no `require(string)`. Errors declared in interfaces.
- **Events** declared in interfaces, indexed where it helps off-chain
  indexing.
- **NatSpec** on every external/public function, struct, event, error.
  Implementation contracts use `@inheritdoc` once the interface has the doc.
- **No `tx.origin`**, no `block.timestamp` for randomness, no hardcoded
  mainnet addresses, no `selfdestruct`. No inline assembly except for the
  patterns whitelisted in CLAUDE.md §1 (none expected here).
- **No deploy / push / PR / broadcast**.
- **Tests**: every external function gets ≥1 happy-path test and ≥1 revert
  test; every custom error must be triggered by at least one test; fuzz
  every function with numeric inputs; integration test against the actual
  diamond fixture (see §6 below).
- **§5.5 scope discipline**: implement exactly what this spec asks for, no
  more. If you find yourself adding a feature that does not map to a line in
  this spec, **stop and ask** instead of widening scope.

---

## 3. Reference (read for understanding, do **not** copy)

The previous codebase has reference implementations of the same two adapters:

- `/Users/keyti/Sources/PrediX_Uni_V4/Smart_Contract_V2/src/oracle/IOracle.sol`
- `/Users/keyti/Sources/PrediX_Uni_V4/Smart_Contract_V2/src/oracle/ManualOracleAdapter.sol`
- `/Users/keyti/Sources/PrediX_Uni_V4/Smart_Contract_V2/src/oracle/ChainlinkAdapter.sol`

Audit findings tracked in
`/Users/keyti/Sources/PrediX_Uni_V4/Smart_Contract_V2/PREDIX_AUDIT_REPORT_v2.md`
that are relevant to oracles:
- **L-03**: Chainlink `answeredInRound` check is deprecated on new feeds —
  rely on `updatedAt` staleness only.

Read these for **business logic, invariants, events, errors**. Do not
copy-paste implementation. The new code lives under `0.8.30 + cancun + via_ir`
with stricter NatSpec and clean-code rules — port idioms, not bytes.

---

## 4. Packages already in place

You can rely on the following without modifying them:

- `@predix/shared/interfaces/IOracle.sol` — the interface you implement.
- `@predix/shared/constants/Roles.sol` — canonical role identifiers used
  across the protocol. The values you need to know:
  - `DEFAULT_ADMIN_ROLE = 0x00`
  - `ADMIN_ROLE = keccak256("predix.role.admin")`
  - `OPERATOR_ROLE = keccak256("predix.role.operator")`
  - `PAUSER_ROLE = keccak256("predix.role.pauser")`
  - These live on the **diamond**. Each oracle is its **own** standalone
    contract with its **own** role registry — they are not shared. You may
    define oracle-specific roles like `REPORTER_ROLE`, `REGISTRAR_ROLE`
    locally inside the oracle contract.
- `@openzeppelin/contracts/access/AccessControl.sol` — use this for the role
  registry inside each oracle (oracles are not facets, so no diamond storage
  pattern is needed here; standard OZ AccessControl is the right fit).
- `@chainlink/contracts/src/v0.8/shared/interfaces/AggregatorV3Interface.sol`
  (path may differ — verify under `lib/chainlink-brownie-contracts/`) —
  Chainlink price feed interface.

---

## 5. What to build

```
SC/packages/oracle/
├── src/
│   ├── interfaces/
│   │   ├── IManualOracle.sol         # extends IOracle, adds events/errors/admin fns
│   │   └── IChainlinkOracle.sol      # extends IOracle, adds events/errors/admin fns
│   └── adapters/
│       ├── ManualOracle.sol          # implementation
│       └── ChainlinkOracle.sol       # implementation
├── test/
│   ├── unit/
│   │   ├── ManualOracle.t.sol
│   │   └── ChainlinkOracle.t.sol
│   ├── integration/
│   │   └── DiamondOracleIntegration.t.sol
│   ├── mocks/
│   │   └── MockChainlinkAggregator.sol
│   └── utils/
│       └── (fixture if you need a shared one)
```

No `init/` or `proxy/` — these are plain contracts. Constructor takes the
initial admin.

---

### 5.1 ManualOracle

**Use case**: human-curated markets where a trusted multisig (Gnosis Safe)
publishes the outcome.

#### Interface (`IManualOracle.sol`)

Extends `IOracle`. Adds:

```solidity
event OutcomeReported(uint256 indexed marketId, bool outcome, address indexed reporter);
event OutcomeRevoked(uint256 indexed marketId, address indexed admin);

error ManualOracle_AlreadyReported();
error ManualOracle_NotReported();

function report(uint256 marketId, bool outcome) external;
function revoke(uint256 marketId) external;
```

#### Implementation (`ManualOracle.sol`)

- Inherits OpenZeppelin `AccessControl`.
- Roles:
  - `DEFAULT_ADMIN_ROLE` — granted to `admin` in constructor; can grant/revoke
    `REPORTER_ROLE` and call `revoke`.
  - `REPORTER_ROLE = keccak256("predix.oracle.reporter")` — declared as
    `bytes32 public constant`. Granted by admin. Calls `report`.
- Storage:
  ```solidity
  struct Resolution {
      bool reported;
      bool outcome;
      uint64 reportedAt;
      address reporter;
  }
  mapping(uint256 marketId => Resolution) internal _resolutions;
  ```
- `report(marketId, outcome)`:
  - `onlyRole(REPORTER_ROLE)`
  - Revert `ManualOracle_AlreadyReported` if already reported.
  - Store resolution, emit `OutcomeReported`.
- `revoke(marketId)`:
  - `onlyRole(DEFAULT_ADMIN_ROLE)`
  - Revert `ManualOracle_NotReported` if not reported.
  - Reset resolution to default, emit `OutcomeRevoked`.
  - **Why** an escape hatch exists: the diamond snapshots the answer the moment
    `resolveMarket` is called. If a reporter publishes a wrong answer but no
    market has consumed it yet, admin can revoke before it propagates.
- `isResolved(marketId)` → returns `_resolutions[marketId].reported`.
- `outcome(marketId)` → reverts `ManualOracle_NotReported` if not reported,
  else returns the stored outcome.

#### Constructor

```solidity
constructor(address admin) {
    if (admin == address(0)) revert ManualOracle_ZeroAdmin();
    _grantRole(DEFAULT_ADMIN_ROLE, admin);
}
```

(declare `ManualOracle_ZeroAdmin` in the interface)

---

### 5.2 ChainlinkOracle

**Use case**: markets like *"ETH/USD ≥ $4000 at 2026-06-01 12:00 UTC"*. A
registrar configures the market, then anyone can call `resolve` after the
snapshot time has passed.

#### Interface (`IChainlinkOracle.sol`)

Extends `IOracle`. Adds:

```solidity
struct Config {
    address feed;       // Chainlink AggregatorV3 address
    int256 threshold;   // price threshold to compare against (in feed decimals)
    bool gte;           // true → outcome = (price >= threshold); false → (price <= threshold)
    uint64 snapshotAt;  // earliest unix timestamp at which `resolve` becomes callable
}

event MarketRegistered(uint256 indexed marketId, address indexed feed, int256 threshold, bool gte, uint64 snapshotAt);
event MarketResolved(uint256 indexed marketId, int256 price, bool outcome);

error ChainlinkOracle_NotRegistered();
error ChainlinkOracle_AlreadyRegistered();
error ChainlinkOracle_AlreadyResolved();
error ChainlinkOracle_BeforeSnapshot();
error ChainlinkOracle_StalePrice();
error ChainlinkOracle_InvalidPrice();
error ChainlinkOracle_ZeroFeed();
error ChainlinkOracle_ZeroAdmin();
error ChainlinkOracle_PastSnapshot();

function register(uint256 marketId, Config calldata cfg) external;
function resolve(uint256 marketId) external;
function getConfig(uint256 marketId) external view returns (Config memory);
```

#### Implementation (`ChainlinkOracle.sol`)

- Inherits OZ `AccessControl`.
- Roles:
  - `DEFAULT_ADMIN_ROLE` — granted to `admin` in constructor.
  - `REGISTRAR_ROLE = keccak256("predix.oracle.registrar")` — calls `register`.
- Constants:
  - `uint256 public constant MAX_STALENESS = 1 hours;` — maximum age of the
    Chainlink answer at the moment `resolve` is called. Tune later if a
    market needs a different freshness window; for v1 this is global.
- Storage:
  ```solidity
  struct Resolution {
      bool resolved;
      bool outcome;
      int256 price;        // snapshot of the feed answer at resolution
      uint64 resolvedAt;
  }
  mapping(uint256 marketId => Config) internal _configs;
  mapping(uint256 marketId => Resolution) internal _resolutions;
  ```
- `register(marketId, cfg)`:
  - `onlyRole(REGISTRAR_ROLE)`
  - Revert `ChainlinkOracle_AlreadyRegistered` if `_configs[marketId].feed != address(0)`.
  - Revert `ChainlinkOracle_ZeroFeed` if `cfg.feed == address(0)`.
  - Revert `ChainlinkOracle_PastSnapshot` if `cfg.snapshotAt <= block.timestamp`.
  - Store config, emit `MarketRegistered`.
- `resolve(marketId)`:
  - **Permissionless** (any caller can settle once data is ready).
  - Revert `ChainlinkOracle_NotRegistered` if config missing.
  - Revert `ChainlinkOracle_AlreadyResolved` if already resolved.
  - Revert `ChainlinkOracle_BeforeSnapshot` if `block.timestamp < cfg.snapshotAt`.
  - Read `(, int256 answer, , uint256 updatedAt, ) = AggregatorV3Interface(cfg.feed).latestRoundData();`
  - Revert `ChainlinkOracle_InvalidPrice` if `answer <= 0`.
  - Revert `ChainlinkOracle_StalePrice` if `block.timestamp - updatedAt > MAX_STALENESS`.
  - Compute outcome: `cfg.gte ? answer >= cfg.threshold : answer <= cfg.threshold`.
  - Store resolution, emit `MarketResolved`.
  - **Do not** check `answeredInRound` (Chainlink deprecated on new feeds — see audit L-03).
- `isResolved(marketId)` → `_resolutions[marketId].resolved`.
- `outcome(marketId)` → revert `ChainlinkOracle_NotRegistered` if config is
  missing; revert `ChainlinkOracle_AlreadyResolved` semantics is reversed:
  if not resolved, revert with… use `ChainlinkOracle_NotRegistered` only when
  config is missing, and a separate `ChainlinkOracle_NotResolvedYet` (add to
  errors) when config exists but `resolve` not called. Pick whichever is
  least confusing in tests; you decide and document the choice.
- `getConfig(marketId)` → returns the stored config (used by off-chain UIs).

#### Snapshot semantics — clarification

The current spec says `resolve` reads `latestRoundData()` at the moment it
is called, **not** the round whose `updatedAt == cfg.snapshotAt`. This means
the resolved price is "the latest price observed shortly after `snapshotAt`",
not "the price at exactly `snapshotAt`". This is the simplest implementation,
matches reference behaviour, and the staleness cap (`MAX_STALENESS`) bounds
how late the read can be relative to wall-clock.

If that's unacceptable for your market structure (e.g. you need the round
that contains a specific timestamp), **stop and ask** before designing a
historical-round lookup — that requires either `getRoundData()` round-binary-
search or a Chainlink Time-Series Feed and changes the interface.

---

## 6. Tests

### 6.1 Unit — `test/unit/ManualOracle.t.sol`

Required cases:
- `test_Constructor_GrantsAdmin`
- `test_Report_HappyPath` (admin grants reporter role first)
- `test_Report_StoresAllFields` (outcome, reporter, reportedAt, isResolved)
- `test_Outcome_ReturnsStored_True` and `_False`
- `test_Revoke_HappyPath_ResetsState`
- `test_Revoke_AllowsReReport`
- `test_Revert_Report_NotReporter`
- `test_Revert_Report_AlreadyReported`
- `test_Revert_Revoke_NotAdmin`
- `test_Revert_Revoke_NotReported`
- `test_Revert_Outcome_NotReported`
- `test_Revert_Constructor_ZeroAdmin`
- `testFuzz_Report_AnyMarketId(uint256 marketId, bool outcome)`

### 6.2 Unit — `test/unit/ChainlinkOracle.t.sol`

Build a `MockChainlinkAggregator` under `test/mocks/` that implements
`AggregatorV3Interface` and lets the test set `(answer, updatedAt)`.

Required cases:
- `test_Register_HappyPath_StoresConfig`
- `test_Register_EmitsEvent`
- `test_Resolve_GtePath_YesWins` (price ≥ threshold)
- `test_Resolve_GtePath_NoWins` (price < threshold)
- `test_Resolve_LtePath_YesWins`
- `test_Resolve_LtePath_NoWins`
- `test_Resolve_PermissionlessFromAnyCaller`
- `test_IsResolved_TrueAfterResolve`
- `test_Outcome_ReturnsStored`
- `test_Revert_Register_NotRegistrar`
- `test_Revert_Register_AlreadyRegistered`
- `test_Revert_Register_ZeroFeed`
- `test_Revert_Register_PastSnapshot`
- `test_Revert_Resolve_NotRegistered`
- `test_Revert_Resolve_AlreadyResolved`
- `test_Revert_Resolve_BeforeSnapshot`
- `test_Revert_Resolve_StalePrice` (warp so updatedAt is older than MAX_STALENESS)
- `test_Revert_Resolve_InvalidPrice` (answer = 0 and answer < 0)
- `test_Revert_Constructor_ZeroAdmin`
- `testFuzz_Resolve_ThresholdComparison(int256 threshold, int256 price, bool gte)`
  — bound inputs to a sensible range, assert outcome matches the comparator.

### 6.3 Integration — `test/integration/DiamondOracleIntegration.t.sol`

This is the proof that the oracle plugs into the real diamond.

You will need to deploy the same diamond used in
`SC/packages/diamond/test/utils/MarketFixture.sol` (read it for the recipe).
The cleanest path is:

- Add `@predix/diamond/=../diamond/src/` to `oracle/remappings.txt` **for the
  test build only** if you can — but check CLAUDE.md §2 first: the boundary
  rule says oracle MUST NOT depend on diamond. **Solution**: keep the
  remapping out of `src/`-built code; only `test/` files reference diamond
  source. If forge complains, instead duplicate the minimal diamond
  bootstrap inside the test file using `vm.getCode` / inlining, OR move this
  integration test into `SC/packages/diamond/test/integration/` where it can
  freely import oracle via a sibling remapping.
- **Confirmed acceptable approach**: put the integration test in
  `SC/packages/diamond/test/integration/OracleIntegration.t.sol` after the
  oracle package is built. That keeps oracle/`src/` boundary clean and the
  diamond's tests already have access to `@predix/oracle/=../oracle/src/`
  if you add that remapping to `diamond/remappings.txt`. **Ask before
  editing the diamond remappings file** — that's the diamond's package, not
  this one.

Required scenarios:
- Deploy `Diamond` + facets + `MarketFacet` + `MarketInit` (copy the recipe
  from `MarketFixture`).
- Deploy `ManualOracle`, approve it on the diamond, create a market with it,
  user splits, oracle reporter calls `report`, anyone calls
  `MarketFacet.resolveMarket`, user redeems → assert payout matches.
- Same flow with `ChainlinkOracle` + `MockChainlinkAggregator`.
- Negative: `resolveMarket` reverts with `Market_OracleNotResolved` if the
  oracle has not produced an answer yet.

### 6.4 General test rules

- Use `vm.expectRevert(SomeError.selector)` — never string match.
- Use `vm.expectEmit(true, true, true, true)` before emitting expected
  events.
- Cache state in `before/after` locals, not via repeated reads.
- Each `forge test --fuzz` run should finish in under a minute on a laptop.
- `forge test` must finish green before you submit.

---

## 7. Definition of Done (you cannot report "done" without all of this)

Run from `SC/packages/oracle/`:

- [ ] `forge build` — green, **no new warnings**.
- [ ] `forge test` — green (unit + fuzz + integration).
- [ ] `forge fmt --check` — clean.
- [ ] Every external/public function has ≥1 happy + ≥1 revert test.
- [ ] Every custom error declared in your interfaces has a test that
      triggers it.
- [ ] No imports from `@predix/diamond/` or any other PrediX package outside
      `@predix/shared/` (grep your `src/` to confirm).
- [ ] No `tx.origin`, no `block.timestamp` randomness, no `selfdestruct`, no
      hardcoded mainnet addresses, no inline assembly.
- [ ] NatSpec on every external/public function (via `@inheritdoc` is fine
      once the interface has it).
- [ ] Constructor on each oracle reverts on `address(0)` admin.
- [ ] `MAX_STALENESS` documented in NatSpec on `ChainlinkOracle`.
- [ ] Integration test proves the full diamond → oracle flow round-trips.

Then write a report in the format mandated by `SC/CLAUDE.md` §10.4:

```
## Summary
## Requirement → Evidence
## Files
## Tests
## Deviations from reference
## Out-of-scope findings (NOT fixed)
## Open questions
## Checklist §10.3 (A–F)
```

---

## 8. Things you will probably want to ask before coding

The user has authorised you to make every reasonable design call **except**
the ones below. If any of these matter to your implementation, **stop and
ask** instead of guessing:

1. **`MAX_STALENESS` value**: spec says 1 hour. Acceptable for daily-close
   markets, possibly too tight for low-volume feeds. Confirm or override.
2. **ChainlinkOracle snapshot semantics**: spec uses "latest price observed
   after `snapshotAt`" not "price at exactly `snapshotAt`". If markets need
   the latter, the design changes substantially — ask.
3. **Whether to add a third oracle** (e.g. UMA-style optimistic). Default:
   **no, out of scope**. Do not add it without explicit go-ahead.
4. **Whether to support multi-feed quorum** (e.g. require 2 of 3 Chainlink
   feeds to agree). Default: **no, single-feed only**. Do not add quorum
   without explicit go-ahead.
5. **`revoke` for ChainlinkOracle**: the spec only gives `revoke` to
   `ManualOracle`. ChainlinkOracle resolution is deterministic from the
   feed snapshot, so a revoke would let admin override the feed — that's
   a trust escalation and is **deliberately omitted**. Confirm before adding
   one.

---

## 9. What is explicitly NOT in scope

- Any optimistic/dispute-window oracle.
- Multi-feed aggregation, median calculation, TWAP.
- Off-chain push (e.g. signed reports a la Chainlink OCR2). Use the on-chain
  `latestRoundData()` interface only.
- Touching `SC/packages/diamond/`, `SC/packages/shared/`, or any other
  package's `src/`. If you discover that a needed symbol is missing from
  `shared/`, **stop and ask** — adding it is a separate, prior commit.
- Deployment scripts, broadcast, mainnet addresses.
- Hook / exchange / router integration.

---

## 10. Quick orientation: relevant files to read before you start

In this order:

1. `SC/CLAUDE.md` — full hard rules.
2. `SC/packages/shared/src/interfaces/IOracle.sol` — the contract you
   implement.
3. `SC/packages/diamond/src/facets/market/MarketFacet.sol` — read
   `resolveMarket`, `getMarket`, and how `m.oracle` is used. Do NOT touch
   this file.
4. `SC/packages/diamond/src/facets/market/MarketFacet.sol` admin functions
   `approveOracle` / `revokeOracle` — to understand the lifecycle of an
   oracle from the diamond's perspective.
5. `SC/packages/diamond/test/utils/MarketFixture.sol` — copy the diamond
   bootstrap recipe for your integration test.
6. `/Users/keyti/Sources/PrediX_Uni_V4/Smart_Contract_V2/src/oracle/*` —
   reference implementations. Read for behaviour, do not copy code.
7. `/Users/keyti/Sources/PrediX_Uni_V4/Smart_Contract_V2/PREDIX_AUDIT_REPORT_v2.md`
   — search for "Chainlink", "oracle", "L-03". Do not replay findings.

When you finish, the report in §10.4 format is what proves you're done.
