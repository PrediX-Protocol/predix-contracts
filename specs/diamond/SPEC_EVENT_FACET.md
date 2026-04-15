# EventFacet — implementation spec

> **Read first**: this spec is self-contained but you MUST also read
> `SC/CLAUDE.md` (hard rules for the entire smart-contract subtree) before
> writing a single line of code. Anything in `CLAUDE.md` overrides this spec.
> You should ALSO skim `SC/packages/diamond/src/facets/market/MarketFacet.sol`
> and `SC/packages/diamond/test/utils/MarketFixture.sol` before you start —
> you will be touching both.

---

## 0. What you are building

PrediX currently supports **standalone binary markets** ("Will X happen?" →
YES/NO). The user wants **Polymarket-style multi-outcome events** where a
question with N possible outcomes is represented as **N linked binary
markets** under a single "event" umbrella.

Concrete examples:
- *"Who will be the next US president?"* → an **event** with N candidates.
  Each candidate (Trump, Harris, RFK, …) gets its own **binary market**
  ("Will Trump win?", "Will Harris win?", …) with its own YES/NO outcome
  tokens and its own AMM pool.
- *"Match result: A vs B"* → an **event** with 3 child markets: "Will A
  win?", "Will B win?", "Will the match draw?"

Each candidate is still a standard binary market — same `OutcomeToken` pair,
same hook, same liquidity model. The new **`EventFacet`** adds a thin
coordination layer on top that:

1. **Groups** N binary markets under a single `eventId` (shared endTime,
   shared creator, shared lifecycle).
2. **Enforces mutual exclusion at resolution time**: exactly one child market
   wins; the others lose. This happens **atomically** in a single
   transaction — no two-winner race, no partial state.
3. **Blocks individual resolution** of child markets. A market that belongs
   to an event can ONLY be resolved through `resolveEvent`.
4. **Propagates refund mode** across all children if the event cannot be
   adjudicated.

This is exactly the pattern Polymarket's `ctf-exchange` uses (verified
against the actual source code: `Polymarket/ctf-exchange/src/exchange/
mixins/Registry.sol` — tokens are registered as binary complement pairs;
N-way events are **N binary conditions grouped off-chain**). We go one step
further by enforcing mutual exclusion on-chain via `resolveEvent`.

---

## 1. Hard rules (subset of `SC/CLAUDE.md` — read the full file)

- **Toolchain**: Solidity `0.8.30`, `evm_version = cancun`, `via_ir = true`,
  `optimizer_runs = 200`. Do not change `foundry.toml`.
- **Boundary §2**: EventFacet lives in `SC/packages/diamond/`. It may
  import from `@predix/shared/`, `@openzeppelin/contracts/`, and from other
  `@predix/diamond/` libraries / interfaces. It MUST NOT import from any
  other PrediX package.
- **Diamond storage pattern §6.7**: new storage lives in a dedicated library
  with slot `keccak256("predix.storage.event.v1")`. Never reorder existing
  slots.
- **Storage layout append-only**: you WILL add a new field (`eventId`) to
  the existing `LibMarketStorage.MarketData` struct. **Append at the end.**
- **Custom errors**, no `require(string)`. Errors declared in interfaces.
- **Events** declared in interfaces, indexed where it helps indexing.
- **NatSpec** on every external/public function, struct, event, error.
  Implementation contracts use `@inheritdoc` once the interface has the doc.
- **No `tx.origin`**, no `block.timestamp` for randomness, no hardcoded
  mainnet addresses, no `selfdestruct`, no inline assembly except the
  diamond-storage slot assignment helper you already know.
- **Reentrancy**: any function that touches external calls or token
  transfers gets `nonReentrant` from `@predix/shared/utils/
  TransientReentrancyGuard.sol`.
- **SafeERC20 always** — `safeTransferFrom`, `safeTransfer`.
- **Tests**: every external function gets ≥1 happy-path test and ≥1 revert
  test; every custom error must be triggered; fuzz the numeric bits;
  invariant-test the mutual-exclusion property.
- **§5.5 scope discipline**: build exactly what this spec asks for. If you
  discover something else that "would be nice", **stop and ask** instead of
  widening scope.

---

## 2. What already exists (do not rebuild)

- **`MarketFacet`** ([src/facets/market/MarketFacet.sol](../src/facets/market/MarketFacet.sol))
  — the binary market lifecycle facet. You will modify it (carefully —
  existing tests must stay green).
- **`LibMarketStorage`** ([src/libraries/LibMarketStorage.sol](../src/libraries/LibMarketStorage.sol))
  — `MarketData` struct. You will append one field.
- **`LibConfigStorage`** — fee recipient, market creation fee, approved
  oracles. Event children reuse `marketCreationFee` (charged per candidate).
- **`LibAccessControl`** — role checks. EventFacet uses `ADMIN_ROLE` (refund
  mode) and `OPERATOR_ROLE` (resolution), same pattern as MarketFacet.
- **`LibPausable`** — module-level pause. EventFacet participates in the
  existing `Modules.MARKET` module (if the market module is paused, event
  creation and user-triggered operations are blocked).
- **`OutcomeToken`** ([../../shared/src/tokens/OutcomeToken.sol](../../shared/src/tokens/OutcomeToken.sol))
  — ERC20 + Permit, factory-only mint/burn. Each candidate still deploys
  one pair, exactly like standalone binary markets.
