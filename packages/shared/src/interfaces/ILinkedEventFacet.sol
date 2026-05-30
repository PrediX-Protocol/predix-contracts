// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

/// @title ILinkedEventFacet
/// @notice Shared-collateral (NegRisk-style) multi-outcome events. One USDC pool
///         (`eventPool[eventId]`) backs N mutually-exclusive outcomes. Each outcome is a binary child
///         market with its own YES/NO clone, so it trades on the same AMM pools and CLOB books as any
///         standalone market. `mintCompleteSet` / `redeemCompleteSet` make `Σ YES → $1` enforceable by
///         arbitrage. Per-outcome split/merge is performed through `IMarketFacet.splitPosition` /
///         `mergePositions` on the child `marketId` (those functions are linked-aware and route
///         collateral to the shared pool); there is intentionally no `splitOutcome`/`mergeOutcome` here.
///         Resolution reuses `IEventFacet.resolveEvent` / `emergencyResolveEvent`.
interface ILinkedEventFacet {
    /// @notice Emitted once per `createLinkedEvent`. Each child market also emits its own
    ///         `IMarketFacet.MarketCreated` in the same transaction.
    /// @param eventId   Newly assigned event id.
    /// @param creator   Caller (holds `CREATOR_ROLE`).
    /// @param endTime   Shared end time of every child market.
    /// @param marketIds Child market ids, in candidate order.
    /// @param oracle    `IEventOracle` bound to the event for atomic resolution.
    event LinkedEventCreated(
        uint256 indexed eventId, address indexed creator, uint256 endTime, uint256[] marketIds, address oracle
    );

    /// @notice Emitted when a complete set is minted (one YES of every outcome) against the pool.
    /// @param eventId Target event.
    /// @param user    Caller who deposited `amount` USDC.
    /// @param amount  USDC deposited; also the YES amount minted per outcome.
    event CompleteSetMinted(uint256 indexed eventId, address indexed user, uint256 amount);

    /// @notice Emitted when a complete set is redeemed (burn one YES of every outcome for USDC).
    /// @param eventId Target event.
    /// @param user    Caller.
    /// @param amount  USDC returned; also the YES amount burned per outcome.
    event CompleteSetRedeemed(uint256 indexed eventId, address indexed user, uint256 amount);

    /// @notice Emitted when a holder redeems a resolved linked event from the shared pool.
    /// @param eventId    Target event.
    /// @param user       Caller.
    /// @param grossClaim Winning-YES + losing-NO burned (the gross pool draw).
    /// @param fee        Redemption fee routed to the protocol fee recipient.
    /// @param payout     Net USDC transferred to the caller (`grossClaim - fee`).
    event LinkedRedeemed(
        uint256 indexed eventId, address indexed user, uint256 grossClaim, uint256 fee, uint256 payout
    );

    /// @notice Reverts when the event id does not exist.
    error LinkedEvent_NotFound();
    /// @notice Reverts when the event id exists but is not a shared-collateral (linked) event.
    error LinkedEvent_NotLinked();
    /// @notice Reverts when an op requires the event to be unresolved but it is already resolved.
    error LinkedEvent_AlreadyResolved();
    /// @notice Reverts when `redeemLinked` is called before the event is resolved.
    error LinkedEvent_NotResolved();
    /// @notice Reverts when an op is attempted while the event is in refund mode (defensive; refund mode
    ///         is unreachable for linked events in v1 — see `IEventFacet.Event_LinkedNoRefund`).
    error LinkedEvent_RefundModeActive();
    /// @notice Reverts when a pre-resolution mint/split op is attempted after the event `endTime`.
    error LinkedEvent_Ended();
    /// @notice Reverts when an amount argument is zero.
    error LinkedEvent_ZeroAmount();
    /// @notice Reverts when `redeemLinked` finds the caller holds no winning-YES or losing-NO to claim.
    error LinkedEvent_NothingToRedeem();
    /// @notice Reverts when the shared pool is smaller than the gross claim — an accounting tripwire that
    ///         must never fire if the solvency invariant holds (`pool == Σ NO_i + M`).
    error LinkedEvent_PoolInsolvent();

    /// @notice Create a shared-collateral event with N binary child markets sharing one USDC pool.
    /// @param name               Event name (non-empty).
    /// @param candidateQuestions One question per outcome; length in `[2, 50]`, each non-empty.
    /// @param endTime            Shared end time for every child market (must be in the future).
    /// @param oracle             Approved oracle implementing `IEventOracle`.
    /// @return eventId           Newly assigned event id.
    /// @return marketIds         Child market ids in candidate order.
    function createLinkedEvent(
        string calldata name,
        string[] calldata candidateQuestions,
        uint256 endTime,
        address oracle
    ) external returns (uint256 eventId, uint256[] memory marketIds);

    /// @notice Deposit `amount` USDC into the pool and mint `amount` YES of EVERY outcome (a complete set).
    /// @param eventId Target linked event (unresolved, not ended).
    /// @param amount  USDC to deposit; must be non-zero.
    function mintCompleteSet(uint256 eventId, uint256 amount) external;

    /// @notice Burn `amount` YES of EVERY outcome and withdraw `amount` USDC from the pool.
    /// @param eventId Target linked event (unresolved).
    /// @param amount  Complete-set size to redeem; must be non-zero and held in full across all outcomes.
    function redeemCompleteSet(uint256 eventId, uint256 amount) external;

    /// @notice After resolution, burn the caller's winning-YES and losing-NO and pay out from the pool.
    /// @param eventId Target linked event (resolved).
    /// @return payout Net USDC transferred to the caller (`grossClaim - fee`).
    function redeemLinked(uint256 eventId) external returns (uint256 payout);

    /// @notice Current shared-pool balance (USDC base units) backing `eventId`.
    function eventPoolOf(uint256 eventId) external view returns (uint256);

    /// @notice Whether `eventId` is a shared-collateral (linked) event.
    function isLinkedEvent(uint256 eventId) external view returns (bool);
}
