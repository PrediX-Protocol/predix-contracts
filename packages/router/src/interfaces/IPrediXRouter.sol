// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {IAllowanceTransfer} from "permit2/src/interfaces/IAllowanceTransfer.sol";

/// @title IPrediXRouter
/// @notice Public interface of the PrediX user-facing aggregator that routes binary
///         prediction-market trades between the PrediX CLOB (`PrediXExchange`) and
///         the matching Uniswap v4 pool (registered with `PrediXHookV2`).
/// @dev Stateless, permissionless. CLOB is tried first, AMM takes the remainder, unused
///      input is refunded to `msg.sender`. The router holds no funds between transactions —
///      every entry function enforces a zero-balance invariant on exit.
interface IPrediXRouter {
    // =========================================================================
    // Types
    // =========================================================================

    /// @notice Trade classification emitted on every successful router call.
    enum TradeType {
        BUY_YES,
        SELL_YES,
        BUY_NO,
        SELL_NO
    }

    // =========================================================================
    // Errors
    // =========================================================================

    /// @notice Thrown when any constructor argument is the zero address.
    error ZeroAddress();

    /// @notice Thrown when the user supplies a zero or below-minimum input amount.
    error ZeroAmount();

    /// @notice Thrown when the supplied `deadline` has already passed.
    error DeadlineExpired(uint256 deadline, uint256 currentTime);

    /// @notice Thrown when the aggregate filled amount is below the user's `minOut` bound.
    error InsufficientOutput(uint256 actual, uint256 minimum);

    /// @notice Thrown when neither CLOB nor AMM filled any portion of the request.
    error ExactInUnfilled(uint256 amountIn);

    /// @notice Thrown when `getMarketStatus` returns the zero-address sentinel for `yesToken`.
    error MarketNotFound();

    /// @notice Thrown when the market has already been resolved.
    error MarketResolved();

    /// @notice Thrown when `block.timestamp >= market.endTime`.
    error MarketExpired();

    /// @notice Thrown when the market has been placed into refund mode by an admin.
    error MarketInRefundMode();

    /// @notice Thrown when the diamond's MARKET module (or the global pause flag) is set.
    error MarketModulePaused();

    /// @notice Thrown when `recipient` is zero, the router itself, or any PrediX infrastructure
    ///         address (diamond, exchange, hook, poolManager, quoter, permit2).
    error InvalidRecipient();

    /// @notice Thrown when `unlockCallback` is invoked by anyone other than the PoolManager.
    error OnlyPoolManager();

    /// @notice Thrown when the v4 pool for a market has no liquidity (Quoter returns zero).
    error PoolNotInitialized();

    /// @notice Thrown when the combined CLOB + AMM depth cannot satisfy the trade within the
    ///         `buyNo` / `sellNo` virtual-NO 3% safety margin.
    error InsufficientLiquidity();

    /// @notice Thrown when the Permit2 permit references a token other than the one the
    ///         router is about to pull.
    error InvalidPermitToken();

    /// @notice Thrown when `permitSingle.details.amount < amount` for the current call.
    error InsufficientPermitAllowance();

    /// @notice Defensive invariant: the router's balance of a token MUST be zero after a call
    ///         settles. A non-zero residue means accounting drifted — revert hard instead of
    ///         silently stranding the dust.
    error FinalizeBalanceNonZero();

    /// @notice Thrown when the virtual-NO path's re-quote after computing `mintAmount` falls
    ///         outside the 3% safety margin. Documents the economic bound for the caller.
    error QuoteOutsideSafetyMargin();

    /// @notice Thrown when a `buyNo` / `sellNo` mint amount would breach the market's
    ///         `perMarketCap` collateral ceiling.
    error PerMarketCapExceeded();

    // =========================================================================
    // Events
    // =========================================================================

    /// @notice Emitted once per successful `buy*` / `sell*` call. `clobFilled + ammFilled == amountOut`.
    event Trade(
        uint256 indexed marketId,
        address indexed trader,
        address indexed recipient,
        TradeType tradeType,
        uint256 amountIn,
        uint256 amountOut,
        uint256 clobFilled,
        uint256 ammFilled
    );

    /// @notice Emitted when the router returns unused input to `msg.sender` at the end of a trade.
    event DustRefunded(address indexed recipient, address indexed token, uint256 amount);

    // =========================================================================
    // Exact-in trade primitives
    // =========================================================================

    /// @notice Spend `usdcIn` USDC to acquire at least `minYesOut` YES tokens on `marketId`.
    function buyYes(
        uint256 marketId,
        uint256 usdcIn,
        uint256 minYesOut,
        address recipient,
        uint256 maxFills,
        uint256 deadline
    ) external returns (uint256 yesOut, uint256 clobFilled, uint256 ammFilled);

    /// @notice Sell `yesIn` YES tokens for at least `minUsdcOut` USDC on `marketId`.
    function sellYes(
        uint256 marketId,
        uint256 yesIn,
        uint256 minUsdcOut,
        address recipient,
        uint256 maxFills,
        uint256 deadline
    ) external returns (uint256 usdcOut, uint256 clobFilled, uint256 ammFilled);