- **`IMarketFacet`** ([../../shared/src/interfaces/IMarketFacet.sol](../../shared/src/interfaces/IMarketFacet.sol))
  — interface of the market facet. You will add **one** error and **one**
  struct field here.
- **`MarketFixture`** ([test/utils/MarketFixture.sol](../test/utils/MarketFixture.sol))
  — test fixture that boots a full diamond with MarketFacet. You will
  extend it (not copy it) in `EventFixture`.

---

## 3. Design — files to create

```
SC/packages/diamond/
├── src/
│   ├── libraries/
│   │   ├── LibEventStorage.sol        [NEW]
│   │   ├── LibMarket.sol              [NEW  — shared market-creation helper]
│   │   └── LibMarketStorage.sol       [MODIFIED — append eventId field]
│   └── facets/
│       ├── event/
│       │   └── EventFacet.sol         [NEW]
│       └── market/
│           └── MarketFacet.sol        [MODIFIED — delegate create to LibMarket,
│                                       block event-child direct resolve, expose eventId]
├── test/
│   ├── unit/
│   │   └── EventFacet.t.sol           [NEW]
│   ├── utils/
│   │   └── EventFixture.sol           [NEW — extends MarketFixture]
│   └── invariant/
│       └── EventInvariant.t.sol       [NEW]
└── ...

SC/packages/shared/
└── src/
    └── interfaces/
        ├── IEventFacet.sol            [NEW]
        └── IMarketFacet.sol           [MODIFIED — add Market_PartOfEvent error
                                         + eventId field in MarketView]
```

---

### 3.1 `LibEventStorage.sol`

Pattern is identical to the other storage libs (`LibMarketStorage`,
`LibConfigStorage`, …). Namespaced slot, `layout()` helper, append-only.

```solidity
// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

/// @title LibEventStorage
/// @notice Diamond storage layout for the EventFacet. An "event" is a named
///         group of N binary child markets that share a deadline and whose
///         resolution is mutually exclusive.
/// @dev Layout is append-only. Never reorder, remove, or change types.
library LibEventStorage {
    bytes32 internal constant SLOT = keccak256("predix.storage.event.v1");

    struct EventData {
        string name;
        uint256[] marketIds;
        uint256 endTime;
        address creator;
        uint256 resolvedAt;
        uint256 refundEnabledAt;
        uint256 winningIndex;
        bool isResolved;
        bool refundModeActive;
    }

    struct Layout {
        uint256 eventCount;
        mapping(uint256 eventId => EventData) events;
        mapping(uint256 marketId => uint256 eventId) marketToEvent;
    }

    function layout() internal pure returns (Layout storage l) {
        bytes32 slot = SLOT;
        assembly ("memory-safe") {
            l.slot := slot
        }
    }
}
```

---

### 3.2 `LibMarketStorage.sol` — append `eventId`

The existing `MarketData` struct already holds 13 fields. Append **one**
more at the end:

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
    // append-only: added in v1.1 to support EventFacet mutual-exclusion grouping.
    // 0 = standalone binary market. Non-zero = child of the indicated event.
    uint256 eventId;
}
```

Add a NatSpec comment block above the `eventId` field stating it is
append-only (v1.1) and explaining its meaning.

---

### 3.3 `LibMarket.sol` — shared market-creation primitive

Both `MarketFacet.createMarket` (standalone) and
`EventFacet.createEvent` (grouped) need to mint a new binary market.
Extract the primitive into a library so both callers use the same code.

**Important**: this library is **trusted code**. Caller is responsible for
ALL input validation (empty question, oracle approval check, end time in
future). The library just writes storage, deploys tokens, charges the fee,
and emits the event. Do not duplicate validation; do not skip it in the
caller either.

```solidity
// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Strings} from "@openzeppelin/contracts/utils/Strings.sol";

import {IMarketFacet} from "@predix/shared/interfaces/IMarketFacet.sol";
import {OutcomeToken} from "@predix/shared/tokens/OutcomeToken.sol";

import {LibConfigStorage} from "./LibConfigStorage.sol";
import {LibMarketStorage} from "./LibMarketStorage.sol";

