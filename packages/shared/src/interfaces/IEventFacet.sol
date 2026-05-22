// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import {EmergencyReason} from "@predix/shared/constants/EmergencyReason.sol";

/// @title IEventFacet
/// @notice Public interface for the PrediX multi-outcome event coordinator. An event
///         groups N binary child markets under a single id, shares their end time,
///         and resolves them atomically with exactly one winning child. Every child
///         is a standard binary market with its own YES/NO outcome token pair — the
///         event layer only enforces grouping and mutual exclusion at resolution time.
interface IEventFacet {
    /// @notice Snapshot of an event for off-chain consumers.
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
        address oracle;
    }

    // ---------------------------------------------------------------------
    // Events
    // ---------------------------------------------------------------------

    /// @notice Emitted on every successful `createEvent` call. Each child market also
    ///         emits its own `IMarketFacet.MarketCreated` in the same transaction.
    event EventCreated(
        uint256 indexed eventId,
        address indexed creator,
        uint256 endTime,
        string name,
        uint256[] marketIds,
        address oracle
    );

    /// @notice Emitted when `resolveEvent` settles the event. One
    ///         `IMarketFacet.MarketResolved` also fires per child in the same tx.
    event EventResolved(uint256 indexed eventId, uint256 winningIndex, address indexed resolver);

    /// @notice Emitted when an operator emergency-resolves an event after the
    ///         oracle stalls past the grace period.
    /// @param reason Classification of why the oracle was bypassed — enables
    ///        off-chain monitoring to distinguish routine stall recovery from
    ///        suspicious operator action.
    event EventEmergencyResolved(
        uint256 indexed eventId,
        uint256 winningIndex,
        address indexed resolver,
        EmergencyReason.Reason reason
    );

    /// @notice Emitted when an admin enables refund mode for the whole event. One
    ///         `IMarketFacet.RefundModeEnabled` also fires per child in the same tx.
    event EventRefundModeEnabled(uint256 indexed eventId, address indexed enabler);

    /// @notice Emitted per-child when `sweepUnclaimedEvent` recovers residual collateral.
    event EventChildSwept(uint256 indexed eventId, uint256 indexed childMarketId, uint256 amount);

    /// @notice Emitted when a new outcome (child market) is appended to a live event.
    ///         The child also emits its own `IMarketFacet.MarketCreated` in the same tx.
    event EventOutcomeAdded(uint256 indexed eventId, uint256 indexed marketId, string question);

    // ---------------------------------------------------------------------
    // Errors
    // ---------------------------------------------------------------------

    error Event_NotFound();
    error Event_AlreadyResolved();
    error Event_NotEnded();
    error Event_RefundModeActive();
    error Event_TooFewCandidates();
    error Event_TooManyCandidates();
    error Event_InvalidWinningIndex();
    error Event_EmptyName();
    error Event_InvalidEndTime();
    /// @notice Reverts when a non-CREATOR_ROLE caller invokes `createEvent`.
    error Event_NotCreator();
    error Event_ZeroOracle();
    error Event_OracleNotApproved();
    /// @notice Reverts when the oracle passed to `createEvent` does not advertise
    ///         `IEventOracle` via ERC-165. An event bound to a binary-only oracle
    ///         could never settle through `resolveEvent`, leaving it stuck until
    ///         emergency resolution.
    error Event_OracleNotEventCapable();
    error Event_OracleNotResolved();
    error Event_TooEarlyForEmergency();
    error Event_OracleResolvedUseResolve();
    /// @notice Reverts when `addEventOutcome` is called on an event whose `endTime`
    ///         has already passed. Outcomes may only be appended while the event is
    ///         still live so every child shares an identical, future deadline.
    error Event_Ended();

    // ---------------------------------------------------------------------
    // Lifecycle
    // ---------------------------------------------------------------------

    /// @notice Create a new event with N binary child markets. All children share
    ///         `endTime` and are marked with the new `eventId`. The event stores
    ///         the oracle address for resolution — child markets have `oracle = address(0)`
    ///         since they resolve atomically via the event's oracle.
    /// @param name                Event name (non-empty).
    /// @param candidateQuestions  One question per candidate. Length must be in
    ///                            `[2, 50]`. Every question must be non-empty.
    /// @param endTime             Shared end time for every child market.
    /// @param oracle              Oracle contract implementing `IEventOracle`. Must
    ///                            be in the diamond's approved-oracles set.
    /// @return eventId            Newly assigned monotonic event id.
    /// @return marketIds          Ids of the child markets created, in the same
    ///                            order as `candidateQuestions`.
    function createEvent(string calldata name, string[] calldata candidateQuestions, uint256 endTime, address oracle)
        external
        returns (uint256 eventId, uint256[] memory marketIds);

    /// @notice Append one outcome (child market) to an existing live event. The new
    ///         child inherits the event's `endTime`, its collective oracle
    ///         (`oracle = address(0)`, resolved via the event), and `eventId`, so it
    ///         stays consistent with the existing candidates. Restricted to
    ///         `CREATOR_ROLE`. Charges `marketCreationFee` like any market creation.
    /// @dev    Callable only while the event is live: not resolved, not in refund
    ///         mode, and `block.timestamp < endTime`. Bounded by `MAX_CANDIDATES`.
    ///         Adding a candidate mid-event dilutes the implied probability of
    ///         existing positions — an intentional property of "open" events.
    /// @param eventId  Target event.
    /// @param question The new candidate's question (non-empty).
    /// @return marketId The newly created child market id (appended to the event).
    function addEventOutcome(uint256 eventId, string calldata question) external returns (uint256 marketId);

    /// @notice Resolve an event atomically by reading the outcome from its oracle.
    ///         Permissionless — anyone may call once the oracle has reported.
    ///         Sets the winning child's outcome to `true` and every other child's
    ///         outcome to `false`, all in one transaction.
    /// @param eventId Target event.
    function resolveEvent(uint256 eventId) external;

    /// @notice Emergency-resolve an event when the oracle stalls. Restricted to
    ///         `OPERATOR_ROLE`. Only callable after `endTime + EMERGENCY_DELAY`.
    ///         Reverts if the oracle has since produced an answer.
    /// @param eventId       Target event.
    /// @param winningIndex  Index into the event's `marketIds` array.
    function emergencyResolveEvent(uint256 eventId, uint256 winningIndex) external;

    /// @notice Enable refund mode across every child market in an event. Restricted
    ///         to `ADMIN_ROLE`. Each child's `refundModeActive` flag is set;
    ///         subsequently users call `IMarketFacet.refund` on each child they hold.
    function enableEventRefundMode(uint256 eventId) external;

    /// @notice Sweep unclaimed collateral from all child markets of a finalized
    ///         event in a single transaction. Restricted to `ADMIN_ROLE`. Each child
    ///         must be in a final state (resolved or refund-mode) and past GRACE_PERIOD.
    /// @return total Total USDC swept across all children.
    function sweepUnclaimedEvent(uint256 eventId) external returns (uint256 total);

    // ---------------------------------------------------------------------
    // Views
    // ---------------------------------------------------------------------

    /// @notice Read a snapshot of an event's full state.
    function getEvent(uint256 eventId) external view returns (EventView memory);

    /// @notice Return the event id a market belongs to, or `0` if it is standalone.
    function eventOfMarket(uint256 marketId) external view returns (uint256);

    /// @notice Lightweight status view consumed by oracles for timing gates.
    function getEventStatus(uint256 eventId)
        external
        view
        returns (uint256 endTime, uint256 candidateCount, bool isResolved, bool refundModeActive);

    /// @notice Total number of events ever created. Latest id == this value.
    function eventCount() external view returns (uint256);
}
