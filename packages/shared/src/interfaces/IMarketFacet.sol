// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

/// @title IMarketFacet
/// @notice Public interface of the PrediX market lifecycle facet: create, split, merge,
///         resolve, redeem, emergency-resolve, refund-mode, sweep, plus admin config.
interface IMarketFacet {
    /// @notice Snapshot of a market for off-chain consumers.
    /// @dev `eventId` is 0 for standalone binary markets and non-zero for markets that
    ///      belong to a multi-outcome event coordinated by `IEventFacet`.
    ///      `perMarketRedemptionFeeBps` / `redemptionFeeOverridden` expose the per-market
    ///      protocol redemption fee override (append-only, v1.3).
    struct MarketView {
        string question;
        uint256 endTime;
        address oracle;
        address creator;
        address yesToken;
        address noToken;
        uint256 totalCollateral;
        uint256 perMarketCap;
        uint256 resolvedAt;
        bool isResolved;
        bool outcome;
        bool refundModeActive;
        uint256 eventId;
        uint16 perMarketRedemptionFeeBps;
        bool redemptionFeeOverridden;
    }

    // ---------------------------------------------------------------------
    // Events
    // ---------------------------------------------------------------------

    /// @notice Emitted on every successful `createMarket` call.
    event MarketCreated(
        uint256 indexed marketId,
        address indexed creator,
        address indexed oracle,
        address yesToken,
        address noToken,
        uint256 endTime,
        string question
    );

    /// @notice Emitted on every successful `splitPosition` call.
    event PositionSplit(uint256 indexed marketId, address indexed user, uint256 amount);

    /// @notice Emitted on every successful `mergePositions` call.
    event PositionMerged(uint256 indexed marketId, address indexed user, uint256 amount);

    /// @notice Emitted when a market is resolved via the on-chain oracle pull.
    event MarketResolved(uint256 indexed marketId, bool outcome, address indexed resolver);

    /// @notice Emitted when an operator force-resolves a stalled market after the cooling-off window.
    event MarketEmergencyResolved(uint256 indexed marketId, bool outcome, address indexed resolver);

    /// @notice Emitted when a user redeems their position after resolution. `fee` is the
    ///         protocol redemption fee routed to `feeRecipient` and `payout` is the net
    ///         amount transferred to the user. `fee + payout == winningBurned`.
    event TokensRedeemed(
        uint256 indexed marketId,
        address indexed user,
        uint256 winningBurned,
        uint256 losingBurned,
        uint256 fee,
        uint256 payout
    );

    /// @notice Emitted when an admin updates the global default redemption fee.
    event DefaultRedemptionFeeUpdated(uint256 previous, uint256 current);

    /// @notice Emitted when an admin sets or clears a per-market redemption fee override.
    ///         `overridden == false` means the market reverted to the default; in that case
    ///         `bps` is reported as 0 for clarity.
    event PerMarketRedemptionFeeUpdated(uint256 indexed marketId, uint16 bps, bool overridden);

    /// @notice Emitted when an admin enables refund mode on an unresolved, ended market.
    event RefundModeEnabled(uint256 indexed marketId, address indexed enabler);

    /// @notice Emitted when a user claims a refund in refund mode.
    event MarketRefunded(
        uint256 indexed marketId, address indexed user, uint256 yesBurned, uint256 noBurned, uint256 payout
    );

    /// @notice Emitted when an admin sweeps leftover collateral after the grace period.
    event UnclaimedSwept(uint256 indexed marketId, address indexed recipient, uint256 amount);

    /// @notice Emitted when an admin adds an oracle to the approved set.
    event OracleApproved(address indexed oracle);

    /// @notice Emitted when an admin removes an oracle from the approved set.
    event OracleRevoked(address indexed oracle);

    /// @notice Emitted when the protocol fee recipient changes.
    event FeeRecipientUpdated(address indexed previous, address indexed current);

    /// @notice Emitted when the global market creation fee changes.
    event MarketCreationFeeUpdated(uint256 previous, uint256 current);

    /// @notice Emitted when the default per-market cap changes.
    event DefaultPerMarketCapUpdated(uint256 previous, uint256 current);

    /// @notice Emitted when an admin overrides a single market's per-market cap.
    event PerMarketCapUpdated(uint256 indexed marketId, uint256 previous, uint256 current);

    // ---------------------------------------------------------------------
    // Errors
    // ---------------------------------------------------------------------