/// @title LibMarket
/// @notice Internal creation primitive shared by `MarketFacet.createMarket`
///         and `EventFacet.createEvent`. Trusted: caller MUST validate the
///         question, end time, and (when applicable) oracle before calling.
/// @dev Charges the protocol's `marketCreationFee` once per call. Deploys
///      one YES and one NO `OutcomeToken`, stores `MarketData`, emits
///      `IMarketFacet.MarketCreated`, and returns the new `marketId`.
library LibMarket {
    using SafeERC20 for IERC20;

    function create(
        string memory question,
        uint256 endTime,
        address oracle,
        uint256 eventId
    ) internal returns (uint256 marketId) {
        LibConfigStorage.Layout storage cfg = LibConfigStorage.layout();

        uint256 fee = cfg.marketCreationFee;
        if (fee > 0) {
            cfg.collateralToken.safeTransferFrom(msg.sender, cfg.feeRecipient, fee);
        }

        LibMarketStorage.Layout storage ms = LibMarketStorage.layout();
        marketId = ++ms.marketCount;

        string memory idStr = Strings.toString(marketId);
        OutcomeToken yes = new OutcomeToken(
            address(this),
            marketId,
            true,
            string.concat("PrediX YES #", idStr),
            string.concat("pxY-", idStr)
        );
        OutcomeToken no = new OutcomeToken(
            address(this),
            marketId,
            false,
            string.concat("PrediX NO #", idStr),
            string.concat("pxN-", idStr)
        );

        LibMarketStorage.MarketData storage m = ms.markets[marketId];
        m.question = question;
        m.endTime = endTime;
        m.oracle = oracle;
        m.creator = msg.sender;
        m.yesToken = address(yes);
        m.noToken = address(no);
        m.eventId = eventId;

        emit IMarketFacet.MarketCreated(
            marketId, msg.sender, oracle, address(yes), address(no), endTime, question
        );
    }
}
```

Notes:
- Uses `string memory` not `calldata` because `EventFacet.createEvent` will
  call with memory strings (the array element type it decodes from
  calldata).
- Emits `IMarketFacet.MarketCreated` directly from the library — Solidity
  0.8+ allows emitting events declared in an interface.
- `oracle` can be `address(0)` (event children). Caller is responsible for
  enforcing oracle approval when relevant.
- `eventId == 0` means standalone. Non-zero means event child.
- **Note on `msg.sender`**: libraries are inlined, so `msg.sender` is the
  original caller of whichever facet invoked the library. That means the
  fee is charged from the user who called `createMarket` / `createEvent`,
  which is what we want.

---

### 3.4 `MarketFacet.sol` — required modifications

**Every modification listed below is required. Do not introduce any other
changes.** Existing tests must continue to pass after your edits.

#### 3.4.1 Use `LibMarket.create` in `createMarket`

Replace the inline creation code in `createMarket` with a single call to
`LibMarket.create(question, endTime, oracle, 0)`. Keep all the pre-call
validation (empty question, `endTime <= block.timestamp`, zero oracle,
oracle not approved, module pause). Keep `nonReentrant`.

The function body after the refactor looks roughly like:

```solidity
function createMarket(string calldata question, uint256 endTime, address oracle)
    external override nonReentrant returns (uint256 marketId)
{
    LibPausable.enforceNotPaused(Modules.MARKET);
    if (bytes(question).length == 0) revert Market_EmptyQuestion();
    if (endTime <= block.timestamp) revert Market_InvalidEndTime();
    if (oracle == address(0)) revert Market_ZeroAddress();
    if (!LibConfigStorage.layout().approvedOracles[oracle]) {
        revert Market_OracleNotApproved();
    }
    marketId = LibMarket.create(question, endTime, oracle, 0);
}
```

#### 3.4.2 Block direct resolution of event-child markets

In **`resolveMarket`**, **`emergencyResolve`**, and **`enableRefundMode`**,
add a check right after the "market exists" lookup:

```solidity
if (m.eventId != 0) revert Market_PartOfEvent();
```

Place this check BEFORE any other state checks (it is the most specific
reason the caller is wrong).

Do NOT add this check to:
- `splitPosition` / `mergePositions` — users must still be able to trade
  positions on event-child markets while the event is open.
- `redeem` — users must be able to claim after the event is resolved
  (resolution is atomic via EventFacet, but redemption per-market is fine).
- `refund` — same reasoning; refund mode is set by EventFacet but each user
  redeems their position individually.
- `sweepUnclaimed` — admin sweeps each child market individually after the
  grace period. (Convenience wrapper `sweepEvent` is out of scope for v1.)

#### 3.4.3 Expose `eventId` in the `getMarket` view

Update `MarketFacet.getMarket` to include the new field in the returned
`MarketView`:

```solidity
return MarketView({
    // ... all existing fields ...
    eventId: m.eventId
});
```

#### 3.4.4 No other changes

Do not touch `splitPosition`, `mergePositions`, `redeem`, `refund`,
`sweepUnclaimed`, or any admin config function beyond what 3.4.1–3.4.3
require.

---

### 3.5 `IMarketFacet.sol` — required modifications

Add the new error:

```solidity
/// @notice Reverts when an operation on a child market would bypass the
///         event-level mutual-exclusion guarantee. The caller must use the
///         corresponding `EventFacet` function instead.
error Market_PartOfEvent();
```

Add the new field at the end of `MarketView`:

```solidity
struct MarketView {
    // ... all existing fields ...
    uint256 eventId; // 0 when the market is standalone
}
```

Update the NatSpec on `MarketView` to mention the new field.

Do NOT add `eventId` anywhere else in the interface (no new getters, no
new events).

---

### 3.6 `IEventFacet.sol`

Place at `SC/packages/shared/src/interfaces/IEventFacet.sol`.

```solidity
// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

/// @title IEventFacet
/// @notice Public interface for the PrediX multi-outcome event coordinator.
///         An event groups N binary child markets under a single id, shares
///         their end time, and resolves them atomically with exactly one
///         winning child.
interface IEventFacet {
    struct EventView {
        string name;
        uint256[] marketIds;
        uint256 endTime;
        address creator;
        uint256 resolvedAt;
        uint256 refundEnabledAt;
        uint256 winningIndex;
        bool isResolved;
        bool refundModeActive;
    }