    /// @notice Spend `usdcIn` USDC to acquire at least `minNoOut` NO tokens on `marketId`.
    /// @dev Executed via the virtual-NO path: split USDC → YES+NO, swap YES→USDC on the v4
    ///      pool, deliver NO to `recipient`, refund USDC. A 3% safety margin is applied to
    ///      the Quoter-derived mint amount to absorb price impact between quote and execute.
    function buyNo(
        uint256 marketId,
        uint256 usdcIn,
        uint256 minNoOut,
        address recipient,
        uint256 maxFills,
        uint256 deadline
    ) external returns (uint256 noOut, uint256 clobFilled, uint256 ammFilled);

    /// @notice Sell `noIn` NO tokens for at least `minUsdcOut` USDC on `marketId`.
    /// @dev Executed via the virtual-NO path: swap USDC→YES on the v4 pool (sized via Quoter),
    ///      merge YES+NO → USDC, pay `recipient`.
    function sellNo(
        uint256 marketId,
        uint256 noIn,
        uint256 minUsdcOut,
        address recipient,
        uint256 maxFills,
        uint256 deadline
    ) external returns (uint256 usdcOut, uint256 clobFilled, uint256 ammFilled);

    // =========================================================================
    // Permit2 variants
    // =========================================================================

    /// @notice Permit2 variant of {buyYes}. The router calls `permit2.permit` with the supplied
    ///         signature then pulls USDC via `permit2.transferFrom` instead of `safeTransferFrom`.
    function buyYesWithPermit(
        uint256 marketId,
        uint256 usdcIn,
        uint256 minYesOut,
        address recipient,
        uint256 maxFills,
        uint256 deadline,
        IAllowanceTransfer.PermitSingle calldata permitSingle,
        bytes calldata signature
    ) external returns (uint256 yesOut, uint256 clobFilled, uint256 ammFilled);

    /// @notice Permit2 variant of {sellYes}. See {buyYesWithPermit} for pulling semantics.
    function sellYesWithPermit(
        uint256 marketId,
        uint256 yesIn,
        uint256 minUsdcOut,
        address recipient,
        uint256 maxFills,
        uint256 deadline,
        IAllowanceTransfer.PermitSingle calldata permitSingle,
        bytes calldata signature
    ) external returns (uint256 usdcOut, uint256 clobFilled, uint256 ammFilled);

    /// @notice Permit2 variant of {buyNo}. See {buyYesWithPermit} for pulling semantics.
    function buyNoWithPermit(
        uint256 marketId,
        uint256 usdcIn,
        uint256 minNoOut,
        address recipient,
        uint256 maxFills,
        uint256 deadline,
        IAllowanceTransfer.PermitSingle calldata permitSingle,
        bytes calldata signature
    ) external returns (uint256 noOut, uint256 clobFilled, uint256 ammFilled);

    /// @notice Permit2 variant of {sellNo}. See {buyYesWithPermit} for pulling semantics.
    function sellNoWithPermit(
        uint256 marketId,
        uint256 noIn,
        uint256 minUsdcOut,
        address recipient,
        uint256 maxFills,
        uint256 deadline,
        IAllowanceTransfer.PermitSingle calldata permitSingle,
        bytes calldata signature
    ) external returns (uint256 usdcOut, uint256 clobFilled, uint256 ammFilled);

    // =========================================================================
    // Quotes
    // =========================================================================

    /// @notice Preview {buyYes} without executing. Non-view because `IV4Quoter.quoteExactInputSingle`
    ///         is implemented with a revert-and-decode simulation and is not a `view` function.
    /// @dev Returns `(0, 0, 0)` on an untradeable market instead of reverting, so frontend
    ///      callers can probe without needing to catch.
    function quoteBuyYes(uint256 marketId, uint256 usdcIn, uint256 maxFills)
        external
        returns (uint256 expectedYesOut, uint256 clobPortion, uint256 ammPortion);

    /// @notice Preview {sellYes}. Returns `(0, 0, 0)` on bad market state.
    function quoteSellYes(uint256 marketId, uint256 yesIn, uint256 maxFills)
        external
        returns (uint256 expectedUsdcOut, uint256 clobPortion, uint256 ammPortion);

    /// @notice Preview {buyNo}. Returns `(0, 0, 0)` on bad market state.
    function quoteBuyNo(uint256 marketId, uint256 usdcIn, uint256 maxFills)
        external
        returns (uint256 expectedNoOut, uint256 clobPortion, uint256 ammPortion);

    /// @notice Preview {sellNo}. Returns `(0, 0, 0)` on bad market state.
    function quoteSellNo(uint256 marketId, uint256 noIn, uint256 maxFills)
        external
        returns (uint256 expectedUsdcOut, uint256 clobPortion, uint256 ammPortion);
}
