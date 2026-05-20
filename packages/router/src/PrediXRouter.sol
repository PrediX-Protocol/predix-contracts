// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

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
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";

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
    using StateLibrary for IPoolManager;

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

    /// @notice Precision cushion for virtual-NO paths. Quote and actual swap go
    ///         through the same hook code path with the same dynamic-fee override,
    ///         so the only divergence between them is quoter-vs-actual EVM
    ///         precision drift across tick boundaries (empirically <0.5% on
    ///         well-formed pools). The cushion absorbs that drift.
    ///
    ///         A LARGER cushion would charge NO traders a hidden cost
    ///         disproportionate to YES traders (who carry no internal cushion at
    ///         all). A SMALLER cushion would expose user-facing reverts to
    ///         routine quoter precision drift.
    ///
    ///         Both buyNo and sellNo paths use the same value so the hidden cost
    ///         is symmetric across NO entry/exit. The path-D iterative sizing in
    ///         `_computeBuyNoMintAmount` makes the cushion's job purely
    ///         precision drift — the algebraic feasibility is already guaranteed
    ///         by quoting at the exact swap size.
    uint256 internal constant SELL_NO_PRECISION_CUSHION_BPS = 9950;
    uint256 internal constant BUY_NO_PRECISION_CUSHION_BPS = 9950;

    /// @notice Maximum iterations the virtual-NO sizing loop runs. Each
    ///         iteration is a fixed-point step that shrinks the gap between
    ///         the quoted swap size and the size whose proceeds the user's
    ///         `usdcIn` can cover. Convergence is guaranteed because every
    ///         step strictly shrinks the size, and the function returns the
    ///         tighter of `size` or `proceeds + usdcIn` at the loop exit. The
    ///         empirical convergence rate is 2 iterations for normal pools
    ///         and 3 for extreme concentration; cap at 3 to keep gas
    ///         predictable.
    uint256 internal constant BUY_NO_SIZING_MAX_ITER = 3;

    uint256 internal constant BPS_DENOMINATOR = 10_000;

    // Expected exchange error selectors — graceful fallback to AMM when the
    // CLOB cannot fill. All other selectors indicate caller/protocol bugs
    // and MUST propagate. Selectors copied here because the monorepo
    // boundary rule forbids importing cross-package `src/`.
    bytes4 private constant _EX_PAUSED = bytes4(keccak256("ExchangePaused()"));
    bytes4 private constant _EX_MARKET_PAUSED = bytes4(keccak256("MarketPaused()"));
    bytes4 private constant _EX_MARKET_EXPIRED = bytes4(keccak256("MarketExpired()"));
    bytes4 private constant _EX_MARKET_RESOLVED = bytes4(keccak256("MarketResolved()"));
    bytes4 private constant _EX_MARKET_REFUND = bytes4(keccak256("MarketInRefundMode()"));
    bytes4 private constant _EX_DEADLINE = bytes4(keccak256("DeadlineExpired(uint256,uint256)"));
    bytes4 private constant _EX_NO_LIQUIDITY = bytes4(keccak256("InsufficientLiquidity()"));

    /// @notice Price precision used by the CLOB and by the AMM fee math (1e6 = 100%).
    uint256 internal constant PRICE_PRECISION = 1e6;

    /// @notice Canonical Permit2 deployment address. Deterministic across every EVM
    ///         chain via the deployer pattern documented in the Uniswap Permit2 repo.
    ///         Exposed as a constant so off-chain tooling and the deploy verifier can
    ///         assert the router was wired to the real Permit2 in production.
    address public constant CANONICAL_PERMIT2 = 0x000000000022D473030F116dDEE9F6B43aC78BA3;

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

    /// @notice Uniswap v4 Quoter — used for AMM quotes.
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

        // Canonical pool shape: the hook's `registerMarketPool` rejects
        // non-canonical fee / tickSpacing. Catching zero here at construction
        // gives a louder, earlier failure than a confusing pool-registration
        // revert later. The hook's own constructor applies the same checks.
        if (_lpFeeFlag == 0) revert InvalidLpFeeFlag();
        if (_tickSpacing == 0) revert InvalidTickSpacing();

        // Catch the obvious "deployer pointed at an EOA" typo. The audited
        // canonical Permit2 lives at `CANONICAL_PERMIT2`, but test fixtures
        // and pre-canonical-deployment chains may legitimately wire a fresh
        // Permit2 — enforcing the canonical address here would break those
        // paths. Verifying that the target has contract code is the minimum
        // viable check; deploy-time `verifyPostDeploy` should additionally
        // assert `address(permit2) == CANONICAL_PERMIT2` for mainnet.
        if (address(_permit2).code.length == 0) revert Permit2NotAContract();

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
            .previewFillMarketOrder(marketId, IPrediXExchangeView.Side.BUY_YES, clobLimit, usdcIn, maxFills, address(0));

        uint256 usdcLeft = usdcIn - clobCost;
        if (usdcLeft > 0 && _hasPool(yesToken)) {
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
        (clobPortion, sharesFilled) = IPrediXExchangeView(exchange)
            .previewFillMarketOrder(marketId, IPrediXExchangeView.Side.SELL_YES, clobLimit, yesIn, maxFills, address(0));

        uint256 yesLeft = yesIn - sharesFilled;
        if (yesLeft > 0 && _hasPool(yesToken)) {
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
            .previewFillMarketOrder(marketId, IPrediXExchangeView.Side.BUY_NO, clobLimit, usdcIn, maxFills, address(0));

        uint256 usdcLeft = usdcIn - clobCost;
        if (usdcLeft > 0 && _hasPool(yesToken)) {
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
        (clobPortion, sharesFilled) = IPrediXExchangeView(exchange)
            .previewFillMarketOrder(marketId, IPrediXExchangeView.Side.SELL_NO, clobLimit, noIn, maxFills, address(0));

        uint256 noLeft = noIn - sharesFilled;
        if (noLeft > 0 && _hasPool(yesToken)) {
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
            || recipient == address(permit2) || recipient == usdc;
    }

    /// @notice Returns true if the YES/USDC pool is initialized on the PoolManager.
    function _hasPool(address yesToken) internal view returns (bool) {
        PoolKey memory key = _buildPoolKey(yesToken);
        (uint160 sqrtPriceX96,,,) = poolManager.getSlot0(key.toId());
        return sqrtPriceX96 != 0;
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
                marketId, side, limitPrice, amountIn, address(this), address(this), maxFills, deadline, bytes32(0)
            ) returns (
            uint256 _filled, uint256 _cost
        ) {
            filled = _filled;
            amountInRemaining = amountIn - _cost;
        } catch (bytes memory err) {
            bytes4 sel = err.length >= 4 ? bytes4(err) : bytes4(0);
            if (!_isClobGracefulError(sel)) {
                assembly ("memory-safe") {
                    revert(add(err, 0x20), mload(err))
                }
            }
            filled = 0;
            amountInRemaining = amountIn;
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
                marketId, side, limitPrice, amountIn, address(this), address(this), maxFills, deadline, bytes32(0)
            ) returns (
            uint256 _filled, uint256 _cost
        ) {
            filled = _filled;
            amountInRemaining = amountIn - _cost;
        } catch (bytes memory err) {
            bytes4 sel = err.length >= 4 ? bytes4(err) : bytes4(0);
            if (!_isClobGracefulError(sel)) {
                assembly ("memory-safe") {
                    revert(add(err, 0x20), mload(err))
                }
            }
            filled = 0;
            amountInRemaining = amountIn;
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
    // Quoter identity pre-commit
    // =========================================================================

    /// @dev Pre-commit `msg.sender` identity under the quoter's transient slot so
    ///      `V4Quoter.quoteExactInputSingle` / `quoteExactOutputSingle` can pass
    ///      the hook's identity-commit gate during simulate-and-revert. Must be
    ///      called before every quoter invocation in the same transaction. Both the
    ///      router and the quoter must be in the hook's trusted-router set.
    function _preCommitForQuoter(address yesToken) internal {
        PoolKey memory key = _buildPoolKey(yesToken);
        IPrediXHookCommit(hook).commitSwapIdentityFor(address(quoter), msg.sender, key.toId());
    }

    // =========================================================================
    // CLOB price caps — fee-adjusted AMM spot
    // =========================================================================

    /// @notice Fee-adjusted AMM spot price for buying YES, in USDC/YES with 1e6 precision.
    /// @dev Returns 0 when the pool is uninitialized or empty so callers fall back to a
    ///      permissive CLOB cap rather than reverting.
    function _ammSpotPriceForBuy(address yesToken) internal returns (uint256 usdcPerYes) {
        if (!_hasPool(yesToken)) return 0;
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
        if (!_hasPool(yesToken)) return 0;
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

    /// @notice Compute `mintAmount` for `buyNo` via iterative fixed-point sizing.
    /// @dev The callback flash-SELLS `mintAmount` YES (USDC ← YES) and uses the
    ///      proceeds plus the user's `usdcIn` to fund `diamond.splitPosition(mintAmount)`.
    ///      The budget invariant is:
    ///          proceeds(mintAmount) + usdcIn >= mintAmount
    ///
    ///      The historical 2-pass design (quote at linear-spot estimate `X`,
    ///      cushion to `0.99X`, then swap at the cushioned size) introduced an
    ///      algebraic gap: the quote at `X` over-estimated the per-unit proceeds
    ///      available at the cushioned-down swap size. A linear pool's
    ///      `proceeds(αX) ≥ α × proceeds(X)` bound for `α < 1` was too weak to
    ///      close the budget invariant on non-trivial trade sizes — the only
    ///      thing rescuing the path was real-pool concavity (which is bounded
    ///      and runs out at ~1% of pool liquidity).
    ///
    ///      Path D (this implementation) closes the gap by iterating: each step
    ///      quotes at the CURRENT candidate size and shrinks the size until the
    ///      quote's reported proceeds plus `usdcIn` are at least the size. Once
    ///      converged, the quote is at the EXACT size the callback will swap, so
    ///      the linear bound collapses to equality and the budget invariant is
    ///      guaranteed by construction (within quoter-vs-actual precision drift,
    ///      absorbed by `BUY_NO_PRECISION_CUSHION_BPS`).
    ///
    ///      The economic identity uses the fee-adjusted SELL-direction spot:
    ///      `usdcPerYesSell` bakes the hook's dynamic fee into the proceeds a
    ///      seller receives. The buy-direction spot would over-estimate
    ///      `mintAmount` by `fee / (1 - fee)`, so we always read the sell side.
    function _computeBuyNoMintAmount(address yesToken, uint256 usdcIn) internal returns (uint256 mintAmount) {
        // Pass 1: spot probe → linear no-impact extrapolation. Bootstraps the
        // iteration with a feasibility estimate before the first quote.
        uint256 usdcPerYesSell = _ammSpotPriceForSell(yesToken);
        if (usdcPerYesSell == 0 || usdcPerYesSell >= PRICE_PRECISION) return 0;

        uint256 effectiveNoPrice = PRICE_PRECISION - usdcPerYesSell;
        uint256 size = (usdcIn * PRICE_PRECISION) / effectiveNoPrice;
        if (size == 0) return 0;

        PoolKey memory key = _buildPoolKey(yesToken);
        bool zeroForOne = yesToken < usdc;

        // Iterative sizing — quote at the candidate size, shrink to feasible
        // size if budget short, then re-quote at the new (smaller) size. The
        // quoter's per-unit price improves monotonically as size shrinks
        // (concentrated-liquidity concavity), so each iteration strictly
        // shrinks the gap. Convergence is empirically 2 iterations for normal
        // pools and 3 for extreme concentration. Pathologically linear pool
        // curves may not fully converge inside `MAX_ITER`; the final safety
        // re-quote below handles that case.
        for (uint256 i = 0; i < BUY_NO_SIZING_MAX_ITER; ++i) {
            _preCommitForQuoter(yesToken);
            (uint256 proceeds,) = quoter.quoteExactInputSingle(
                IV4Quoter.QuoteExactSingleParams({
                    poolKey: key,
                    zeroForOne: zeroForOne,
                    exactAmount: uint128(size),
                    hookData: ""
                })
            );
            if (proceeds + usdcIn >= size) {
                // Converged — the next swap-size quote covers the budget.
                break;
            }
            // Pool can absorb less than `size`; shrink to the strictly
            // feasible budget and re-quote at the smaller size next round.
            uint256 newSize = proceeds + usdcIn;
            if (newSize == 0 || newSize >= size) {
                // Saturated or non-monotone — no further shrink possible.
                size = newSize == 0 ? size : newSize;
                break;
            }
            size = newSize;
        }

        // Apply precision cushion against quoter-vs-actual EVM drift across
        // tick boundaries.
        uint256 candidate = (size * BUY_NO_PRECISION_CUSHION_BPS) / BPS_DENOMINATOR;
        if (candidate == 0) return 0;

        // Final safety quote at the EXACT amount the callback will swap.
        // This collapses the algebraic LB to equality: if `proceeds + usdcIn
        // >= candidate` here, the callback's invariant is guaranteed by
        // construction (modulo the cushion's own precision tolerance). If
        // not, the iteration didn't converge within `MAX_ITER` (rare,
        // requires near-linear liquidity over the whole swap range) — cap
        // strictly at the quoter-confirmed feasible budget instead of
        // letting the callback revert.
        _preCommitForQuoter(yesToken);
        (uint256 finalProceeds,) = quoter.quoteExactInputSingle(
            IV4Quoter.QuoteExactSingleParams({
                poolKey: key,
                zeroForOne: zeroForOne,
                exactAmount: uint128(candidate),
                hookData: ""
            })
        );
        if (finalProceeds + usdcIn >= candidate) {
            mintAmount = candidate;
        } else {
            // Strict cap at quoter-confirmed budget. The callback's invariant
            // becomes `proceedsActual(mintAmount) + usdcIn >= mintAmount`,
            // which holds because `mintAmount < candidate` and quoter precision
            // drift is bounded by `BUY_NO_PRECISION_CUSHION_BPS` against the
            // already-checked `finalProceeds`.
            mintAmount = finalProceeds + usdcIn;
        }
    }

    /// @notice Compute the USDC cost upper bound for flash-buying `noIn` YES in `sellNo`.
    /// @dev `quoteExactOutputSingle` is called at the EXACT swap size (`noIn`)
    ///      so the only divergence is quoter-vs-actual precision drift —
    ///      identical safety profile to the buyNo path post-Path-D. The
    ///      cushion bumps the max-cost up by `1 / SELL_NO_PRECISION_CUSHION_BPS`
    ///      so a small per-tick rounding discrepancy does not revert the
    ///      callback.
    function _computeSellNoMaxCost(address yesToken, uint256 noIn) internal returns (uint256 maxCost) {
        _preCommitForQuoter(yesToken);
        PoolKey memory key = _buildPoolKey(yesToken);
        IV4Quoter.QuoteExactSingleParams memory params = IV4Quoter.QuoteExactSingleParams({
            poolKey: key, zeroForOne: usdc < yesToken, exactAmount: uint128(noIn), hookData: ""
        });
        (uint256 costQuote,) = quoter.quoteExactOutputSingle(params);
        if (costQuote == 0) return type(uint256).max;
        maxCost = (costQuote * BPS_DENOMINATOR) / SELL_NO_PRECISION_CUSHION_BPS;
    }

    /// @notice Enforce the diamond's effective per-market cap against a prospective `splitPosition`.
    /// @dev `getMarket` is the heavy read — we only pay for it inside the virtual-NO path
    ///      where `splitPosition` is actually invoked. See spec §7 E18.
    /// @dev Mirrors the diamond's effective-cap formula
    ///      `cap = perMarketCap > 0 ? perMarketCap : defaultPerMarketCap`.
    ///      Both the per-market override and the global default are checked so
    ///      default-capped markets do not silently pass pre-flight then revert
    ///      deep inside the unlock callback after gas was spent.
    function _enforcePerMarketCap(uint256 marketId, uint256 mintAmount) internal view {
        IMarketFacet.MarketView memory m = IMarketFacet(diamond).getMarket(marketId);
        uint256 cap = m.perMarketCap > 0 ? m.perMarketCap : IMarketFacet(diamond).defaultPerMarketCap();
        if (cap > 0 && m.totalCollateral + mintAmount > cap) {
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
    /// @dev Enforces `permitSingle.details.amount == amount`. A permit
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
        // Reject permits signed for a different spender BEFORE touching Permit2.
        // Without this check the downstream `transferFrom` would revert deep
        // inside Permit2 with an opaque allowance error — fail here with a
        // selector tooling can pattern-match on.
        if (permitSingle.spender != address(this)) revert InvalidPermitSpender();
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

        bool hasAmm = _hasPool(yesToken);
        if (usdcRemaining > 0 && hasAmm) {
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

        if (yesRemaining > 0 && _hasPool(yesToken)) {
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

        if (usdcRemaining > 0 && _hasPool(yesToken)) {
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

        if (noRemaining > 0 && _hasPool(yesToken)) {
            ammFilled = _executeAmmSellNo(marketId, yesToken, noToken, noRemaining, msg.sender);
        }

        usdcOut = clobFilled + ammFilled;
        if (usdcOut == 0) revert ExactInUnfilled(noIn);
        if (usdcOut < minUsdcOut) revert InsufficientOutput(usdcOut, minUsdcOut);

        IERC20(usdc).safeTransfer(recipient, usdcOut);
        _finalizeAndAssertAllZero(yesToken, noToken);

        emit Trade(marketId, msg.sender, recipient, TradeType.SELL_NO, noIn, usdcOut, clobFilled, ammFilled);
    }

    function _isClobGracefulError(bytes4 sel) private pure returns (bool) {
        return sel == _EX_PAUSED || sel == _EX_MARKET_PAUSED || sel == _EX_MARKET_EXPIRED
            || sel == _EX_MARKET_RESOLVED || sel == _EX_MARKET_REFUND || sel == _EX_DEADLINE
            || sel == _EX_NO_LIQUIDITY;
    }
}