    // -----------------------------------------------------------------------
    // Events
    // -----------------------------------------------------------------------

    /// @notice Emitted on every successful `createEvent`.
    event EventCreated(
        uint256 indexed eventId,
        address indexed creator,
        uint256 endTime,
        string name,
        uint256[] marketIds
    );

    /// @notice Emitted when `resolveEvent` settles the event. Listeners that
    ///         also watch `IMarketFacet.MarketResolved` will see one
    ///         `MarketResolved` per child market in the same transaction.
    event EventResolved(
        uint256 indexed eventId, uint256 winningIndex, address indexed resolver
    );

    /// @notice Emitted when admin enables refund mode for the whole event.
    ///         One `IMarketFacet.RefundModeEnabled` also fires for each child.
    event EventRefundModeEnabled(uint256 indexed eventId, address indexed enabler);

    // -----------------------------------------------------------------------
    // Errors
    // -----------------------------------------------------------------------

    error Event_NotFound();
    error Event_AlreadyResolved();
    error Event_NotEnded();
    error Event_RefundModeActive();
    error Event_TooFewCandidates();
    error Event_TooManyCandidates();
    error Event_InvalidWinningIndex();
    error Event_EmptyName();
    error Event_InvalidEndTime();

    // -----------------------------------------------------------------------
    // Lifecycle
    // -----------------------------------------------------------------------

    /// @notice Create a new event with N binary child markets. All children
    ///         share `endTime`, have `address(0)` as their oracle (events are
    ///         resolved by role-gated `resolveEvent`), and are marked with
    ///         the new `eventId`. Each child charges the standard
    ///         `marketCreationFee` individually, so the caller must approve
    ///         `N * marketCreationFee` USDC before calling.
    /// @param name                Event name (non-empty).
    /// @param candidateQuestions  One question per candidate. Length must
    ///                            be between 2 and 50 inclusive. Every
    ///                            question must be non-empty.
    /// @param endTime             Shared end time for every child market.
    /// @return eventId            Newly assigned monotonic event id.
    /// @return marketIds          Ids of the child markets created, in the
    ///                            same order as `candidateQuestions`.
    function createEvent(
        string calldata name,
        string[] calldata candidateQuestions,
        uint256 endTime
    ) external returns (uint256 eventId, uint256[] memory marketIds);

    /// @notice Resolve an event atomically. Sets the winning child's outcome
    ///         to `true` and every other child's outcome to `false`, all in
    ///         one transaction. Restricted to `OPERATOR_ROLE`.
    /// @param eventId        Target event.
    /// @param winningIndex   Index into the event's `marketIds` array.
    function resolveEvent(uint256 eventId, uint256 winningIndex) external;

    /// @notice Enable refund mode across every child market in an event.
    ///         Restricted to `ADMIN_ROLE`. Each child's own `refundModeActive`
    ///         flag is set; subsequently users call `IMarketFacet.refund`
    ///         on each child market they hold.
    function enableEventRefundMode(uint256 eventId) external;

    // -----------------------------------------------------------------------
    // Views
    // -----------------------------------------------------------------------

    function getEvent(uint256 eventId) external view returns (EventView memory);
    function eventOfMarket(uint256 marketId) external view returns (uint256);
    function eventCount() external view returns (uint256);
}
```

---

### 3.7 `EventFacet.sol`

Place at `SC/packages/diamond/src/facets/event/EventFacet.sol`.

#### 3.7.1 Constants

```solidity
/// @notice Minimum number of candidate binary markets per event.
uint256 internal constant MIN_CANDIDATES = 2;