    error Market_NotFound();
    error Market_EmptyQuestion();
    error Market_InvalidEndTime();
    error Market_OracleNotApproved();
    error Market_OracleNotResolved();
    error Market_AlreadyResolved();
    error Market_NotResolved();
    error Market_NotInFinalState();
    error Market_NotEnded();
    error Market_Ended();
    error Market_RefundModeActive();
    error Market_RefundModeInactive();
    error Market_TooEarlyForEmergency();
    error Market_GracePeriodNotElapsed();
    error Market_ExceedsPerMarketCap();
    error Market_ZeroAmount();
    error Market_NothingToRedeem();
    error Market_NothingToRefund();
    error Market_OracleAlreadyApproved();
    error Market_ZeroAddress();
    /// @notice Reverts when an operation on a child market would bypass the event-level
    ///         mutual-exclusion guarantee. Use the corresponding `IEventFacet` function.
    error Market_PartOfEvent();
    /// @notice Reverts when a non-CREATOR_ROLE caller invokes `createMarket`.
    ///         Admin can delegate via `AccessControlFacet.grantRole`.
    error Market_NotCreator();
    /// @notice Reverts when an admin tries to set a redemption fee above
    ///         `MAX_REDEMPTION_FEE_BPS` (15%).
    error Market_FeeTooHigh();
    /// @notice Reverts when admin tries to mutate the per-market redemption fee
    ///         after the market has reached a final state (resolved or in refund
    ///         mode). The effective fee for a market is snapshotted at creation
    ///         to protect users from retroactive mutation.
    error Market_FeeLockedAfterFinal();
    /// @notice Reverts when admin tries to set a per-market redemption fee
    ///         override above the snapshotted default fee. The override path
    ///         can only LOWER the effective fee — never raise it — so the
    ///         snapshot promise made to depositors at create-time is preserved.
    ///         Admin can still call `setDefaultRedemptionFeeBps` to raise the
    ///         global default, but it only applies to new markets (snapshot is
    ///         captured at create).
    error Market_FeeExceedsSnapshot();
    /// @notice Reverts from `sweepUnclaimed` when the market's tracked collateral
    ///         is less than the outstanding claim supply — indicates a prior
    ///         accounting violation and the sweep refuses to paper over it.
    error Market_AccountingBroken();
    /// @notice Reverts from `emergencyResolve` when the oracle has already
    ///         produced an answer. Operators must route normal resolutions
    ///         through `resolveMarket`; emergency is for genuine stalls.
    error Market_OracleResolvedUseResolve();

    // ---------------------------------------------------------------------
    // Lifecycle
    // ---------------------------------------------------------------------

    /// @notice Create a new binary market with `oracle` as its sole resolution source.
    /// @param question  Free-form market question (must be non-empty).
    /// @param endTime   Unix timestamp after which the market accepts no more splits and may be resolved.
    /// @param oracle    Address of an oracle previously added to the approved set.
    /// @return marketId Newly assigned market identifier (1-indexed, monotonic).
    function createMarket(string calldata question, uint256 endTime, address oracle) external returns (uint256 marketId);

    /// @notice Deposit `amount` USDC and receive `amount` YES + `amount` NO outcome tokens.
    /// @dev Reverts if the market is past its end time, resolved, in refund mode, or
    ///      if the resulting collateral would exceed the effective per-market cap.
    function splitPosition(uint256 marketId, uint256 amount) external;

    /// @notice Burn `amount` YES + `amount` NO and withdraw `amount` USDC. Allowed any time
    ///         before resolution or refund mode (including after end time, to give an exit).
    function mergePositions(uint256 marketId, uint256 amount) external;

    /// @notice Pull resolution from the market's oracle. Reverts if the market is not yet
    ///         ended or the oracle has not produced an answer.
    function resolveMarket(uint256 marketId) external;

    /// @notice Force-resolve a stalled market after `endTime + EMERGENCY_DELAY` (7 days).
    ///         Restricted to `OPERATOR_ROLE`. Bypasses the pause guard so an emergency
    ///         is always actionable.
    function emergencyResolve(uint256 marketId, bool outcome) external;

    /// @notice Burn the caller's full YES and NO balances for `marketId` and pay out the
    ///         winning balance 1:1 in USDC. Burning both legs prevents losing tokens from
    ///         remaining in circulation post-resolution.
    /// @return payout Amount of USDC transferred to the caller.
    function redeem(uint256 marketId) external returns (uint256 payout);

    /// @notice Enable refund mode on an unresolved, ended market. Restricted to `ADMIN_ROLE`.
    ///         Bypasses the pause guard. Once enabled, the market cannot be resolved.
    function enableRefundMode(uint256 marketId) external;

