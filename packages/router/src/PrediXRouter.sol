// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "@uniswap/v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {CurrencyLibrary} from "@uniswap/v4-core/src/types/Currency.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";

import {IV4Quoter} from "@uniswap/v4-periphery/src/interfaces/IV4Quoter.sol";

import {IAllowanceTransfer} from "permit2/src/interfaces/IAllowanceTransfer.sol";

import {IMarketFacet} from "@predix/shared/interfaces/IMarketFacet.sol";
import {IPausableFacet} from "@predix/shared/interfaces/IPausableFacet.sol";
import {Modules} from "@predix/shared/constants/Modules.sol";
import {TransientReentrancyGuard} from "@predix/shared/utils/TransientReentrancyGuard.sol";

import {IPrediXRouter} from "./interfaces/IPrediXRouter.sol";
import {IPrediXExchangeView} from "./interfaces/IPrediXExchangeView.sol";
import {IPrediXHookCommit} from "./interfaces/IPrediXHookCommit.sol";

/// @title PrediXRouter
/// @notice User-facing aggregator that routes PrediX binary-market trades between the CLOB
///         exchange and the matching Uniswap v4 pool. Stateless, permissionless, zero-fee.
/// @dev See `SC/packages/router/SPEC_ROUTER.md` for the full design. Invariants:
///      - The contract holds no funds between calls (enforced by `_refundAndAssertZero`).
///      - Only immutables; no storage variables.
///      - Every state-changing entry is `nonReentrant` and guarded by `_checkDeadline`.
contract PrediXRouter is IPrediXRouter, IUnlockCallback, TransientReentrancyGuard {
    using SafeERC20 for IERC20;
    using CurrencyLibrary for Currency;

    // =========================================================================
    // Callback dispatch
    // =========================================================================

    /// @notice AMM action selector carried through `poolManager.unlock` → `unlockCallback`.
    enum AmmAction {
        BUY_YES,
        SELL_YES,
        BUY_NO,
        SELL_NO
    }

    /// @notice Context struct passed to the unlock callback. Keeps the dispatch table shape
    ///         identical across the four AMM flows.
    struct AmmCtx {
        PoolKey key;
        uint256 marketId;
        address yesToken;
        address noToken;
        uint256 amountIn;
    }

    // =========================================================================
    // Constants
    // =========================================================================

    /// @notice Minimum trade input. Equals `$0.001` on the 6-decimal side (USDC or shares).
    ///         Below this, rounding dust dominates and the user would lose more than they gain.
    uint256 internal constant MIN_TRADE_AMOUNT = 1000;

    /// @notice Default `maxFills` substituted when the caller supplies zero.
    uint256 internal constant DEFAULT_MAX_FILLS = 10;

    /// @notice Virtual-NO path safety margin. The router under-sizes the `mintAmount` by 3%
    ///         relative to the Quoter's spot-price estimate, absorbing v4 price impact between
    ///         the quote and the actual swap. See spec §6.8.
    uint256 internal constant VIRTUAL_SAFETY_MARGIN_BPS = 9700;

    /// @notice NEW-M7: safety buffer applied to the post-impact mint target
    ///         computed by the two-pass virtual-NO quote. The first pass
    ///         extrapolates linearly from spot; the second pass re-quotes at
    ///         the estimated size and observes the real price-impact. Because
    ///         the size already reflects actual impact, only a 1% cushion is
    ///         needed against rounding + minor intra-block drift.
    uint256 internal constant BUY_NO_POST_IMPACT_MARGIN_BPS = 9900;

    uint256 internal constant BPS_DENOMINATOR = 10_000;

    /// @notice Price precision used by the CLOB and by the AMM fee math (1e6 = 100%).
    uint256 internal constant PRICE_PRECISION = 1e6;

    // =========================================================================
    // Immutables
    // =========================================================================

    /// @notice Uniswap v4 PoolManager shared with the diamond and the hook.
    IPoolManager public immutable poolManager;

    /// @notice PrediX diamond (market lifecycle, pause, access control).
    address public immutable diamond;

    /// @notice USDC — the only collateral PrediX supports.
    address public immutable usdc;

    /// @notice PrediX hook proxy. The router MUST be in its trusted-router set.
    address public immutable hook;

    /// @notice PrediX on-chain CLOB.
    address public immutable exchange;

    /// @notice Uniswap v4 Quoter — used for AMM quotes (fixes legacy audit H-03).
    IV4Quoter public immutable quoter;

    /// @notice Canonical Permit2 deployment on the target chain.
    IAllowanceTransfer public immutable permit2;

    /// @notice LP fee flag for every PrediX market pool. Expected value is
    ///         `LPFeeLibrary.DYNAMIC_FEE_FLAG` (`0x800000`) so the hook's per-swap override
    ///         takes effect. Stored as an immutable so test fixtures or future chains can
    ///         deploy with a different canonical fee without a code change.
    /// @dev Spec §6.1 deviation: the canonical PrediX pool shape is not stored in the shared
    ///      constants package, and the hook accepts arbitrary `fee` / `tickSpacing`. Exposing
    ///      both as deploy-time immutables is the cleanest way to let the router reconstruct
    ///      a `PoolKey` from a `(yesToken, usdc)` pair without a diamond round-trip. See R2
    ///      report for the follow-up question.
    uint24 public immutable lpFeeFlag;

    /// @notice Tick spacing for every PrediX market pool. Stored as an immutable; see
    ///         {lpFeeFlag} for the rationale and the open question.
    int24 public immutable tickSpacing;

    // =========================================================================
    // Constructor
    // =========================================================================

    /// @notice Wire the router to its infrastructure dependencies. All addresses are
    ///         immutable; there is no post-deploy setter for any of them.
    /// @dev Pre-approves the diamond and the exchange for infinite USDC so the hot path
    ///      never pays for an `approve` call. YES/NO outcome-token approvals to the exchange
    ///      are lazy because every market deploys its own ERC20 pair.
    constructor(
        IPoolManager _poolManager,
        address _diamond,
        address _usdc,
        address _hook,
        address _exchange,
        IV4Quoter _quoter,
        IAllowanceTransfer _permit2,
        uint24 _lpFeeFlag,
        int24 _tickSpacing
    ) {
        if (
            address(_poolManager) == address(0) || _diamond == address(0) || _usdc == address(0) || _hook == address(0)
                || _exchange == address(0) || address(_quoter) == address(0) || address(_permit2) == address(0)
        ) revert ZeroAddress();

        poolManager = _poolManager;
        diamond = _diamond;
        usdc = _usdc;
        hook = _hook;
        exchange = _exchange;
        quoter = _quoter;
        permit2 = _permit2;
        lpFeeFlag = _lpFeeFlag;
        tickSpacing = _tickSpacing;

        IERC20(_usdc).forceApprove(_diamond, type(uint256).max);
        IERC20(_usdc).forceApprove(_exchange, type(uint256).max);
    }

    // =========================================================================
    // IUnlockCallback
    // =========================================================================

    /// @inheritdoc IUnlockCallback
    /// @dev Dispatches to the matching AMM flow based on the `AmmAction` prefix in `data`.
    ///      Only the PoolManager is allowed to enter — the check closes an obvious footgun
    ///      where an attacker could forge arbitrary calldata for a `buyYes` flow.
    function unlockCallback(bytes calldata data) external override returns (bytes memory) {
        if (msg.sender != address(poolManager)) revert OnlyPoolManager();
        AmmAction action = abi.decode(data[0:32], (AmmAction));
        if (action == AmmAction.SELL_NO) {
            (, AmmCtx memory ctx, uint256 maxCost) = abi.decode(data, (AmmAction, AmmCtx, uint256));
            return abi.encode(_callbackSellNo(ctx, maxCost));
        }
        (, AmmCtx memory basicCtx) = abi.decode(data, (AmmAction, AmmCtx));
        if (action == AmmAction.BUY_YES) return abi.encode(_callbackBuyYes(basicCtx));
        if (action == AmmAction.SELL_YES) return abi.encode(_callbackSellYes(basicCtx));
        return abi.encode(_callbackBuyNo(basicCtx));
    }

    // =========================================================================
    // IPrediXRouter — entry points (implemented in R3–R6)
    // =========================================================================

    /// @inheritdoc IPrediXRouter
    function buyYes(
        uint256 marketId,
        uint256 usdcIn,
        uint256 minYesOut,
        address recipient,
        uint256 maxFills,
        uint256 deadline
    ) external nonReentrant returns (uint256 yesOut, uint256 clobFilled, uint256 ammFilled) {
        (address yesToken, address noToken) = _preEntry(usdcIn, recipient, deadline, marketId);
        IERC20(usdc).safeTransferFrom(msg.sender, address(this), usdcIn);
        return _buyYesExecute(marketId, usdcIn, minYesOut, recipient, maxFills, deadline, yesToken, noToken);
    }

    /// @inheritdoc IPrediXRouter
    function sellYes(
        uint256 marketId,
        uint256 yesIn,
        uint256 minUsdcOut,
        address recipient,
        uint256 maxFills,
        uint256 deadline
    ) external nonReentrant returns (uint256 usdcOut, uint256 clobFilled, uint256 ammFilled) {
        (address yesToken, address noToken) = _preEntry(yesIn, recipient, deadline, marketId);
        IERC20(yesToken).safeTransferFrom(msg.sender, address(this), yesIn);
        return _sellYesExecute(marketId, yesIn, minUsdcOut, recipient, maxFills, deadline, yesToken, noToken);
    }

    /// @inheritdoc IPrediXRouter
    function buyNo(
        uint256 marketId,
        uint256 usdcIn,
        uint256 minNoOut,
        address recipient,
        uint256 maxFills,
        uint256 deadline
    ) external nonReentrant returns (uint256 noOut, uint256 clobFilled, uint256 ammFilled) {
        (address yesToken, address noToken) = _preEntry(usdcIn, recipient, deadline, marketId);
        IERC20(usdc).safeTransferFrom(msg.sender, address(this), usdcIn);
        return _buyNoExecute(marketId, usdcIn, minNoOut, recipient, maxFills, deadline, yesToken, noToken);
    }

    /// @inheritdoc IPrediXRouter
    function sellNo(
        uint256 marketId,
        uint256 noIn,
        uint256 minUsdcOut,
        address recipient,
        uint256 maxFills,
        uint256 deadline
    ) external nonReentrant returns (uint256 usdcOut, uint256 clobFilled, uint256 ammFilled) {
        (address yesToken, address noToken) = _preEntry(noIn, recipient, deadline, marketId);
        IERC20(noToken).safeTransferFrom(msg.sender, address(this), noIn);
        return _sellNoExecute(marketId, noIn, minUsdcOut, recipient, maxFills, deadline, yesToken, noToken);
    }

    /// @inheritdoc IPrediXRouter
    function buyYesWithPermit(
        uint256 marketId,
        uint256 usdcIn,
        uint256 minYesOut,
        address recipient,
        uint256 maxFills,
        uint256 deadline,
        IAllowanceTransfer.PermitSingle calldata permitSingle,
        bytes calldata signature
    ) external nonReentrant returns (uint256 yesOut, uint256 clobFilled, uint256 ammFilled) {
        (address yesToken, address noToken) = _preEntry(usdcIn, recipient, deadline, marketId);
        _consumePermit(permitSingle, signature, uint160(usdcIn), usdc);
        return _buyYesExecute(marketId, usdcIn, minYesOut, recipient, maxFills, deadline, yesToken, noToken);
    }

    /// @inheritdoc IPrediXRouter
    function sellYesWithPermit(
        uint256 marketId,
        uint256 yesIn,
        uint256 minUsdcOut,
        address recipient,
        uint256 maxFills,
        uint256 deadline,
        IAllowanceTransfer.PermitSingle calldata permitSingle,
        bytes calldata signature
    ) external nonReentrant returns (uint256 usdcOut, uint256 clobFilled, uint256 ammFilled) {
        (address yesToken, address noToken) = _preEntry(yesIn, recipient, deadline, marketId);
        _consumePermit(permitSingle, signature, uint160(yesIn), yesToken);
        return _sellYesExecute(marketId, yesIn, minUsdcOut, recipient, maxFills, deadline, yesToken, noToken);
    }

    /// @inheritdoc IPrediXRouter
    function buyNoWithPermit(
        uint256 marketId,
        uint256 usdcIn,
        uint256 minNoOut,
        address recipient,
        uint256 maxFills,
        uint256 deadline,
        IAllowanceTransfer.PermitSingle calldata permitSingle,
        bytes calldata signature
    ) external nonReentrant returns (uint256 noOut, uint256 clobFilled, uint256 ammFilled) {
        (address yesToken, address noToken) = _preEntry(usdcIn, recipient, deadline, marketId);
        _consumePermit(permitSingle, signature, uint160(usdcIn), usdc);
        return _buyNoExecute(marketId, usdcIn, minNoOut, recipient, maxFills, deadline, yesToken, noToken);
    }

    /// @inheritdoc IPrediXRouter
    function sellNoWithPermit(
        uint256 marketId,
        uint256 noIn,
        uint256 minUsdcOut,
        address recipient,
        uint256 maxFills,
        uint256 deadline,
        IAllowanceTransfer.PermitSingle calldata permitSingle,
        bytes calldata signature
    ) external nonReentrant returns (uint256 usdcOut, uint256 clobFilled, uint256 ammFilled) {
        (address yesToken, address noToken) = _preEntry(noIn, recipient, deadline, marketId);
        _consumePermit(permitSingle, signature, uint160(noIn), noToken);
        return _sellNoExecute(marketId, noIn, minUsdcOut, recipient, maxFills, deadline, yesToken, noToken);
    }

    /// @inheritdoc IPrediXRouter
    function quoteBuyYes(uint256 marketId, uint256 usdcIn, uint256 maxFills)
        external
        returns (uint256 expectedYesOut, uint256 clobPortion, uint256 ammPortion)
    {
        (address yesToken,,,,) = _quoteMarketStatus(marketId);
        if (yesToken == address(0) || usdcIn < MIN_TRADE_AMOUNT) return (0, 0, 0);

        uint256 clobLimit = _clobBuyYesLimit(yesToken);
        uint256 clobCost;
        (clobPortion, clobCost) = IPrediXExchangeView(exchange)
            .previewFillMarketOrder(marketId, IPrediXExchangeView.Side.BUY_YES, clobLimit, usdcIn, maxFills);

        uint256 usdcLeft = usdcIn - clobCost;
        if (usdcLeft > 0) {
            _preCommitForQuoter(yesToken);
            PoolKey memory key = _buildPoolKey(yesToken);
            IV4Quoter.QuoteExactSingleParams memory params = IV4Quoter.QuoteExactSingleParams({
                poolKey: key, zeroForOne: usdc < yesToken, exactAmount: uint128(usdcLeft), hookData: ""
            });
            (uint256 amountOut,) = quoter.quoteExactInputSingle(params);
            ammPortion = amountOut;
        }

        expectedYesOut = clobPortion + ammPortion;
    }

    /// @inheritdoc IPrediXRouter
    function quoteSellYes(uint256 marketId, uint256 yesIn, uint256 maxFills)
        external
        returns (uint256 expectedUsdcOut, uint256 clobPortion, uint256 ammPortion)
    {
        (address yesToken,,,,) = _quoteMarketStatus(marketId);
        if (yesToken == address(0) || yesIn < MIN_TRADE_AMOUNT) return (0, 0, 0);

        uint256 clobLimit = _clobSellYesLimit(yesToken);
        uint256 sharesFilled;
        // previewFillMarketOrder returns (filled, cost) where filled = output
        // denomination delivered to taker and cost = input denomination consumed
        // from taker. For SELL_YES: filled = USDC out, cost = YES in.
        (clobPortion, sharesFilled) = IPrediXExchangeView(exchange)
            .previewFillMarketOrder(marketId, IPrediXExchangeView.Side.SELL_YES, clobLimit, yesIn, maxFills);

        uint256 yesLeft = yesIn - sharesFilled;
        if (yesLeft > 0) {
            _preCommitForQuoter(yesToken);
            PoolKey memory key = _buildPoolKey(yesToken);
            IV4Quoter.QuoteExactSingleParams memory params = IV4Quoter.QuoteExactSingleParams({
                poolKey: key, zeroForOne: yesToken < usdc, exactAmount: uint128(yesLeft), hookData: ""
            });
            (uint256 amountOut,) = quoter.quoteExactInputSingle(params);
            ammPortion = amountOut;
        }

        expectedUsdcOut = clobPortion + ammPortion;
    }

    /// @inheritdoc IPrediXRouter
    function quoteBuyNo(uint256 marketId, uint256 usdcIn, uint256 maxFills)
        external
        returns (uint256 expectedNoOut, uint256 clobPortion, uint256 ammPortion)
    {
        (address yesToken,,,,) = _quoteMarketStatus(marketId);
        if (yesToken == address(0) || usdcIn < MIN_TRADE_AMOUNT) return (0, 0, 0);

        uint256 clobLimit = _clobBuyNoLimit(yesToken);
        uint256 clobCost;
        (clobPortion, clobCost) = IPrediXExchangeView(exchange)
            .previewFillMarketOrder(marketId, IPrediXExchangeView.Side.BUY_NO, clobLimit, usdcIn, maxFills);

        uint256 usdcLeft = usdcIn - clobCost;
        if (usdcLeft > 0) {
            ammPortion = _computeBuyNoMintAmount(yesToken, usdcLeft);
        }

        expectedNoOut = clobPortion + ammPortion;
    }

    /// @inheritdoc IPrediXRouter
    function quoteSellNo(uint256 marketId, uint256 noIn, uint256 maxFills)
        external
        returns (uint256 expectedUsdcOut, uint256 clobPortion, uint256 ammPortion)
    {
        (address yesToken,,,,) = _quoteMarketStatus(marketId);
        if (yesToken == address(0) || noIn < MIN_TRADE_AMOUNT) return (0, 0, 0);

        uint256 clobLimit = _clobSellNoLimit(yesToken);
        uint256 sharesFilled;
        // SELL_NO: filled = USDC out, cost = NO in (side-dependent tuple).
        (clobPortion, sharesFilled) = IPrediXExchangeView(exchange)
            .previewFillMarketOrder(marketId, IPrediXExchangeView.Side.SELL_NO, clobLimit, noIn, maxFills);

        uint256 noLeft = noIn - sharesFilled;
        if (noLeft > 0) {
            uint256 maxCost = _computeSellNoMaxCost(yesToken, noLeft);
            if (maxCost < noLeft) ammPortion = noLeft - maxCost;
        }

        expectedUsdcOut = clobPortion + ammPortion;
    }

    /// @notice Market-status read that returns zero-valued fields on bad state rather than
    ///         reverting. Used exclusively by the quote functions so frontends can probe
    ///         markets without wrapping calls in try/catch.
    function _quoteMarketStatus(uint256 marketId)
        internal
        view
        returns (address yesToken, address noToken, uint256 endTime, bool isResolved, bool refundModeActive)
    {
        if (IPausableFacet(diamond).isModulePaused(Modules.MARKET)) {
            return (address(0), address(0), 0, false, false);
        }
        (yesToken, noToken, endTime, isResolved, refundModeActive) = IMarketFacet(diamond).getMarketStatus(marketId);
        if (yesToken == address(0) || isResolved || refundModeActive || block.timestamp >= endTime) {
            return (address(0), address(0), 0, false, false);
        }
    }

    // =========================================================================
    // Internal helpers
    // =========================================================================

    /// @notice Revert if the supplied deadline has already passed.
    function _checkDeadline(uint256 deadline) internal view {
        if (deadline < block.timestamp) revert DeadlineExpired(deadline, block.timestamp);
    }

    /// @notice Full market-health gate. Single read of `getMarketStatus`; callers must pass
    ///         the cached `(yesToken, noToken)` pair into any downstream helper instead of
    ///         re-reading the diamond.
    /// @dev Reverts on every untradeable condition: module paused, market absent, resolved,
    ///      expired, or in refund mode. Keeps ordering identical to the exchange's taker-path
    ///      validation so frontend error mapping stays consistent across both systems.
    function _validateMarket(uint256 marketId)
        internal
        view
        returns (address yesToken, address noToken, uint256 endTime, bool isResolved, bool refundModeActive)
    {
        if (IPausableFacet(diamond).isModulePaused(Modules.MARKET)) revert MarketModulePaused();

        (yesToken, noToken, endTime, isResolved, refundModeActive) = IMarketFacet(diamond).getMarketStatus(marketId);

        if (yesToken == address(0)) revert MarketNotFound();
        if (isResolved) revert MarketResolved();
        if (refundModeActive) revert MarketInRefundMode();
        if (block.timestamp >= endTime) revert MarketExpired();
    }

    /// @notice Block recipients that would allow a user to hand tokens to PrediX infrastructure
    ///         (or the router itself) by mistake. Protects against the "recipient = diamond"
    ///         footgun raised in spec §7 E2.
    function _isBannedRecipient(address recipient) internal view returns (bool) {
        return recipient == address(0) || recipient == address(this) || recipient == diamond || recipient == exchange
            || recipient == hook || recipient == address(poolManager) || recipient == address(quoter)
            || recipient == address(permit2);
    }

    /// @notice Construct the canonical `PoolKey` for a PrediX market from its YES token.
    /// @dev Sorts `(usdc, yesToken)` into the `(currency0, currency1)` v4 ordering. The hook
    ///      address and the canonical fee / tickSpacing come from immutables. MUST match the
    ///      `PoolKey` the diamond used when calling `hook.registerMarketPool` at create time.
    function _buildPoolKey(address yesToken) internal view returns (PoolKey memory key) {
        address quote = usdc;
        (Currency currency0, Currency currency1) = quote < yesToken
            ? (Currency.wrap(quote), Currency.wrap(yesToken))
            : (Currency.wrap(yesToken), Currency.wrap(quote));
        key = PoolKey({
            currency0: currency0, currency1: currency1, fee: lpFeeFlag, tickSpacing: tickSpacing, hooks: IHooks(hook)
        });
    }

    /// @notice Approve `spender` for the maximum uint256 of `token` exactly once per
    ///         (token, spender) pair. `forceApprove` handles non-standard ERC20s that require
    ///         the allowance to be reset to zero first.
    /// @dev Read-first-write strategy avoids a second SSTORE on the warm path. Outcome tokens
    ///      (YES / NO) are standard ERC20s so the read is cheap and the write is one-shot.
    function _ensureApproval(address token, address spender) internal {
        if (IERC20(token).allowance(address(this), spender) == type(uint256).max) return;
        IERC20(token).forceApprove(spender, type(uint256).max);
    }

    /// @notice Settle a debt the router owes to the PoolManager for `amount` of `token`.
    ///         Uses v4 flash-accounting: `sync → transfer → settle` so the pool learns about
    ///         the payment via its balance diff.
    /// @dev Callable only from inside an unlock callback; nothing here enforces that — the
    ///      callers do. Copied from the `DeltaResolver` helper shape in `v4-periphery`.
    function _settleToken(address token, uint256 amount) internal {
        if (amount == 0) return;
        poolManager.sync(Currency.wrap(token));
        IERC20(token).safeTransfer(address(poolManager), amount);
        poolManager.settle();
    }

    /// @notice Claim `amount` of `token` the pool owes the router. Uses `take` under the v4
    ///         flash-accounting model; the recipient is always the router itself so the hot
    ///         path can apply the refund-and-deliver invariant.
    function _takeToken(address token, uint256 amount) internal {
        if (amount == 0) return;
        poolManager.take(Currency.wrap(token), address(this), amount);
    }

    /// @notice Refund all three trade-path tokens (USDC + YES + NO) and assert the router
    ///         holds zero of each afterwards. Stronger than single-token refund — catches
    ///         any residual from intermediate steps that might strand a different token.
    function _finalizeAndAssertAllZero(address yesToken, address noToken) internal {
        _refundAndAssertZero(usdc);
        _refundAndAssertZero(yesToken);
        _refundAndAssertZero(noToken);
    }

    /// @notice Return any residual balance of `token` to `msg.sender` and assert the router's
    ///         balance is zero afterwards. The revert path is the router's accounting canary —
    ///         it should never fire under normal operation.
    function _refundAndAssertZero(address token) internal {
        uint256 bal = IERC20(token).balanceOf(address(this));
        if (bal > 0) {
            IERC20(token).safeTransfer(msg.sender, bal);
            emit DustRefunded(msg.sender, token, bal);
        }
        if (IERC20(token).balanceOf(address(this)) != 0) revert FinalizeBalanceNonZero();
    }

    /// @notice Try filling a buy via the CLOB. Silently falls back to 100% AMM if the exchange
    ///         reverts — e.g. because the exchange module is paused. See spec §6.9 / E14.
    /// @dev Pre-approvals for USDC are set in the constructor so no allowance bump is needed.
    function _tryClobBuy(
        uint256 marketId,
        IPrediXExchangeView.Side side,
        uint256 limitPrice,
        uint256 amountIn,
        uint256 maxFills,
        uint256 deadline
    ) internal returns (uint256 filled, uint256 amountInRemaining) {
        try IPrediXExchangeView(exchange)
            .fillMarketOrder(
                marketId, side, limitPrice, amountIn, address(this), address(this), maxFills, deadline
            ) returns (
            uint256 _filled, uint256 _cost
        ) {
            filled = _filled;
            amountInRemaining = amountIn - _cost;
        } catch (bytes memory err) {
            // H-R1: log-and-fallback. Keep the AMM resilience by not re-throwing,
            // but surface the selector so silent CLOB reverts become observable.
            // `msg.sender` here is the end user — internal calls preserve it
            // through the router entry (`buyYes` / `buyNo`).
            filled = 0;
            amountInRemaining = amountIn;
            bytes4 sel = err.length >= 4 ? bytes4(err) : bytes4(0);
            emit ClobSkipped(marketId, msg.sender, sel);
        }
    }

    /// @notice Commit the end-user identity to the hook and unlock the pool to execute an
    ///         exact-in USDC → YES swap. Returns the YES amount credited to the router.
    /// @dev The hook commit MUST happen before `unlock`, not inside the callback — the
    ///      anti-sandwich detector reads the transient slot from the `_beforeSwap` path.
    function _executeAmmBuyYes(uint256 marketId, address yesToken, address noToken, uint256 usdcIn, address user)
        internal
        returns (uint256 yesOut)
    {
        PoolKey memory key = _buildPoolKey(yesToken);
        PoolId poolId = key.toId();

        IPrediXHookCommit(hook).commitSwapIdentity(user, poolId);

        bytes memory data = abi.encode(
            AmmAction.BUY_YES,
            AmmCtx({key: key, marketId: marketId, yesToken: yesToken, noToken: noToken, amountIn: usdcIn})
        );
        bytes memory result = poolManager.unlock(data);
        yesOut = abi.decode(result, (uint256));
    }

    /// @notice Callback body for the `BUY_YES` AMM flow. Executes an exact-in USDC → YES swap
    ///         and settles both legs via the v4 flash-accounting pattern.
    /// @dev Dust tolerance: when the CLOB waterfall leaves sub-fee USDC (e.g. 1 wei after a
    ///      near-exact match), the swap returns `yesDelta == 0` because the dynamic hook fee
    ///      consumes the entire input. That is not a liquidity failure — the aggregate fill is
    ///      satisfied by the CLOB leg. Settle the owed USDC (pool has already taken it) and
    ///      return 0 so `_buyYesExecute` can enforce `minOut` / non-zero total on the combined
    ///      CLOB + AMM result rather than reverting here on a negligible remainder.
    function _callbackBuyYes(AmmCtx memory ctx) internal returns (uint256 yesOut) {
        bool zeroForOne = usdc < ctx.yesToken; // USDC → YES if USDC is currency0.
        BalanceDelta delta = poolManager.swap(
            ctx.key,
            SwapParams({
                zeroForOne: zeroForOne,
                amountSpecified: -int256(ctx.amountIn),
                sqrtPriceLimitX96: zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
            }),
            ""
        );

        int128 usdcDelta = zeroForOne ? delta.amount0() : delta.amount1();
        int128 yesDelta = zeroForOne ? delta.amount1() : delta.amount0();

        if (yesDelta == 0) {
            if (usdcDelta < 0) _settleToken(usdc, uint256(uint128(-usdcDelta)));
            return 0;
        }
        if (yesDelta < 0) revert InsufficientLiquidity();

        _settleToken(usdc, uint256(uint128(-usdcDelta)));
        yesOut = uint256(uint128(yesDelta));
        _takeToken(ctx.yesToken, yesOut);
    }

    /// @notice Try filling a sell via the CLOB. Same fallback pattern as {_tryClobBuy} — if
    ///         the exchange reverts (paused, deadline, etc.) the router degrades to pure AMM.
    function _tryClobSell(
        uint256 marketId,
        IPrediXExchangeView.Side side,
        uint256 limitPrice,
        uint256 amountIn,
        uint256 maxFills,
        uint256 deadline
    ) internal returns (uint256 filled, uint256 amountInRemaining) {
        try IPrediXExchangeView(exchange)
            .fillMarketOrder(
                marketId, side, limitPrice, amountIn, address(this), address(this), maxFills, deadline
            ) returns (
            uint256 _filled, uint256 _cost
        ) {
            filled = _filled;
            amountInRemaining = amountIn - _cost;
        } catch (bytes memory err) {
            // H-R1: mirrors `_tryClobBuy` — see the comment there for rationale.
            filled = 0;
            amountInRemaining = amountIn;
            bytes4 sel = err.length >= 4 ? bytes4(err) : bytes4(0);
            emit ClobSkipped(marketId, msg.sender, sel);
        }
    }

    /// @notice Commit + unlock wrapper for the `SELL_YES` AMM flow. Returns the USDC credited
    ///         to the router's balance after the swap + take.
    function _executeAmmSellYes(uint256 marketId, address yesToken, address noToken, uint256 yesIn, address user)
        internal
        returns (uint256 usdcOut)
    {
        PoolKey memory key = _buildPoolKey(yesToken);
        PoolId poolId = key.toId();
        IPrediXHookCommit(hook).commitSwapIdentity(user, poolId);

        bytes memory data = abi.encode(
            AmmAction.SELL_YES,
            AmmCtx({key: key, marketId: marketId, yesToken: yesToken, noToken: noToken, amountIn: yesIn})
        );
        bytes memory result = poolManager.unlock(data);
        usdcOut = abi.decode(result, (uint256));
    }

    /// @notice Callback body for `SELL_YES`: swap exact-in YES → USDC, settle YES debt, take USDC.
    /// @dev Symmetric dust tolerance to `_callbackBuyYes` — YES dust from a near-exact CLOB
    ///      fill yields `usdcDelta == 0` under dynamic fee. Settle the owed YES (pool took it)
    ///      and return 0 instead of reverting, leaving `_sellYesExecute` to check aggregate
    ///      minOut / non-zero total.
    function _callbackSellYes(AmmCtx memory ctx) internal returns (uint256 usdcOut) {
        bool zeroForOne = ctx.yesToken < usdc; // YES → USDC if YES is currency0.
        BalanceDelta delta = poolManager.swap(
            ctx.key,
            SwapParams({
                zeroForOne: zeroForOne,
                amountSpecified: -int256(ctx.amountIn),
                sqrtPriceLimitX96: zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
            }),
            ""
        );

        int128 yesDelta = zeroForOne ? delta.amount0() : delta.amount1();
        int128 usdcDelta = zeroForOne ? delta.amount1() : delta.amount0();

        if (usdcDelta == 0) {
            if (yesDelta < 0) _settleToken(ctx.yesToken, uint256(uint128(-yesDelta)));
            return 0;
        }
        if (usdcDelta < 0) revert InsufficientLiquidity();

        _settleToken(ctx.yesToken, uint256(uint128(-yesDelta)));
        usdcOut = uint256(uint128(usdcDelta));
        _takeToken(usdc, usdcOut);
    }

    /// @notice Virtual-NO `buyNo` AMM path. Pre-computes `mintAmount` using the Quoter's spot
    ///         price and applies a 3% safety margin before entering the unlock callback.
    /// @dev The economic identity `$YES + $NO = $1` is exact pre-resolution, so the spot NO
    ///      price follows directly from the spot YES price. Concentrated liquidity can still
    ///      move the effective execution price — the margin absorbs that gap.
    function _executeAmmBuyNo(uint256 marketId, address yesToken, address noToken, uint256 usdcIn, address user)
        internal
        returns (uint256 noOut)
    {
        uint256 mintAmount = _computeBuyNoMintAmount(yesToken, usdcIn);
        // Dust: when `usdcIn` is the CLOB-waterfall remainder and rounds `mintAmount` to zero
        // (or the pool has no liquidity), skip the AMM leg instead of reverting so the outer
        // caller can ship the CLOB-only fill.
        if (mintAmount == 0) return 0;

        _enforcePerMarketCap(marketId, mintAmount);

        PoolKey memory key = _buildPoolKey(yesToken);
        PoolId poolId = key.toId();
        IPrediXHookCommit(hook).commitSwapIdentity(user, poolId);

        bytes memory data = abi.encode(
            AmmAction.BUY_NO,
            AmmCtx({key: key, marketId: marketId, yesToken: yesToken, noToken: noToken, amountIn: mintAmount})
        );
        bytes memory result = poolManager.unlock(data);
        noOut = abi.decode(result, (uint256));
    }

    /// @notice Callback body for `BUY_NO`. Router enters holding `usdcIn` USDC. It swaps
    ///         `mintAmount` YES → USDC (flash), takes the USDC proceeds, splits the combined
    ///         balance into `mintAmount` YES + NO, settles the borrowed YES, keeps the NO.
    /// @dev Dust tolerance: for sub-fee `mintAmount`, the flash-sell can yield `usdcDelta == 0`
    ///      (fee eats the sliver). We still proceed to `splitPosition` — the original `usdcIn`
    ///      may be enough to fund the mint. The `balanceOf < mintAmount` check below is the
    ///      real gate: if the CLOB remainder cannot cover `mintAmount`, it reverts with
    ///      `QuoteOutsideSafetyMargin`. Only reject on direction-inversion deltas.
    function _callbackBuyNo(AmmCtx memory ctx) internal returns (uint256 noOut) {
        uint256 mintAmount = ctx.amountIn;
        bool zeroForOne = ctx.yesToken < usdc;
        BalanceDelta delta = poolManager.swap(
            ctx.key,
            SwapParams({
                zeroForOne: zeroForOne,
                amountSpecified: -int256(mintAmount),
                sqrtPriceLimitX96: zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
            }),
            ""
        );

        int128 yesDelta = zeroForOne ? delta.amount0() : delta.amount1();
        int128 usdcDelta = zeroForOne ? delta.amount1() : delta.amount0();
        if (usdcDelta < 0 || yesDelta >= 0) revert InsufficientLiquidity();

        uint256 proceeds = uint256(uint128(usdcDelta));
        _takeToken(usdc, proceeds);

        if (IERC20(usdc).balanceOf(address(this)) < mintAmount) revert QuoteOutsideSafetyMargin();
        IMarketFacet(diamond).splitPosition(ctx.marketId, mintAmount);

        _settleToken(ctx.yesToken, mintAmount);
        noOut = mintAmount;
    }

    /// @notice Virtual-NO `sellNo` AMM path. Quote-derived upper bound on the USDC cost of
    ///         flash-buying `noIn` YES keeps the router from under-delivering under price impact.
    /// @dev The quoter is consumed exactly once — here — and the resulting `maxCost` is carried
    ///      through `AmmCtx.amountIn2`-style via a dedicated field added to `AmmCtx`. We reuse
    ///      the existing struct by packing `maxCost` into the high bits of a secondary field.
    function _executeAmmSellNo(uint256 marketId, address yesToken, address noToken, uint256 noIn, address user)
        internal
        returns (uint256 usdcOut)
    {
        uint256 maxCost = _computeSellNoMaxCost(yesToken, noIn);
        // Virtual-NO sell is only profitable when flash-buying `noIn` YES costs strictly less
        // than the `noIn` NO being merged. Dust remainders from a CLOB partial fill, or pool
        // states skewed towards high YES price, fail this test — skip the AMM leg instead of
        // reverting so the outer caller can ship the CLOB-only fill.
        if (maxCost >= noIn) return 0;

        PoolKey memory key = _buildPoolKey(yesToken);
        PoolId poolId = key.toId();
        IPrediXHookCommit(hook).commitSwapIdentity(user, poolId);

        bytes memory data = abi.encode(
            AmmAction.SELL_NO,
            AmmCtx({key: key, marketId: marketId, yesToken: yesToken, noToken: noToken, amountIn: noIn}),
            maxCost
        );
        bytes memory result = poolManager.unlock(data);
        usdcOut = abi.decode(result, (uint256));
    }

    /// @notice Callback body for `SELL_NO`. Router enters holding `noIn` NO. It buys `noIn`
    ///         YES from the pool (exact-out), merges YES+NO for USDC, settles the USDC cost.
    function _callbackSellNo(AmmCtx memory ctx, uint256 maxCost) internal returns (uint256 usdcOut) {
        uint256 noIn = ctx.amountIn;

        bool zeroForOne = usdc < ctx.yesToken;
        BalanceDelta delta = poolManager.swap(
            ctx.key,
            SwapParams({
                zeroForOne: zeroForOne,
                amountSpecified: int256(noIn),
                sqrtPriceLimitX96: zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
            }),
            ""
        );

        int128 usdcDelta = zeroForOne ? delta.amount0() : delta.amount1();
        int128 yesDelta = zeroForOne ? delta.amount1() : delta.amount0();
        if (yesDelta <= 0 || usdcDelta >= 0) revert InsufficientLiquidity();

        uint256 cost = uint256(uint128(-usdcDelta));
        if (cost > maxCost) revert QuoteOutsideSafetyMargin();

        _takeToken(ctx.yesToken, noIn);
        IMarketFacet(diamond).mergePositions(ctx.marketId, noIn);

        _settleToken(usdc, cost);
        usdcOut = noIn - cost;
    }

    // =========================================================================
    // Quoter identity pre-commit (Phase 5 — commitSwapIdentityFor)
    // =========================================================================

    /// @dev Pre-commit `msg.sender` identity under the quoter's transient slot so
    ///      `V4Quoter.quoteExactInputSingle` / `quoteExactOutputSingle` can pass
    ///      the hook's FINAL-H06 commit gate during simulate-and-revert. Must be
    ///      called before every quoter invocation in the same transaction. Both the
    ///      router and the quoter must be in the hook's trusted-router set.
    function _preCommitForQuoter(address yesToken) internal {
        PoolKey memory key = _buildPoolKey(yesToken);
        IPrediXHookCommit(hook).commitSwapIdentityFor(address(quoter), msg.sender, key.toId());
    }

    // =========================================================================
    // CLOB price caps — fee-adjusted AMM spot (restored in Phase 5)
    // =========================================================================

    /// @notice Fee-adjusted AMM spot price for buying YES, in USDC/YES with 1e6 precision.
    /// @dev Quotes `1 USDC ($1) → YES` and inverts. The Quoter simulates the real swap through
    ///      the hook, so the dynamic fee is baked in (audit H-03 fix). Returns 0 on an empty
    ///      pool so callers can fall back to a permissive cap rather than reverting.
    function _ammSpotPriceForBuy(address yesToken) internal returns (uint256 usdcPerYes) {
        _preCommitForQuoter(yesToken);
        PoolKey memory key = _buildPoolKey(yesToken);
        IV4Quoter.QuoteExactSingleParams memory params = IV4Quoter.QuoteExactSingleParams({
            poolKey: key, zeroForOne: usdc < yesToken, exactAmount: uint128(PRICE_PRECISION), hookData: ""
        });
        (uint256 yesOut,) = quoter.quoteExactInputSingle(params);
        if (yesOut == 0) return 0;
        usdcPerYes = (PRICE_PRECISION * PRICE_PRECISION) / yesOut;
    }

    /// @notice Fee-adjusted AMM spot price when selling YES, in USDC/YES with 1e6 precision.
    function _ammSpotPriceForSell(address yesToken) internal returns (uint256 usdcPerYes) {
        _preCommitForQuoter(yesToken);
        PoolKey memory key = _buildPoolKey(yesToken);
        IV4Quoter.QuoteExactSingleParams memory params = IV4Quoter.QuoteExactSingleParams({
            poolKey: key, zeroForOne: yesToken < usdc, exactAmount: uint128(PRICE_PRECISION), hookData: ""
        });
        (usdcPerYes,) = quoter.quoteExactInputSingle(params);
    }

    /// @notice Saturating `1e6 - price` used to derive virtual NO prices from YES prices.
    function _complementPrice(uint256 yesPrice) internal pure returns (uint256) {
        return yesPrice >= PRICE_PRECISION ? 0 : PRICE_PRECISION - yesPrice;
    }

    /// @notice CLOB BUY cap for `BUY_YES`. Falls back to `PRICE_PRECISION` (permissive) on an
    ///         empty pool so the CLOB is free to fill when there is no AMM competition.
    function _clobBuyYesLimit(address yesToken) internal returns (uint256) {
        uint256 spot = _ammSpotPriceForBuy(yesToken);
        return spot == 0 ? PRICE_PRECISION : spot;
    }

    /// @notice CLOB SELL min-price for `SELL_YES`. Spot is already USDC received per YES, so
    ///         there is no fall-back transformation — an empty pool yields 0 which is the
    ///         permissive min.
    function _clobSellYesLimit(address yesToken) internal returns (uint256) {
        return _ammSpotPriceForSell(yesToken);
    }

    /// @notice CLOB BUY cap for `BUY_NO`. Virtual NO buy price = 1 - yesSellSpot.
    function _clobBuyNoLimit(address yesToken) internal returns (uint256) {
        uint256 yesSell = _ammSpotPriceForSell(yesToken);
        if (yesSell == 0) return PRICE_PRECISION;
        uint256 complement = _complementPrice(yesSell);
        return complement == 0 ? PRICE_PRECISION : complement;
    }

    /// @notice CLOB SELL min-price for `SELL_NO`. Virtual NO sell price = 1 - yesBuySpot.
    function _clobSellNoLimit(address yesToken) internal returns (uint256) {
        uint256 yesBuy = _ammSpotPriceForBuy(yesToken);
        if (yesBuy == 0) return 0;
        return _complementPrice(yesBuy);
    }

    /// @notice Compute `mintAmount` for `buyNo` using the sell-direction spot price and 3% margin.
    /// @dev The callback flash-SELLS `mintAmount` YES (USDC ← YES), so the economic identity
    ///      must use the fee-adjusted SELL-direction spot: `usdcPerYesSell` already bakes the
    ///      hook's dynamic fee into the proceeds a seller receives. The buy-direction spot
    ///      (USDC → YES) has the fee applied on the opposite side and returns an inflated YES
    ///      price — using it would over-estimate `mintAmount` by `fee / (1 - fee)`, leaking the
    ///      balance check at `_callbackBuyNo` with `QuoteOutsideSafetyMargin`.
    ///
    ///      User net spend = `mintAmount - proceeds = mintAmount - mintAmount × usdcPerYesSell
    ///      = mintAmount × (1 - usdcPerYesSell)`. Solving for mintAmount with budget = usdcIn:
    ///          mintAmount = usdcIn / (1 - usdcPerYesSell)
    ///      The 3% margin absorbs additional price impact between the spot-size quoter probe
    ///      and the actual swap size in the callback.
    function _computeBuyNoMintAmount(address yesToken, uint256 usdcIn) internal returns (uint256 mintAmount) {
        // Pass 1: spot probe to extrapolate an initial target under a no-
        // impact assumption. Same as pre-fix behaviour up to this point.
        uint256 usdcPerYesSell = _ammSpotPriceForSell(yesToken);
        if (usdcPerYesSell == 0 || usdcPerYesSell >= PRICE_PRECISION) return 0;

        uint256 effectiveNoPrice = PRICE_PRECISION - usdcPerYesSell;
        uint256 estimatedTarget = (usdcIn * PRICE_PRECISION) / effectiveNoPrice;

        // NEW-M7: Pass 2 re-quotes the sell at the estimated target size so
        // the actual price impact is baked in before committing to the mint.
        // Without this, a thin pool's linear extrapolation would size the
        // flash-sell beyond what the pool can absorb; the callback then
        // reverts `QuoteOutsideSafetyMargin` even when the user's USDC is
        // sufficient for a smaller but still-fillable order.
        _preCommitForQuoter(yesToken);
        PoolKey memory key = _buildPoolKey(yesToken);
        IV4Quoter.QuoteExactSingleParams memory params = IV4Quoter.QuoteExactSingleParams({
            poolKey: key,
            // Sell direction: YES in, USDC out. zeroForOne iff YES is currency0.
            zeroForOne: yesToken < usdc,
            exactAmount: uint128(estimatedTarget),
            hookData: ""
        });
        (uint256 proceedsAtTarget,) = quoter.quoteExactInputSingle(params);

        // Invariant for the buyNo flash callback: `proceeds + usdcIn >=
        // estimatedTarget` (user's USDC plus flash-sell proceeds must cover
        // the mint). If Pass 2 shows the pool cannot absorb the full
        // estimatedTarget, size down to what is feasible instead of reverting.
        if (proceedsAtTarget + usdcIn < estimatedTarget) {
            estimatedTarget = proceedsAtTarget + usdcIn;
        }

        // Size already reflects actual impact — 1% cushion is enough for
        // rounding and minor drift. `VIRTUAL_SAFETY_MARGIN_BPS` (3%) stays
        // unchanged for `_computeSellNoMaxCost` where the margin absorbs a
        // different error source (exact-out vs exact-in asymmetry).
        mintAmount = (estimatedTarget * BUY_NO_POST_IMPACT_MARGIN_BPS) / BPS_DENOMINATOR;
    }

    /// @notice Compute the USDC cost upper bound for flash-buying `noIn` YES in `sellNo`.
    function _computeSellNoMaxCost(address yesToken, uint256 noIn) internal returns (uint256 maxCost) {
        _preCommitForQuoter(yesToken);
        PoolKey memory key = _buildPoolKey(yesToken);
        IV4Quoter.QuoteExactSingleParams memory params = IV4Quoter.QuoteExactSingleParams({
            poolKey: key, zeroForOne: usdc < yesToken, exactAmount: uint128(noIn), hookData: ""
        });
        (uint256 costQuote,) = quoter.quoteExactOutputSingle(params);
        if (costQuote == 0) return type(uint256).max;
        maxCost = (costQuote * BPS_DENOMINATOR) / VIRTUAL_SAFETY_MARGIN_BPS;
    }

    /// @notice Enforce the diamond's `perMarketCap` against a prospective `splitPosition`.
    /// @dev `getMarket` is the heavy read — we only pay for it inside the virtual-NO path
    ///      where `splitPosition` is actually invoked. See spec §7 E18.
    function _enforcePerMarketCap(uint256 marketId, uint256 mintAmount) internal view {
        IMarketFacet.MarketView memory m = IMarketFacet(diamond).getMarket(marketId);
        if (m.perMarketCap != 0 && m.totalCollateral + mintAmount > m.perMarketCap) {
            revert PerMarketCapExceeded();
        }
    }

    // =========================================================================
    // Shared entry validation + execute cores (used by both regular and Permit2 variants)
    // =========================================================================

    /// @notice Run the deadline / amount / recipient / market gates once per entry call.
    /// @dev Returns the cached `(yesToken, noToken)` so the shared execute core does not
    ///      re-read the diamond.
    function _preEntry(uint256 amountIn, address recipient, uint256 deadline, uint256 marketId)
        internal
        view
        returns (address yesToken, address noToken)
    {
        _checkDeadline(deadline);
        if (amountIn < MIN_TRADE_AMOUNT) revert ZeroAmount();
        if (_isBannedRecipient(recipient)) revert InvalidRecipient();
        (yesToken, noToken,,,) = _validateMarket(marketId);
        // Tokens sent to their own contract address are permanently locked
        // because OutcomeToken has no rescue function.
        if (recipient == yesToken || recipient == noToken) revert InvalidRecipient();
    }

    /// @notice Pull `amount` of `token` from `msg.sender` via Permit2.
    /// @dev Enforces `permitSingle.details.amount == amount` (NEW-M5). A permit
    ///      signed for MORE than the trade would leave residual Permit2
    ///      allowance to the router — latent attack surface if any future
    ///      router bug introduces a user-controllable transferFrom destination.
    ///      UX trade-off: frontends MUST sign a per-trade permit with the exact
    ///      amount, not a single max-amount permit reused across trades.
    function _consumePermit(
        IAllowanceTransfer.PermitSingle calldata permitSingle,
        bytes calldata signature,
        uint160 amount,
        address token
    ) internal {
        if (permitSingle.details.token != token) revert InvalidPermitToken();
        if (permitSingle.details.amount != amount) revert InvalidPermitAmount();
        permit2.permit(msg.sender, permitSingle, signature);
        permit2.transferFrom(msg.sender, address(this), amount, token);
    }

    /// @notice Shared core flow for {buyYes} / {buyYesWithPermit}. Caller must have already
    ///         transferred `usdcIn` USDC into the router.
    function _buyYesExecute(
        uint256 marketId,
        uint256 usdcIn,
        uint256 minYesOut,
        address recipient,
        uint256 maxFills,
        uint256 deadline,
        address yesToken,
        address noToken
    ) internal returns (uint256 yesOut, uint256 clobFilled, uint256 ammFilled) {
        uint256 clobLimit = _clobBuyYesLimit(yesToken);
        uint256 usdcRemaining;
        (clobFilled, usdcRemaining) =
            _tryClobBuy(marketId, IPrediXExchangeView.Side.BUY_YES, clobLimit, usdcIn, maxFills, deadline);

        if (usdcRemaining > 0) {
            ammFilled = _executeAmmBuyYes(marketId, yesToken, noToken, usdcRemaining, msg.sender);
        }

        yesOut = clobFilled + ammFilled;
        if (yesOut == 0) revert ExactInUnfilled(usdcIn);
        if (yesOut < minYesOut) revert InsufficientOutput(yesOut, minYesOut);

        IERC20(yesToken).safeTransfer(recipient, yesOut);
        _finalizeAndAssertAllZero(yesToken, noToken);

        emit Trade(marketId, msg.sender, recipient, TradeType.BUY_YES, usdcIn, yesOut, clobFilled, ammFilled);
    }

    /// @notice Shared core flow for {sellYes} / {sellYesWithPermit}. `yesIn` must already be
    ///         transferred into the router.
    function _sellYesExecute(
        uint256 marketId,
        uint256 yesIn,
        uint256 minUsdcOut,
        address recipient,
        uint256 maxFills,
        uint256 deadline,
        address yesToken,
        address noToken
    ) internal returns (uint256 usdcOut, uint256 clobFilled, uint256 ammFilled) {
        _ensureApproval(yesToken, exchange);

        uint256 clobLimit = _clobSellYesLimit(yesToken);
        uint256 usdcBefore = IERC20(usdc).balanceOf(address(this));
        uint256 yesRemaining;
        (, yesRemaining) =
            _tryClobSell(marketId, IPrediXExchangeView.Side.SELL_YES, clobLimit, yesIn, maxFills, deadline);
        clobFilled = IERC20(usdc).balanceOf(address(this)) - usdcBefore;

        if (yesRemaining > 0) {
            ammFilled = _executeAmmSellYes(marketId, yesToken, noToken, yesRemaining, msg.sender);
        }

        usdcOut = clobFilled + ammFilled;
        if (usdcOut == 0) revert ExactInUnfilled(yesIn);
        if (usdcOut < minUsdcOut) revert InsufficientOutput(usdcOut, minUsdcOut);

        IERC20(usdc).safeTransfer(recipient, usdcOut);
        _finalizeAndAssertAllZero(yesToken, noToken);

        emit Trade(marketId, msg.sender, recipient, TradeType.SELL_YES, yesIn, usdcOut, clobFilled, ammFilled);
    }

    /// @notice Shared core flow for {buyNo} / {buyNoWithPermit}.
    function _buyNoExecute(
        uint256 marketId,
        uint256 usdcIn,
        uint256 minNoOut,
        address recipient,
        uint256 maxFills,
        uint256 deadline,
        address yesToken,
        address noToken
    ) internal returns (uint256 noOut, uint256 clobFilled, uint256 ammFilled) {
        uint256 clobLimit = _clobBuyNoLimit(yesToken);
        uint256 usdcRemaining;
        (clobFilled, usdcRemaining) =
            _tryClobBuy(marketId, IPrediXExchangeView.Side.BUY_NO, clobLimit, usdcIn, maxFills, deadline);

        if (usdcRemaining > 0) {
            ammFilled = _executeAmmBuyNo(marketId, yesToken, noToken, usdcRemaining, msg.sender);
        }

        noOut = clobFilled + ammFilled;
        if (noOut == 0) revert ExactInUnfilled(usdcIn);
        if (noOut < minNoOut) revert InsufficientOutput(noOut, minNoOut);

        IERC20(noToken).safeTransfer(recipient, noOut);
        _finalizeAndAssertAllZero(yesToken, noToken);

        emit Trade(marketId, msg.sender, recipient, TradeType.BUY_NO, usdcIn, noOut, clobFilled, ammFilled);
    }

    /// @notice Shared core flow for {sellNo} / {sellNoWithPermit}.
    function _sellNoExecute(
        uint256 marketId,
        uint256 noIn,
        uint256 minUsdcOut,
        address recipient,
        uint256 maxFills,
        uint256 deadline,
        address yesToken,
        address noToken
    ) internal returns (uint256 usdcOut, uint256 clobFilled, uint256 ammFilled) {
        _ensureApproval(noToken, exchange);

        uint256 clobLimit = _clobSellNoLimit(yesToken);
        uint256 usdcBefore = IERC20(usdc).balanceOf(address(this));
        uint256 noRemaining;
        (, noRemaining) = _tryClobSell(marketId, IPrediXExchangeView.Side.SELL_NO, clobLimit, noIn, maxFills, deadline);
        clobFilled = IERC20(usdc).balanceOf(address(this)) - usdcBefore;

        if (noRemaining > 0) {
            ammFilled = _executeAmmSellNo(marketId, yesToken, noToken, noRemaining, msg.sender);
        }

        usdcOut = clobFilled + ammFilled;
        if (usdcOut == 0) revert ExactInUnfilled(noIn);
        if (usdcOut < minUsdcOut) revert InsufficientOutput(usdcOut, minUsdcOut);

        IERC20(usdc).safeTransfer(recipient, usdcOut);
        _finalizeAndAssertAllZero(yesToken, noToken);

        emit Trade(marketId, msg.sender, recipient, TradeType.SELL_NO, noIn, usdcOut, clobFilled, ammFilled);
    }
}