/// @notice Maximum number of candidate binary markets per event. Bounds the
///         gas cost of `resolveEvent`'s per-child loop and the storage
///         footprint of `EventData.marketIds`.
uint256 internal constant MAX_CANDIDATES = 50;
```

#### 3.7.2 Inheritance and imports

Inherit `IEventFacet` and `TransientReentrancyGuard` from
`@predix/shared/utils/TransientReentrancyGuard.sol`. Import:
- `LibAccessControl`, `LibPausable`, `LibEventStorage`, `LibMarket`,
  `LibMarketStorage`
- `IMarketFacet` (for `Market_PartOfEvent` is NOT needed here, but you DO
  need to emit `IMarketFacet.MarketResolved` / `RefundModeEnabled` from
  `resolveEvent` / `enableEventRefundMode`)
- `Modules`, `Roles` from `@predix/shared/constants/`

#### 3.7.3 `createEvent`

Pseudocode:

```solidity
function createEvent(
    string calldata name,
    string[] calldata candidateQuestions,
    uint256 endTime
) external override nonReentrant returns (uint256 eventId, uint256[] memory marketIds) {
    LibPausable.enforceNotPaused(Modules.MARKET);

    // Input validation
    if (bytes(name).length == 0) revert Event_EmptyName();
    if (endTime <= block.timestamp) revert Event_InvalidEndTime();
    uint256 n = candidateQuestions.length;
    if (n < MIN_CANDIDATES) revert Event_TooFewCandidates();
    if (n > MAX_CANDIDATES) revert Event_TooManyCandidates();
    for (uint256 i; i < n; ++i) {
        if (bytes(candidateQuestions[i]).length == 0) revert Market_EmptyQuestion();
        // Using IMarketFacet.Market_EmptyQuestion is fine; no need to
        // declare a duplicate error on IEventFacet.
    }

    // Event reservation
    LibEventStorage.Layout storage es = LibEventStorage.layout();
    eventId = ++es.eventCount;
    LibEventStorage.EventData storage e = es.events[eventId];
    e.name = name;
    e.endTime = endTime;
    e.creator = msg.sender;

    // Create child markets via LibMarket — reuses the same fee / token
    // deployment / storage / event emission pipeline as standalone markets.
    marketIds = new uint256[](n);
    for (uint256 i; i < n; ++i) {
        uint256 marketId = LibMarket.create(
            candidateQuestions[i], endTime, address(0), eventId
        );
        marketIds[i] = marketId;
        e.marketIds.push(marketId);
        es.marketToEvent[marketId] = eventId;
    }

    emit EventCreated(eventId, msg.sender, endTime, name, marketIds);
}
```

Design notes:
- `createEvent` is **permissionless** (same as `createMarket`). Spam is
  gated by the `N * marketCreationFee` cost.
- Every child is created with `oracle = address(0)`. This is safe ONLY
  because `MarketFacet.resolveMarket` / `emergencyResolve` / `enableRefundMode`
  reject any market with `eventId != 0`. If you forget 3.4.2, this becomes a
  footgun — the market would be unresolvable because `address(0).isResolved`
  reverts.
- The caller is responsible for having approved
  `N * marketCreationFee` USDC to the diamond. Each `LibMarket.create`
  call pulls one fee. If approval is insufficient, the call reverts halfway
  through and the whole event creation rolls back (all child markets and
  partial state disappear). This is the correct atomicity.

#### 3.7.4 `resolveEvent`

```solidity
function resolveEvent(uint256 eventId, uint256 winningIndex) external override {
    LibAccessControl.checkRole(Roles.OPERATOR_ROLE);

    LibEventStorage.EventData storage e = _event(eventId);
    if (e.isResolved) revert Event_AlreadyResolved();
    if (e.refundModeActive) revert Event_RefundModeActive();
    if (block.timestamp < e.endTime) revert Event_NotEnded();
    uint256 n = e.marketIds.length;
    if (winningIndex >= n) revert Event_InvalidWinningIndex();

    e.isResolved = true;
    e.winningIndex = winningIndex;
    e.resolvedAt = block.timestamp;

    LibMarketStorage.Layout storage ms = LibMarketStorage.layout();
    for (uint256 i; i < n; ++i) {
        uint256 childId = e.marketIds[i];
        LibMarketStorage.MarketData storage m = ms.markets[childId];
        bool winner = (i == winningIndex);
        m.isResolved = true;
        m.outcome = winner;
        m.resolvedAt = block.timestamp;
        emit IMarketFacet.MarketResolved(childId, winner, msg.sender);
    }

    emit EventResolved(eventId, winningIndex, msg.sender);
}
```

Design notes:
- `OPERATOR_ROLE`, not `ADMIN_ROLE`. Mirrors `MarketFacet.emergencyResolve`.
- **Events are ONLY resolved manually in v1** — there is no
  `IEventOracle` pull path. The rationale is documented in §8.
- Emits `IMarketFacet.MarketResolved` for each child so existing indexers
  continue to work without changes.
- No `nonReentrant` needed — this function performs no external calls, only
  storage writes and event emissions.

#### 3.7.5 `enableEventRefundMode`

```solidity
function enableEventRefundMode(uint256 eventId) external override {
    LibAccessControl.checkRole(Roles.ADMIN_ROLE);

    LibEventStorage.EventData storage e = _event(eventId);
    if (e.isResolved) revert Event_AlreadyResolved();
    if (e.refundModeActive) revert Event_RefundModeActive();
    if (block.timestamp < e.endTime) revert Event_NotEnded();

    e.refundModeActive = true;
    e.refundEnabledAt = block.timestamp;

    LibMarketStorage.Layout storage ms = LibMarketStorage.layout();
    uint256 n = e.marketIds.length;
    for (uint256 i; i < n; ++i) {
        uint256 childId = e.marketIds[i];
        LibMarketStorage.MarketData storage m = ms.markets[childId];
        m.refundModeActive = true;
        m.refundEnabledAt = block.timestamp;
        emit IMarketFacet.RefundModeEnabled(childId, msg.sender);
    }

    emit EventRefundModeEnabled(eventId, msg.sender);
}
```

Users then call `IMarketFacet.refund(childId, yesAmt, noAmt)` on each
child they hold — no new user-facing refund entry point is added.

#### 3.7.6 Views

```solidity
function getEvent(uint256 eventId) external view override returns (EventView memory) {
    LibEventStorage.EventData storage e = _event(eventId);
    return EventView({
        name: e.name,
        marketIds: e.marketIds,
        endTime: e.endTime,
        creator: e.creator,
        resolvedAt: e.resolvedAt,
        refundEnabledAt: e.refundEnabledAt,
        winningIndex: e.winningIndex,
        isResolved: e.isResolved,
        refundModeActive: e.refundModeActive
    });
}

function eventOfMarket(uint256 marketId) external view override returns (uint256) {
    return LibEventStorage.layout().marketToEvent[marketId];
}