    /// @notice Burn equal YES and NO from the caller and receive that many USDC 1:1.
    /// @dev The refundable quantity is `min(yesAmount, noAmount)` — both legs must be
    ///      burned in equal measure to preserve `INV-1` when users arrive at refund
    ///      mode with asymmetric balances (e.g. after CLOB/AMM trading). Any excess
    ///      on one side is left with the user and must be matched against the other
    ///      leg (acquired on the secondary market) before it can be refunded.
    /// @return payout Amount of USDC transferred to the caller; equals `min(yesAmount, noAmount)`.
    function refund(uint256 marketId, uint256 yesAmount, uint256 noAmount) external returns (uint256 payout);

    /// @notice After `GRACE_PERIOD` (365 days) post-finalization, sweep any leftover
    ///         collateral to `feeRecipient`. Restricted to `ADMIN_ROLE`. Bypasses pause.
    /// @return amount Amount swept.
    function sweepUnclaimed(uint256 marketId) external returns (uint256 amount);

    // ---------------------------------------------------------------------
    // Admin config
    // ---------------------------------------------------------------------

    /// @notice Add `oracle` to the approved-oracle set. Restricted to `ADMIN_ROLE`.
    function approveOracle(address oracle) external;

    /// @notice Remove `oracle` from the approved set. Existing markets keep their oracle.
    function revokeOracle(address oracle) external;

    /// @notice Set the address that receives creation fees and swept residuals.
    function setFeeRecipient(address recipient) external;

    /// @notice Set the USDC fee charged on `createMarket`. `0` disables the fee.
    function setMarketCreationFee(uint256 fee) external;

    /// @notice Set the default per-market collateral cap applied to markets without an override. `0` = unlimited.
    function setDefaultPerMarketCap(uint256 cap) external;

    /// @notice Override the per-market collateral cap for a single market. `0` = use default.
    function setPerMarketCap(uint256 marketId, uint256 cap) external;

    /// @notice Set the global default redemption fee. Restricted to `ADMIN_ROLE`.
    /// @param bps Fee in basis points (10000 = 100%). Must be ≤ `MAX_REDEMPTION_FEE_BPS` (1500).
    function setDefaultRedemptionFeeBps(uint256 bps) external;

    /// @notice Override the redemption fee for a single market. Restricted to `ADMIN_ROLE`.
    ///         Setting `bps = 0` here explicitly charges 0% to the market (distinct from
    ///         falling back to the default — use `clearPerMarketRedemptionFee` for that).
    /// @param marketId Target market.
    /// @param bps      Fee in basis points; must be ≤ `MAX_REDEMPTION_FEE_BPS`.
    function setPerMarketRedemptionFeeBps(uint256 marketId, uint16 bps) external;

    /// @notice Clear a per-market redemption fee override so the market reverts to using
    ///         the global default. Restricted to `ADMIN_ROLE`. Idempotent.
    function clearPerMarketRedemptionFee(uint256 marketId) external;

    // ---------------------------------------------------------------------
    // Views
    // ---------------------------------------------------------------------

    /// @notice Read a snapshot of a market's full state.
    function getMarket(uint256 marketId) external view returns (MarketView memory);

    /// @notice Gas-optimised read of only the fields hot-path consumers (exchange, router,
    ///         hook keepers) need. Skips the `string question` allocation that dominates
    ///         `getMarket`'s gas cost on high-frequency reads.
    /// @return yesToken          Address of the YES outcome token for `marketId`.
    /// @return noToken           Address of the NO outcome token for `marketId`.
    /// @return endTime           Unix timestamp after which the market stops accepting splits.
    /// @return isResolved        Whether the market has been finalized.
    /// @return refundModeActive  Whether the market is currently in refund mode.
    function getMarketStatus(uint256 marketId)
        external
        view
        returns (address yesToken, address noToken, uint256 endTime, bool isResolved, bool refundModeActive);

    /// @notice Whether `oracle` is currently in the approved set.
    function isOracleApproved(address oracle) external view returns (bool);

    /// @notice Address that receives creation fees and swept residuals.
    function feeRecipient() external view returns (address);

    /// @notice USDC fee charged on every `createMarket` call.
    function marketCreationFee() external view returns (uint256);

    /// @notice Default per-market collateral cap. `0` = unlimited.
    function defaultPerMarketCap() external view returns (uint256);

    /// @notice Total number of markets ever created. Latest id == this value.
    function marketCount() external view returns (uint256);

    /// @notice Global default redemption fee, in basis points (10000 = 100%).
    function defaultRedemptionFeeBps() external view returns (uint256);

    /// @notice Effective redemption fee in basis points for `marketId`, collapsing the
    ///         per-market override / default decision into a single number.
    function effectiveRedemptionFeeBps(uint256 marketId) external view returns (uint256);
}
