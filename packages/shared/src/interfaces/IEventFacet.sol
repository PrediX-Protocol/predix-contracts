// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

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
    }

    // ---------------------------------------------------------------------
    // Events
    // ---------------------------------------------------------------------

    /// @notice Emitted on every successful `createEvent` call. Each child market also
    ///         emits its own `IMarketFacet.MarketCreated` in the same transaction.
    event EventCreated(
        uint256 indexed eventId, address indexed creator, uint256 endTime, string name, uint256[] marketIds
    );

    /// @notice Emitted when `resolveEvent` settles the event. One
    ///         `IMarketFacet.MarketResolved` also fires per child in the same tx.
    event EventResolved(uint256 indexed eventId, uint256 winningIndex, address indexed resolver);

    /// @notice Emitted when an admin enables refund mode for the whole event. One
    ///         `IMarketFacet.RefundModeEnabled` also fires per child in the same tx.
    event EventRefundModeEnabled(uint256 indexed eventId, address indexed enabler);

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
    /// @notice SPEC-03 Phase 1-2: reverts when a non-CREATOR_ROLE caller invokes
    ///         `createEvent`. Mirrors `Market_NotCreator` for the event path.
    error Event_NotCreator();

    // ---------------------------------------------------------------------
    // Lifecycle
    // ---------------------------------------------------------------------

    /// @notice Create a new event with N binary child markets. All children share
    ///         `endTime`, have `address(0)` as their oracle (events are resolved by
    ///         role-gated `resolveEvent`), and are marked with the new `eventId`.
    ///         Each child is charged the standard `marketCreationFee` individually,
    ///         so the caller must have approved `N * marketCreationFee` collateral.
    /// @param name                Event name (non-empty).
    /// @param candidateQuestions  One question per candidate. Length must be in
    ///                            `[2, 50]`. Every question must be non-empty.
    /// @param endTime             Shared end time for every child market.
    /// @return eventId            Newly assigned monotonic event id.
    /// @return marketIds          Ids of the child markets created, in the same
    ///                            order as `candidateQuestions`.
    function createEvent(string calldata name, string[] calldata candidateQuestions, uint256 endTime)
        external
        returns (uint256 eventId, uint256[] memory marketIds);

    /// @notice Resolve an event atomically. Sets the winning child's outcome to `true`
    ///         and every other child's outcome to `false`, all in one transaction.
    ///         Restricted to `OPERATOR_ROLE`.
    /// @param eventId       Target event.
    /// @param winningIndex  Index into the event's `marketIds` array.
    function resolveEvent(uint256 eventId, uint256 winningIndex) external;

    /// @notice Enable refund mode across every child market in an event. Restricted
    ///         to `ADMIN_ROLE`. Each child's `refundModeActive` flag is set;
    ///         subsequently users call `IMarketFacet.refund` on each child they hold.
    function enableEventRefundMode(uint256 eventId) external;

    // ---------------------------------------------------------------------
    // Views
    // ---------------------------------------------------------------------

    /// @notice Read a snapshot of an event's full state.
    function getEvent(uint256 eventId) external view returns (EventView memory);

    /// @notice Return the event id a market belongs to, or `0` if it is standalone.
    function eventOfMarket(uint256 marketId) external view returns (uint256);

    /// @notice Total number of events ever created. Latest id == this value.
    function eventCount() external view returns (uint256);
}