function eventCount() external view override returns (uint256) {
    return LibEventStorage.layout().eventCount;
}
```

#### 3.7.7 Internal helper

```solidity
function _event(uint256 eventId) private view returns (LibEventStorage.EventData storage e) {
    e = LibEventStorage.layout().events[eventId];
    if (e.creator == address(0)) revert Event_NotFound();
}
```

---

## 4. Tests

### 4.1 `EventFixture.sol`

Extends `MarketFixture`. Deploys `EventFacet` via a second `diamondCut`
after the MarketFacet cut is applied (same pattern `MarketFixture` uses to
layer market on top of the base diamond). Exposes helper functions:

```solidity
IEventFacet internal eventFacet;

function setUp() public virtual override {
    super.setUp();
    // deploy EventFacet, cut it in, bind selectors (7 total: createEvent,
    // resolveEvent, enableEventRefundMode, getEvent, eventOfMarket,
    // eventCount, plus whatever else you expose). No init contract needed
    // for this facet — no storage bootstrap required.
}

function _createThreeCandidateEvent(uint256 endTime)
    internal returns (uint256 eventId, uint256[] memory marketIds);

function _createNCandidateEvent(uint256 n, uint256 endTime)
    internal returns (uint256 eventId, uint256[] memory marketIds);
```

The fixture is responsible for funding `alice` / `bob` with enough USDC to
pay the N× market creation fee.

### 4.2 `test/unit/EventFacet.t.sol`

**Required cases** (not exhaustive — add more if you find gaps):

**`createEvent` — happy path**:
- `test_CreateEvent_TwoCandidates_StoresData`
- `test_CreateEvent_ThreeCandidates_AllChildrenPointBack` (every child's
  `eventId` matches; `eventOfMarket` returns the event id)
- `test_CreateEvent_Fifty_Candidates` (boundary at MAX_CANDIDATES)
- `test_CreateEvent_IncrementsCount`
- `test_CreateEvent_EmitsEvent_AllChildrenEmitMarketCreated`
- `test_CreateEvent_ChargesFeePerChild` (set fee = 1e6, create 3 candidates,
  assert feeRecipient received 3e6)
- `test_CreateEvent_ChildrenHaveZeroOracle`
- `test_CreateEvent_ChildrenShareEndTime`

**`createEvent` — reverts**:
- `test_Revert_CreateEvent_EmptyName`
- `test_Revert_CreateEvent_PastEndTime`
- `test_Revert_CreateEvent_TooFew` (0 and 1)
- `test_Revert_CreateEvent_TooMany` (51)
- `test_Revert_CreateEvent_EmptyCandidateQuestion` (question at index 2
  is empty — must revert with `Market_EmptyQuestion` — no partial state)
- `test_Revert_CreateEvent_MarketModulePaused`

**`resolveEvent` — happy path**:
- `test_ResolveEvent_WinnerFirst` (winningIndex = 0)
- `test_ResolveEvent_WinnerMiddle`
- `test_ResolveEvent_WinnerLast`
- `test_ResolveEvent_SetsAllChildrenOutcomes` (assert exactly one child has
  `outcome = true`, rest have `outcome = false`, all have `isResolved = true`,
  all have matching `resolvedAt`)
- `test_ResolveEvent_EmitsEventResolved_AndOneMarketResolvedPerChild`

**`resolveEvent` — reverts**:
- `test_Revert_ResolveEvent_NotOperator`
- `test_Revert_ResolveEvent_NotFound`
- `test_Revert_ResolveEvent_AlreadyResolved`
- `test_Revert_ResolveEvent_NotEnded`
- `test_Revert_ResolveEvent_InvalidWinningIndex` (index == N)
- `test_Revert_ResolveEvent_RefundModeActive` (cannot resolve after
  refund mode is enabled)

**Blocking direct individual resolution** (this is the CORE invariant):
- `test_Revert_MarketFacet_ResolveMarket_PartOfEvent`
- `test_Revert_MarketFacet_EmergencyResolve_PartOfEvent`
- `test_Revert_MarketFacet_EnableRefundMode_PartOfEvent`

Each of these tests creates an event, warps past `endTime`, then calls
the corresponding `MarketFacet` function on a child market and expects
revert with `Market_PartOfEvent`.

**`enableEventRefundMode`**:
- `test_EnableEventRefundMode_HappyPath`
- `test_EnableEventRefundMode_PropagatesToAllChildren` (every child has
  `refundModeActive == true` after the call)
- `test_EnableEventRefundMode_UsersCanRefundOnChildren` (user that split
  on child 1 before enabling refund mode can still call
  `IMarketFacet.refund(child1Id, ...)` after)
- `test_Revert_EnableEventRefundMode_NotAdmin`
- `test_Revert_EnableEventRefundMode_NotFound`
- `test_Revert_EnableEventRefundMode_AlreadyResolved`
- `test_Revert_EnableEventRefundMode_NotEnded`
- `test_Revert_EnableEventRefundMode_RefundModeActive` (second call)

**Child-market interaction**:
- `test_SplitPosition_OnEventChild_Works` (users can still split before
  resolution)
- `test_MergePositions_OnEventChild_Works`
- `test_Redeem_OnEventChild_AfterEventResolve_PaysOut` — user splits 100
  USDC on winner, event resolves, user redeems → gets 100 USDC
- `test_Redeem_OnEventChild_AfterEventResolve_LoserGetsNothing`
- `test_SweepUnclaimed_OnEventChild_AfterGrace` (admin can still sweep each
  child individually after the 365-day grace)

**Views**:
- `test_GetEvent_ReturnsCorrectSnapshot`
- `test_EventOfMarket_ReturnsParent`
- `test_EventOfMarket_StandaloneReturnsZero`
- `test_EventCount_MonotonicIncrement`

**Fuzz**:
- `testFuzz_CreateEvent_AnyValidCandidateCount(uint8 nRaw)` — bound
  `nRaw` into `[MIN_CANDIDATES, MAX_CANDIDATES]`, create event, assert
  all children are linked back.
- `testFuzz_ResolveEvent_AnyWinningIndex(uint8 nRaw, uint8 winIdxRaw)` —
  fuzz both, assert the correct child wins and all others lose.

### 4.3 `test/invariant/EventInvariant.t.sol`

Set up a handler that randomly creates events, splits / merges on random
child markets, and (with some probability) resolves events. The following
invariants MUST hold at all times:

- `invariant_EventChildAlwaysPointsBack`: for every event `e` and every
  `childId` in `e.marketIds`, `marketToEvent[childId] == eventId`.
- `invariant_ResolvedEventExactlyOneWinner`: for every resolved event,
  count child markets with `outcome == true` → must equal 1; count with
  `outcome == false` → must equal `N - 1`.
- `invariant_EventChildrenShareEndTime`: every child of every event has
  `market.endTime == event.endTime`.
- `invariant_EventChildrenHaveZeroOracle`: every child market has
  `m.oracle == address(0)` (regression guard — proves the code did not
  accidentally approve a real oracle for event children).
- `invariant_BinaryInvariantHoldsPerChild`: for every unresolved child
  market, `YES.totalSupply == NO.totalSupply == m.totalCollateral`. (This
  is the same invariant from `MarketInvariantTest` but applied to event
  children — it must survive the grouping layer.)

Keep the handler small (≤150 lines). Target 3–5 invariants max.

---

## 5. Definition of done

Run from `SC/packages/diamond/`:

- [ ] `forge build` — green, no new warnings.
- [ ] `forge test` — green. Existing 132+ tests from previous phases plus
      all new EventFacet tests pass.
- [ ] `forge fmt --check` — clean.
- [ ] `forge build` also green from `SC/packages/shared/` (`IMarketFacet`
      / `IEventFacet` changes don't break shared).
- [ ] Every external / public function on `EventFacet` has ≥1 happy test
      + ≥1 revert test.
- [ ] Every custom error in `IEventFacet` has a test that triggers it.
- [ ] The three "direct-resolution-blocked" tests (§4.2) all pass —
      this is the core on-chain mutual-exclusion guarantee.
- [ ] Invariant suite from §4.3 runs 256 × 500 calls with 0 reverts.
- [ ] NatSpec complete on every external / public function, struct,
      event, error in both `IEventFacet` and the new fields added to
      `IMarketFacet` / `MarketView`.
- [ ] No imports from outside `@openzeppelin`, `@predix/shared`, and
      `@predix/diamond`. Grep `src/facets/event/` and
      `src/libraries/LibEvent*` and `src/libraries/LibMarket.sol` to
      confirm.
- [ ] Report written in the `CLAUDE.md §10.4` format with a
      `Requirement → Evidence` mapping for each numbered section in
      §3 above.

---

## 6. Out of scope — do NOT build any of these

- **`IEventOracle` pull-based resolution.** Events are resolved manually
  by `OPERATOR_ROLE` in v1. Adding an oracle adapter for events is Phase 2.
- **`sweepEvent(eventId)` convenience wrapper.** Admin sweeps each child
  individually. Add in Phase 2 if needed.
- **Market creation fee discount for events.** Each child is charged the
  full `marketCreationFee`. User confirmed.
- **Allowing non-`address(0)` oracles for event children.** Every child
  always has oracle = 0.
- **Emergency-resolve-event with a grace period.** There is only one
  resolution entry point: `resolveEvent`, gated on OPERATOR_ROLE + passed
  endTime. No separate emergency path.
- **Cross-event splits / merges (buying "all losers" in one tx).** Each
  user trades each child market independently.
- **On-chain probability / price aggregation across children.** Off-chain
  indexer computes the implied probabilities from each child's pool state.
- **Dropping or renaming `IMarketFacet.MarketCreated` / `MarketResolved` /
  `RefundModeEnabled` events** — EventFacet reuses them so indexers keep
  working.
- **Modifying tests in other packages.** Only `SC/packages/diamond/` and
  the two noted `IMarketFacet` / new `IEventFacet` files in
  `SC/packages/shared/src/interfaces/` are in scope.

---

## 7. Execution order

Suggested sequence. Build incrementally; run `forge build && forge test`
after each step so failures stay local.

1. **`IMarketFacet` update** — add `Market_PartOfEvent` error + `eventId`
   field in `MarketView`. `forge build` — should fail only where
   `MarketFacet.getMarket` constructs `MarketView` (you'll fix that in
   step 2).
2. **`LibMarketStorage` update** — append `eventId` to `MarketData`.
3. **`LibMarket.sol`** — new shared creation library. No changes to
   MarketFacet yet. `forge build` — library should compile standalone.
4. **`MarketFacet` refactor** — switch `createMarket` to delegate to
   `LibMarket.create`, add the three `Market_PartOfEvent` checks, update
   `getMarket` to include `eventId`. `forge build` — should compile.
   `forge test` — existing 132 tests MUST all still pass. If they don't,
   diagnose before moving on.
5. **`IEventFacet.sol`** — new interface. `forge build`.
6. **`LibEventStorage.sol`** — new storage lib. `forge build`.
7. **`EventFacet.sol`** — the implementation. `forge build`.
8. **`EventFixture.sol`** — test fixture. `forge build`.
9. **`EventFacet.t.sol`** — unit tests. Write incrementally by section
   (happy, reverts, direct-resolution-blocked, refund mode, views, fuzz).
   Run `forge test --match-contract EventFacet` after each section.
10. **`EventInvariant.t.sol`** — invariants last. Tune handler weights if
    invariants fail — a failure here means the core contract logic is
    wrong, not the test.
11. **Final pass** — `forge fmt`, `forge build` (no warnings), `forge test`
    (everything green), write the `§10.4` report.

---

## 8. Questions to pause and ask if unclear

The reviewer has pre-answered these (all six decisions are locked — see
below). Do NOT re-open them, but flag IMMEDIATELY if you find a technical
reason the answer cannot hold:

1. **`MAX_CANDIDATES = 50`** — confirmed. Gas cost of a 50-child
   `resolveEvent` loop should fit comfortably within block gas. Spot-
   check: each child update is ~3 storage writes + 1 event = ~25k gas.
   50 children ≈ 1.25M gas. Fine.
2. **Fee = N × `marketCreationFee` per event** — confirmed. No discount.
3. **Role-gated `resolveEvent` via OPERATOR_ROLE, no oracle adapter in v1**
   — confirmed. Oracle-driven event resolution is Phase 2.
4. **Binary standalone markets still work unchanged** — confirmed. Tests
   from previous phases must stay green.
5. **Pool per candidate (not pool shared across the event)** — confirmed.
   Each child is a standard binary market with its own YES/NO pair and
   its own pool; the hook treats it exactly like any other binary market.
6. **Polymarket-like UX verified in the actual repo**: `Polymarket/ctf-
   exchange/src/exchange/mixins/Registry.sol` registers tokens as
   complement pairs (YES/NO per condition), and multi-outcome events are
   N binary conditions grouped off-chain. We do the same but enforce the
   grouping on-chain via EventFacet.

If you hit ambiguity NOT covered by this spec or the six locked decisions,
**stop and ask** rather than guess. Examples of things that would
legitimately warrant a pause:

- You discover that emitting `IMarketFacet.MarketCreated` from a library
  doesn't compile in the current solc (should work in 0.8.30, but verify).
- You find that adding `eventId` to `MarketData` breaks a test in a way
  you cannot fix without changing semantics.
- A reader could reasonably interpret "event" as "Solidity event" and
  get confused with `emit` — consider whether NatSpec needs to disambiguate.

---

## 9. Report format

After you finish, write the report in the `CLAUDE.md §10.4` format:

```
## Summary
<1-2 sentences>

## Requirement → Evidence
- §3.1 LibEventStorage → src/libraries/LibEventStorage.sol
- §3.2 LibMarketStorage eventId → src/libraries/LibMarketStorage.sol:<line>
- §3.3 LibMarket.create → src/libraries/LibMarket.sol
- §3.4.1 MarketFacet.createMarket delegation → src/facets/market/MarketFacet.sol:<line>
- §3.4.2 Market_PartOfEvent checks → src/facets/market/MarketFacet.sol:<line1>, :<line2>, :<line3>
- §3.4.3 MarketView.eventId → src/facets/market/MarketFacet.sol:<line>
- §3.5 IMarketFacet updates → packages/shared/src/interfaces/IMarketFacet.sol:<line>
- §3.6 IEventFacet → packages/shared/src/interfaces/IEventFacet.sol
- §3.7 EventFacet → src/facets/event/EventFacet.sol
- Tests: EventFacet.t.sol (N unit, M fuzz), EventInvariant.t.sol (K invariants)

## Files
- Added: <list>
- Modified: <list>
- Shared additions: Market_PartOfEvent error, MarketView.eventId field, IEventFacet

## Tests
- Unit: <count>
- Fuzz: <count>
- Invariant: <names>
- Full suite status: X passed / 0 failed

## Deviations from spec
- <anywhere you diverged, with justification>

## Out-of-scope findings (NOT fixed)
- <anything you noticed but did not address>

## Open questions
- <anything still needing user confirmation>

## Checklist §10.3
- A. Requirement tracing: ✅ / ❌
- B. Build & test: ✅ / ❌
- C. Clean code: ✅ / ❌
- D. Security: ✅ / ❌
- E. Boundary: ✅ / ❌
- F. Documentation: ✅ / ❌
```

Push back on anything in this spec that looks wrong once you're in the
code. The implementer has the full picture after building it —
document any disagreement and propose the fix.
