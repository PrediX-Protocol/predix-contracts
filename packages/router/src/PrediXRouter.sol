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
import {IBuilderRegistry} from "@predix/shared/interfaces/IBuilderRegistry.sol";

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

    /// @notice Maximum re-quote rounds when converging the CLOB cap toward the
    ///         AMM effective price at the orderbook-adjusted remainder. Each
    ///         round is one `previewFillMarketOrder` + one effective-price
    ///         quote. The cap walks from the spot-sized effective toward the
    ///         fixed point where the marginal CLOB order equals the AMM
    ///         effective for the leftover size — the optimal CLOB/AMM split.
    ///         Bounded to keep gas predictable; trades whose CLOB depth spans
    ///         more than this many price tranches converge approximately and
    ///         fall back to the last (slightly permissive) cap for the tail.
    uint256 internal constant CLOB_CAP_CONVERGE_ROUNDS = 3;

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

    /// @notice Builder Program registry (Sub-plan 01). The router reads only `feeOf(code).takerBps`
    ///         for the AMM-leg builder fee. Immutable — a registry rotation is a router redeploy.
    IBuilderRegistry public immutable builderRegistry;

    // =========================================================================
    // Constructor
    // =========================================================================

    /// @notice Wire the router to its infrastructure dependencies. All addresses are
    ///         immutable; there is no post-deploy setter for any of them.
    /// @dev Pre-approves the diamond and the exchange for infinite USDC so the hot path
    ///      never pays for an `approve` call. YES/NO outcome-token approvals to the exchange
    ///      are lazy because every market deploys its own ERC20 pair.
    /// @dev `diamond` is immutable: a diamond rotation (replacing the diamond proxy with a
    ///      new deployment) requires redeploying this router and pointing the new instance
    ///      at the new diamond. There is no in-place setter; this is by design so this
    ///      contract's trust binding cannot be silently retargeted post-deploy.
    constructor(
        IPoolManager _poolManager,
        address _diamond,
        address _usdc,
        address _hook,
        address _exchange,
        IV4Quoter _quoter,
        IAllowanceTransfer _permit2,
        uint24 _lpFeeFlag,
        int24 _tickSpacing,
        IBuilderRegistry _builderRegistry
    ) {
        if (
            address(_poolManager) == address(0) || _diamond == address(0) || _usdc == address(0) || _hook == address(0)
                || _exchange == address(0) || address(_quoter) == address(0) || address(_permit2) == address(0)
                || address(_builderRegistry) == address(0)
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
        builderRegistry = _builderRegistry;

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
        uint256 deadline,
        bytes32 builder
    ) external nonReentrant returns (uint256 yesOut, uint256 clobFilled, uint256 ammFilled) {
        (address yesToken, address noToken) = _preEntry(usdcIn, recipient, deadline, marketId);
        IERC20(usdc).safeTransferFrom(msg.sender, address(this), usdcIn);
        return _buyYesExecute(marketId, usdcIn, minYesOut, recipient, maxFills, deadline, yesToken, noToken, builder);
    }

    /// @inheritdoc IPrediXRouter
    function sellYes(
        uint256 marketId,
        uint256 yesIn,
        uint256 minUsdcOut,
        address recipient,
        uint256 maxFills,
        uint256 deadline,
        bytes32 builder
    ) external nonReentrant returns (uint256 usdcOut, uint256 clobFilled, uint256 ammFilled) {
        (address yesToken, address noToken) = _preEntry(yesIn, recipient, deadline, marketId);
        IERC20(yesToken).safeTransferFrom(msg.sender, address(this), yesIn);
        return _sellYesExecute(marketId, yesIn, minUsdcOut, recipient, maxFills, deadline, yesToken, noToken, builder);
    }

    /// @inheritdoc IPrediXRouter
    function buyNo(
        uint256 marketId,
        uint256 usdcIn,
        uint256 minNoOut,
        address recipient,
        uint256 maxFills,
        uint256 deadline,
        bytes32 builder
    ) external nonReentrant returns (uint256 noOut, uint256 clobFilled, uint256 ammFilled) {
        (address yesToken, address noToken) = _preEntry(usdcIn, recipient, deadline, marketId);
        IERC20(usdc).safeTransferFrom(msg.sender, address(this), usdcIn);
        return _buyNoExecute(marketId, usdcIn, minNoOut, recipient, maxFills, deadline, yesToken, noToken, builder);
    }

    /// @inheritdoc IPrediXRouter
    function sellNo(
        uint256 marketId,
        uint256 noIn,
        uint256 minUsdcOut,
        address recipient,
        uint256 maxFills,
        uint256 deadline,
        bytes32 builder
    ) external nonReentrant returns (uint256 usdcOut, uint256 clobFilled, uint256 ammFilled) {
        (address yesToken, address noToken) = _preEntry(noIn, recipient, deadline, marketId);
        IERC20(noToken).safeTransferFrom(msg.sender, address(this), noIn);
        return _sellNoExecute(marketId, noIn, minUsdcOut, recipient, maxFills, deadline, yesToken, noToken, builder);
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
        bytes calldata signature,
        bytes32 builder
    ) external nonReentrant returns (uint256 yesOut, uint256 clobFilled, uint256 ammFilled) {
        (address yesToken, address noToken) = _preEntry(usdcIn, recipient, deadline, marketId);
        _consumePermit(permitSingle, signature, uint160(usdcIn), usdc);
        return _buyYesExecute(marketId, usdcIn, minYesOut, recipient, maxFills, deadline, yesToken, noToken, builder);
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
        bytes calldata signature,
        bytes32 builder
    ) external nonReentrant returns (uint256 usdcOut, uint256 clobFilled, uint256 ammFilled) {
        (address yesToken, address noToken) = _preEntry(yesIn, recipient, deadline, marketId);
        _consumePermit(permitSingle, signature, uint160(yesIn), yesToken);
        return _sellYesExecute(marketId, yesIn, minUsdcOut, recipient, maxFills, deadline, yesToken, noToken, builder);
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
        bytes calldata signature,
        bytes32 builder
    ) external nonReentrant returns (uint256 noOut, uint256 clobFilled, uint256 ammFilled) {
        (address yesToken, address noToken) = _preEntry(usdcIn, recipient, deadline, marketId);
        _consumePermit(permitSingle, signature, uint160(usdcIn), usdc);
        return _buyNoExecute(marketId, usdcIn, minNoOut, recipient, maxFills, deadline, yesToken, noToken, builder);
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
        bytes calldata signature,
        bytes32 builder
    ) external nonReentrant returns (uint256 usdcOut, uint256 clobFilled, uint256 ammFilled) {
        (address yesToken, address noToken) = _preEntry(noIn, recipient, deadline, marketId);
        _consumePermit(permitSingle, signature, uint160(noIn), noToken);
        return _sellNoExecute(marketId, noIn, minUsdcOut, recipient, maxFills, deadline, yesToken, noToken, builder);
    }

    /// @inheritdoc IPrediXRouter
    function quoteBuyYes(uint256 marketId, uint256 usdcIn, uint256 maxFills)
        external
        returns (uint256 expectedYesOut, uint256 clobPortion, uint256 ammPortion)
    {
        (address yesToken,,,,) = _quoteMarketStatus(marketId);
        if (yesToken == address(0) || usdcIn < MIN_TRADE_AMOUNT) return (0, 0, 0);

        uint256 clobLimit =
            _convergeCap(marketId, IPrediXExchangeView.Side.BUY_YES, CapKind.BUY_YES, yesToken, usdcIn, maxFills);
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

        uint256 clobLimit =
            _convergeCap(marketId, IPrediXExchangeView.Side.SELL_YES, CapKind.SELL_YES, yesToken, yesIn, maxFills);
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

        uint256 clobLimit =
            _convergeCap(marketId, IPrediXExchangeView.Side.BUY_NO, CapKind.BUY_NO, yesToken, usdcIn, maxFills);
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

        uint256 clobLimit =
            _convergeCap(marketId, IPrediXExchangeView.Side.SELL_NO, CapKind.SELL_NO, yesToken, noIn, maxFills);
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
        PoolId poolId = key.toId();
        // A set price alone isn't enough to route to the AMM: a registered + initialized pool with no active
        // liquidity reverts NotEnoughLiquidity on swap (the v4 Quoter re-wraps it, so the FE surfaces "no AMM
        // pool"), blocking market orders the CLOB could otherwise fill. Gate on liquidity so the router falls
        // back to 100% CLOB when the AMM cannot fill.
        (uint160 sqrtPriceX96,,,) = poolManager.getSlot0(poolId);
        if (sqrtPriceX96 == 0) return false;
        return poolManager.getLiquidity(poolId) > 0;
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
        uint256 deadline,
        bytes32 builder
    ) internal returns (uint256 filled, uint256 amountInRemaining) {
        try IPrediXExchangeView(exchange)
            .fillMarketOrder(
                marketId, side, limitPrice, amountIn, address(this), address(this), maxFills, deadline, builder
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
        // RTR-1 (clm6.7): the swap + flash settlement run inside `unlock`; on revert (InsufficientLiquidity /
        // slippage / a callback guard) ship the CLOB-only fill instead of reverting the whole atomic trade.
        // Surface the selector via AmmSkipped — do NOT swallow silently.
        try poolManager.unlock(data) returns (bytes memory result) {
            yesOut = abi.decode(result, (uint256));
        } catch (bytes memory err) {
            emit AmmSkipped(marketId, user, err.length >= 4 ? bytes4(err) : bytes4(0));
            return 0;
        }
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
        uint256 deadline,
        bytes32 builder
    ) internal returns (uint256 filled, uint256 amountInRemaining) {
        try IPrediXExchangeView(exchange)
            .fillMarketOrder(
                marketId, side, limitPrice, amountIn, address(this), address(this), maxFills, deadline, builder
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
        // RTR-1 (clm6.7): catch an AMM-leg revert and ship CLOB-only rather than reverting the whole trade.
        try poolManager.unlock(data) returns (bytes memory result) {
            usdcOut = abi.decode(result, (uint256));
        } catch (bytes memory err) {
            emit AmmSkipped(marketId, user, err.length >= 4 ? bytes4(err) : bytes4(0));
            return 0;
        }
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
        // RTR-1 (clm6.7): catch an AMM-leg revert (e.g. QuoteOutsideSafetyMargin / InsufficientLiquidity in
        // `_callbackBuyNo`) and ship CLOB-only rather than reverting the whole atomic trade.
        try poolManager.unlock(data) returns (bytes memory result) {
            noOut = abi.decode(result, (uint256));
        } catch (bytes memory err) {
            emit AmmSkipped(marketId, user, err.length >= 4 ? bytes4(err) : bytes4(0));
            return 0;
        }
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
        // Pool-direction equivalence: flash-sells YES, same direction as
        // `_callbackSellYes`. The hook's anti-sandwich detector groups
        // BUY_NO with SELL_YES (push YES price down) and BUY_YES with
        // SELL_NO (push YES price up); cross-class same-block from the
        // same identity reverts `Hook_SandwichDetected`. See
        // `packages/hook/test/repro/RouterCallbackDirectionMatrix.t.sol`
        // for the full pinned matrix.
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
        // RTR-1 (clm6.7): catch an AMM-leg revert and ship CLOB-only rather than reverting the whole trade.
        try poolManager.unlock(data) returns (bytes memory result) {
            usdcOut = abi.decode(result, (uint256));
        } catch (bytes memory err) {
            emit AmmSkipped(marketId, user, err.length >= 4 ? bytes4(err) : bytes4(0));
            return 0;
        }
    }

    /// @notice Callback body for `SELL_NO`. Router enters holding `noIn` NO. It buys `noIn`
    ///         YES from the pool (exact-out), merges YES+NO for USDC, settles the USDC cost.
    function _callbackSellNo(AmmCtx memory ctx, uint256 maxCost) internal returns (uint256 usdcOut) {
        uint256 noIn = ctx.amountIn;

        // Pool-direction equivalence: flash-buys YES, same direction as
        // `_callbackBuyYes`. Cross-class same-block sequences (e.g.
        // SELL_NO → BUY_NO or SELL_YES → SELL_NO) revert in the hook's
        // sandwich detector by design. Users wanting an atomic "hedge both
        // sides" should call `MarketFacet.splitPosition` instead.
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

    /// @notice Fee-adjusted AMM spot price when selling YES, in USDC/YES with 1e6 precision.
    /// @dev Spot probe (exactAmount = 1e6) used to bootstrap the virtual-NO mint
    ///      estimate in `_clobBuyNoLimit` and Pass 1 of `_computeBuyNoMintAmount`.
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

    /// @notice Flat-bps fee on a USDC amount — the AMM-leg builder fee. `bps` is the builder's taker
    ///         rate read from the registry (a true rate, capped at 100 bps by the registry).
    function _feeOn(uint256 amount, uint16 bps) internal pure returns (uint256) {
        return (amount * bps) / BPS_DENOMINATOR;
    }

    /// @notice Protocol-fee price curve: `shares × coef × p × (1e6 − p) / 1e16` (`PROTOCOL_FEE_DESIGN.md`
    ///         §1; divisor 1e16, NOT 1e12). `coefBps` is the COEFFICIENT, `p` the traded-side price in 1e6
    ///         units. Returns 0 on coef==0 (launch) or p out of (0,1e6).
    function _curveFee(uint256 shares, uint16 coefBps, uint256 p) internal pure returns (uint256) {
        if (coefBps == 0 || p == 0 || p >= PRICE_PRECISION) return 0;
        return (shares * uint256(coefBps) * p * (PRICE_PRECISION - p)) / 1e16;
    }

    /// @notice Conservative pre-swap protocol-fee reserve for a BUY AMM leg. Reserves at the fee-maximizing
    ///         p=0.5 over a no-impact YES-out estimate. Because the curve peaks at 0.5 and the impacted
    ///         `ammFilled` is ≤ the no-impact `yesEst`, this reserve ≥ the post-swap recomputed `_curveFee`
    ///         whenever the leg fills (so no post-swap clamp is needed); over-reserve is refunded by the
    ///         finalize canary. F4-2: clamped to `usdcForLeg` so an extreme-price estimate can never make the
    ///         caller's `ammSpend` underflow (worst case reserve==budget → ammSpend 0 → leg skips, refunded).
    ///         Returns 0 at launch coef 0.
    function _reserveProtocolFee(address yesToken, uint256 usdcForLeg, uint16 coefBps) internal returns (uint256) {
        if (coefBps == 0 || usdcForLeg == 0) return 0;
        uint256 effective = _ammEffectivePriceForBuy(yesToken, uint128(usdcForLeg));
        if (effective == 0) return 0;
        uint256 r = _curveFee((usdcForLeg * PRICE_PRECISION) / effective, coefBps, PRICE_PRECISION / 2);
        return r > usdcForLeg ? usdcForLeg : r;
    }

    /// @dev buyYes AMM leg with builder + protocol fee carve. Builder flat-bps on the USDC in; protocol fee
    ///      reserved at p=0.5 then recomputed on the realized fill. F4-2 clamps guard the extreme-price case
    ///      (reserve > budget / recompute > residual) so the trade never reverts/over-pulls. Own stack frame.
    function _ammBuyYesWithFees(
        uint256 marketId,
        address yesToken,
        address noToken,
        uint256 usdcRemaining,
        bytes32 builder
    ) internal returns (uint256 ammFilled) {
        (uint16 takerBps,,) = builder == bytes32(0)
            ? (uint16(0), uint16(0), address(0))
            : builderRegistry.feeOf(builder);
        uint16 coefBps = IMarketFacet(diamond).getMarket(marketId).protocolFeeRateBps;
        uint256 builderFee = _feeOn(usdcRemaining, takerBps);
        uint256 ammSpend =
            usdcRemaining - builderFee - _reserveProtocolFee(yesToken, usdcRemaining - builderFee, coefBps);
        ammFilled = _executeAmmBuyYes(marketId, yesToken, noToken, ammSpend, msg.sender);
        if (ammFilled > 0) {
            uint256 protocolFee = _curveFee(ammFilled, coefBps, (ammSpend * PRICE_PRECISION) / ammFilled);
            if (builderFee > 0) IPrediXExchangeView(exchange).depositBuilderFee(builder, builderFee);
            if (protocolFee > 0) IPrediXExchangeView(exchange).depositProtocolFee(protocolFee);
        }
    }

    /// @dev buyNo AMM leg with builder + protocol fee. The full `usdcRemaining` stays in the router during the
    ///      leg so the buyNo split-solvency gate reads enough USDC; fees are carved AFTER. `p` is a balance
    ///      delta (USDC actually consumed by the leg) per §13, snapshotted tightly around `_executeAmmBuyNo`.
    ///      F4-2: the protocol fee is clamped to the residual the router holds (the YES-out reserve is NOT a
    ///      guaranteed upper bound under the balance-delta basis) so the trade never over-pulls / reverts.
    function _ammBuyNoWithFees(
        uint256 marketId,
        address yesToken,
        address noToken,
        uint256 usdcRemaining,
        bytes32 builder
    ) internal returns (uint256 ammFilled) {
        (uint16 takerBps,,) = builder == bytes32(0)
            ? (uint16(0), uint16(0), address(0))
            : builderRegistry.feeOf(builder);
        uint16 coefBps = IMarketFacet(diamond).getMarket(marketId).protocolFeeRateBps;
        uint256 builderFee = _feeOn(usdcRemaining, takerBps);
        uint256 ammSpend =
            usdcRemaining - builderFee - _reserveProtocolFee(yesToken, usdcRemaining - builderFee, coefBps);
        uint256 balBefore = IERC20(usdc).balanceOf(address(this));
        ammFilled = _executeAmmBuyNo(marketId, yesToken, noToken, ammSpend, msg.sender);
        if (ammFilled > 0) {
            uint256 protocolFee = _curveFee(
                ammFilled, coefBps, ((balBefore - IERC20(usdc).balanceOf(address(this))) * PRICE_PRECISION) / ammFilled
            );
            if (builderFee > 0) IPrediXExchangeView(exchange).depositBuilderFee(builder, builderFee);
            uint256 room = IERC20(usdc).balanceOf(address(this));
            if (protocolFee > room) protocolFee = room;
            if (protocolFee > 0) IPrediXExchangeView(exchange).depositProtocolFee(protocolFee);
        }
    }

    /// @notice Fee-adjusted AMM effective price for buying YES at `usdcSize` USDC in.
    /// @dev Quotes `quoteExactInputSingle(usdcSize)` and divides input by output to get the
    ///      blended USDC-per-YES the swap would pay across the full trade. Used to size the
    ///      CLOB cap so the orderbook is not forced to undercut spot when the actual
    ///      AMM-effective price is higher under slippage. Returns 0 if the pool is empty.
    function _ammEffectivePriceForBuy(address yesToken, uint128 usdcSize) internal returns (uint256 usdcPerYes) {
        if (!_hasPool(yesToken) || usdcSize == 0) return 0;
        _preCommitForQuoter(yesToken);
        PoolKey memory key = _buildPoolKey(yesToken);
        IV4Quoter.QuoteExactSingleParams memory params = IV4Quoter.QuoteExactSingleParams({
            poolKey: key, zeroForOne: usdc < yesToken, exactAmount: usdcSize, hookData: ""
        });
        (uint256 yesOut,) = quoter.quoteExactInputSingle(params);
        if (yesOut == 0) return 0;
        usdcPerYes = (uint256(usdcSize) * PRICE_PRECISION) / yesOut;
    }

    /// @notice Fee-adjusted AMM effective price when selling `yesSize` YES at the pool.
    /// @dev Symmetric to {_ammEffectivePriceForBuy}. Returns 0 on empty pool / zero size.
    function _ammEffectivePriceForSell(address yesToken, uint128 yesSize) internal returns (uint256 usdcPerYes) {
        if (!_hasPool(yesToken) || yesSize == 0) return 0;
        _preCommitForQuoter(yesToken);
        PoolKey memory key = _buildPoolKey(yesToken);
        IV4Quoter.QuoteExactSingleParams memory params = IV4Quoter.QuoteExactSingleParams({
            poolKey: key, zeroForOne: yesToken < usdc, exactAmount: yesSize, hookData: ""
        });
        (uint256 usdcOut,) = quoter.quoteExactInputSingle(params);
        if (usdcOut == 0) return 0;
        usdcPerYes = (usdcOut * PRICE_PRECISION) / uint256(yesSize);
    }

    /// @notice Fee-adjusted AMM effective cost-per-YES for an exact-out buy of `yesOut` YES.
    /// @dev Used by the SELL_NO cap derivation, where the virtual-NO callback flash-buys
    ///      `noIn` YES exact-out. Returns 0 on empty pool / zero size.
    function _ammEffectivePriceForBuyExactOut(address yesToken, uint128 yesOut) internal returns (uint256 usdcPerYes) {
        if (!_hasPool(yesToken) || yesOut == 0) return 0;
        _preCommitForQuoter(yesToken);
        PoolKey memory key = _buildPoolKey(yesToken);
        IV4Quoter.QuoteExactSingleParams memory params = IV4Quoter.QuoteExactSingleParams({
            poolKey: key, zeroForOne: usdc < yesToken, exactAmount: yesOut, hookData: ""
        });
        (uint256 usdcInQuote,) = quoter.quoteExactOutputSingle(params);
        if (usdcInQuote == 0) return 0;
        usdcPerYes = (usdcInQuote * PRICE_PRECISION) / uint256(yesOut);
    }

    /// @notice CLOB BUY cap for `BUY_YES`, set to the AMM's effective per-YES price at
    ///         `usdcIn` USDC in. Falls back to `PRICE_PRECISION` (permissive) on an empty
    ///         pool or when effective price saturates above $1.00 so the CLOB stays
    ///         routable.
    /// @dev Sizing the cap at the actual trade size — instead of at $1 (spot) — lets the
    ///      orderbook fill at prices between AMM-spot and AMM-effective, which is profit
    ///      strictly preserved for the taker (the AMM would have charged the same or more
    ///      for the same units).
    function _clobBuyYesLimit(address yesToken, uint256 usdcIn) internal returns (uint256) {
        uint256 effective = _ammEffectivePriceForBuy(yesToken, uint128(usdcIn));
        if (effective == 0 || effective >= PRICE_PRECISION) return PRICE_PRECISION;
        return effective;
    }

    /// @notice CLOB SELL min-price for `SELL_YES`, set to the AMM's effective per-YES sell
    ///         price at `yesIn`. Empty pool yields 0 (permissive min).
    function _clobSellYesLimit(address yesToken, uint256 yesIn) internal returns (uint256) {
        return _ammEffectivePriceForSell(yesToken, uint128(yesIn));
    }

    /// @notice CLOB BUY cap for `BUY_NO`. Virtual NO buy price = 1 - YES sell effective at
    ///         the mint-amount the virtual path would flash-sell. A spot probe bootstraps
    ///         the mint estimate linearly; the second quote gets the impact-aware effective
    ///         at that estimate. Returns `PRICE_PRECISION` (permissive) when the pool is
    ///         empty / saturates.
    function _clobBuyNoLimit(address yesToken, uint256 usdcIn) internal returns (uint256) {
        uint256 yesSellSpot = _ammSpotPriceForSell(yesToken);
        if (yesSellSpot == 0 || yesSellSpot >= PRICE_PRECISION) return PRICE_PRECISION;
        uint256 mintEstimate = (usdcIn * PRICE_PRECISION) / (PRICE_PRECISION - yesSellSpot);
        if (mintEstimate == 0) return PRICE_PRECISION;
        uint256 yesSellEffective = _ammEffectivePriceForSell(yesToken, uint128(mintEstimate));
        if (yesSellEffective == 0 || yesSellEffective >= PRICE_PRECISION) return PRICE_PRECISION;
        return PRICE_PRECISION - yesSellEffective;
    }

    /// @notice CLOB SELL min-price for `SELL_NO`. Virtual NO sell price = 1 - YES buy
    ///         effective for an exact-out flash-buy of `noIn` YES.
    function _clobSellNoLimit(address yesToken, uint256 noIn) internal returns (uint256) {
        uint256 yesBuyEffective = _ammEffectivePriceForBuyExactOut(yesToken, uint128(noIn));
        if (yesBuyEffective == 0 || yesBuyEffective >= PRICE_PRECISION) return 0;
        return PRICE_PRECISION - yesBuyEffective;
    }

    /// @notice The four cap-derivation kinds, one per trade side.
    enum CapKind {
        BUY_YES,
        SELL_YES,
        BUY_NO,
        SELL_NO
    }

    /// @notice Re-quote dispatch: AMM effective-price cap for `size` on the given side.
    function _capFor(CapKind kind, address yesToken, uint256 size) internal returns (uint256) {
        if (kind == CapKind.BUY_YES) return _clobBuyYesLimit(yesToken, size);
        if (kind == CapKind.SELL_YES) return _clobSellYesLimit(yesToken, size);
        if (kind == CapKind.BUY_NO) return _clobBuyNoLimit(yesToken, size);
        return _clobSellNoLimit(yesToken, size);
    }

    /// @notice Converge the CLOB cap toward the AMM effective price at the
    ///         remainder the orderbook would actually leave (Level-2 routing).
    /// @dev Seeds the cap at the spot-sized effective (a tiny probe), which is
    ///      the SELECTIVE end for both directions, then expands it round by
    ///      round:
    ///        - BUY: spot is the low end; effective rises with size, so the cap
    ///          walks UP until it stops rising.
    ///        - SELL: spot is the high end; effective falls with size, so the
    ///          cap walks DOWN until it stops falling.
    ///      Each round previews the CLOB fill at the current cap (view, no
    ///      transfers), then re-quotes the AMM effective at the resulting
    ///      remainder. The fixed point is the price where the marginal CLOB
    ///      order equals the AMM effective for the leftover size — the optimal
    ///      CLOB/AMM split boundary. Seeding at the selective end avoids the
    ///      over-consumption that makes a naive descending fixed-point oscillate
    ///      when a single large maker order can absorb the whole budget.
    ///
    ///      Only the cap NUMBER is produced here; the caller's execution path
    ///      (one `fillMarketOrder` + one AMM leg) is unchanged from the single
    ///      cap design, so no new settlement / balance risk is introduced.
    ///      `amountIn` is USDC for buys and shares for sells; `preview`'s
    ///      `cost` is in the same unit, so the remainder math is uniform.
    function _convergeCap(
        uint256 marketId,
        IPrediXExchangeView.Side side,
        CapKind kind,
        address yesToken,
        uint256 amountIn,
        uint256 maxFills
    ) internal returns (uint256 cap) {
        // Level-1 cap: AMM effective at the full trade size. Identical quoter
        // profile to the non-convergence path.
        cap = _capFor(kind, yesToken, amountIn);
        if (!_hasPool(yesToken)) return cap;

        // Gate: a single preview at the Level-1 (most permissive) cap. If the
        // CLOB has NO eligible depth at all, there is no split to optimise — the
        // AMM takes everything and the cap is irrelevant, so return the Level-1
        // cap on the same quoter profile as the non-convergence path. `preview`
        // calls the exchange, not the quoter, so it never perturbs Path-D
        // sequences.
        //
        // Note: a `gateCost == amountIn` (CLOB absorbs the whole budget at the
        // permissive cap) does NOT short-circuit — that is precisely the
        // over-take case convergence must correct, because a tighter cap can
        // route the marginal tail to a cheaper AMM remainder.
        //
        // The preview is wrapped in try/catch so a preview revert degrades to
        // the Level-1 cap rather than failing the trade, preserving the CLOB
        // graceful-fallback contract that `_tryClobBuy` / `_tryClobSell`
        // provide on the execute leg.
        uint256 gateCost;
        try IPrediXExchangeView(exchange)
            .previewFillMarketOrder(marketId, side, cap, amountIn, maxFills, address(this)) returns (
            uint256, uint256 gc
        ) {
            gateCost = gc;
        } catch {
            return cap;
        }
        if (gateCost == 0) return cap;

        // Meaningful split → converge from the spot-sized effective (the
        // selective end) toward the fixed point. BUY walks the cap UP (effective
        // rises with size); SELL walks it DOWN (effective falls with size).
        bool isBuy = (kind == CapKind.BUY_YES || kind == CapKind.BUY_NO);
        uint256 conv = _capFor(kind, yesToken, MIN_TRADE_AMOUNT);
        for (uint256 r; r < CLOB_CAP_CONVERGE_ROUNDS; ++r) {
            uint256 clobCost;
            try IPrediXExchangeView(exchange)
                .previewFillMarketOrder(marketId, side, conv, amountIn, maxFills, address(this)) returns (
                uint256, uint256 cc
            ) {
                clobCost = cc;
            } catch {
                break;
            }
            uint256 remainder = amountIn > clobCost ? amountIn - clobCost : 0;
            if (remainder < MIN_TRADE_AMOUNT) break;
            uint256 newCap = _capFor(kind, yesToken, remainder);
            if (isBuy ? newCap <= conv : newCap >= conv) break;
            conv = newCap;
        }
        cap = conv;
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
                    poolKey: key, zeroForOne: zeroForOne, exactAmount: uint128(size), hookData: ""
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

        // Safety convergence loop. Each iteration quotes at the EXACT amount
        // the callback would swap; if the quoter-confirmed budget covers
        // `candidate` the invariant is satisfied by construction. If not,
        // shrink `candidate` to a cushioned multiple of the strictly feasible
        // budget and re-quote. In well-behaved (concave) pools this exits in
        // iteration 1. In pathologically linear pools the candidate shrinks
        // geometrically toward the cushioned fixed point
        // `cushion · usdcIn / (1 - cushion · spot)` where the invariant
        // holds strictly — without this loop the historical strict-cap
        // branch could revert `QuoteOutsideSafetyMargin` at the callback,
        // re-introducing the bug Path D was designed to close.
        for (uint256 i = 0; i < BUY_NO_SIZING_MAX_ITER; ++i) {
            _preCommitForQuoter(yesToken);
            (uint256 finalProceeds,) = quoter.quoteExactInputSingle(
                IV4Quoter.QuoteExactSingleParams({
                    poolKey: key, zeroForOne: zeroForOne, exactAmount: uint128(candidate), hookData: ""
                })
            );
            if (finalProceeds + usdcIn >= candidate) {
                mintAmount = candidate;
                return mintAmount;
            }
            uint256 newCandidate = ((finalProceeds + usdcIn) * BUY_NO_PRECISION_CUSHION_BPS) / BPS_DENOMINATOR;
            if (newCandidate == 0 || newCandidate >= candidate) {
                // Saturated — no further shrink possible. Return the
                // strictly feasible budget cushioned once for drift; in
                // practice this branch is unreachable because each
                // iteration above strictly shrinks `candidate`.
                mintAmount = newCandidate;
                return mintAmount;
            }
            candidate = newCandidate;
        }
        // Bounded-iteration exit. The cushioned `candidate` from the last
        // shrink step has NOT been re-quoted, but every shrink applies the
        // 0.5% cushion on top of the strictly feasible budget, which is
        // bounded above by the linear-pool fixed point. Returning
        // `candidate` here is the conservative continuation of the loop's
        // contraction.
        mintAmount = candidate;
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
        address noToken,
        bytes32 builder
    ) internal returns (uint256 yesOut, uint256 clobFilled, uint256 ammFilled) {
        uint256 usdcRemaining;
        (clobFilled, usdcRemaining) = _tryClobBuy(
            marketId,
            IPrediXExchangeView.Side.BUY_YES,
            _convergeCap(marketId, IPrediXExchangeView.Side.BUY_YES, CapKind.BUY_YES, yesToken, usdcIn, maxFills),
            usdcIn,
            maxFills,
            deadline,
            builder
        );

        // AMM-leg fees: builder flat-bps on USDC in + protocol curve (reserve at p=0.5, recompute on the
        // realized fill). Over-reserve is refunded by the finalize canary. Launch coef 0 ⇒ protocol fee 0
        // (P10). High-LP-tier all-in ~9.5% at the 500bps tier is a parameterization concern, moot at launch.
        if (usdcRemaining > 0 && _hasPool(yesToken)) {
            ammFilled = _ammBuyYesWithFees(marketId, yesToken, noToken, usdcRemaining, builder);
        }

        yesOut = clobFilled + ammFilled;
        if (yesOut == 0) revert ExactInUnfilled(usdcIn);
        if (yesOut < minYesOut) revert InsufficientOutput(yesOut, minYesOut);

        IERC20(yesToken).safeTransfer(recipient, yesOut);
        _finalizeAndAssertAllZero(yesToken, noToken);

        emit Trade(marketId, msg.sender, recipient, TradeType.BUY_YES, usdcIn, yesOut, clobFilled, ammFilled, builder);
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
        address noToken,
        bytes32 builder
    ) internal returns (uint256 usdcOut, uint256 clobFilled, uint256 ammFilled) {
        _ensureApproval(yesToken, exchange);

        uint256 clobLimit =
            _convergeCap(marketId, IPrediXExchangeView.Side.SELL_YES, CapKind.SELL_YES, yesToken, yesIn, maxFills);
        uint256 usdcBefore = IERC20(usdc).balanceOf(address(this));
        uint256 yesRemaining;
        (, yesRemaining) =
            _tryClobSell(marketId, IPrediXExchangeView.Side.SELL_YES, clobLimit, yesIn, maxFills, deadline, builder);
        clobFilled = IERC20(usdc).balanceOf(address(this)) - usdcBefore;

        // AMM-leg fees carved from the post-swap gross (SELL needs no reserve), gated ammGross>0. The fee-
        // config reads sit INSIDE the pool gate so a CLOB-only sell pays no extra SLOAD (mirrors the BUY paths).
        if (yesRemaining > 0 && _hasPool(yesToken)) {
            (uint16 takerBps,,) =
                builder == bytes32(0) ? (uint16(0), uint16(0), address(0)) : builderRegistry.feeOf(builder);
            uint16 coefBps = IMarketFacet(diamond).getMarket(marketId).protocolFeeRateBps;
            uint256 ammGross = _executeAmmSellYes(marketId, yesToken, noToken, yesRemaining, msg.sender);
            if (ammGross > 0) {
                uint256 builderFee = _feeOn(ammGross, takerBps);
                uint256 protocolFee = _curveFee(yesRemaining, coefBps, (ammGross * PRICE_PRECISION) / yesRemaining);
                ammFilled = ammGross - builderFee - protocolFee;
                if (builderFee > 0) IPrediXExchangeView(exchange).depositBuilderFee(builder, builderFee);
                if (protocolFee > 0) IPrediXExchangeView(exchange).depositProtocolFee(protocolFee);
            }
        }

        usdcOut = clobFilled + ammFilled;
        if (usdcOut == 0) revert ExactInUnfilled(yesIn);
        if (usdcOut < minUsdcOut) revert InsufficientOutput(usdcOut, minUsdcOut);

        IERC20(usdc).safeTransfer(recipient, usdcOut);
        _finalizeAndAssertAllZero(yesToken, noToken);

        emit Trade(marketId, msg.sender, recipient, TradeType.SELL_YES, yesIn, usdcOut, clobFilled, ammFilled, builder);
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
        address noToken,
        bytes32 builder
    ) internal returns (uint256 noOut, uint256 clobFilled, uint256 ammFilled) {
        uint256 usdcRemaining;
        (clobFilled, usdcRemaining) = _tryClobBuy(
            marketId,
            IPrediXExchangeView.Side.BUY_NO,
            _convergeCap(marketId, IPrediXExchangeView.Side.BUY_NO, CapKind.BUY_NO, yesToken, usdcIn, maxFills),
            usdcIn,
            maxFills,
            deadline,
            builder
        );

        if (usdcRemaining > 0 && _hasPool(yesToken)) {
            ammFilled = _ammBuyNoWithFees(marketId, yesToken, noToken, usdcRemaining, builder);
        }

        noOut = clobFilled + ammFilled;
        if (noOut == 0) revert ExactInUnfilled(usdcIn);
        if (noOut < minNoOut) revert InsufficientOutput(noOut, minNoOut);

        IERC20(noToken).safeTransfer(recipient, noOut);
        _finalizeAndAssertAllZero(yesToken, noToken);

        emit Trade(marketId, msg.sender, recipient, TradeType.BUY_NO, usdcIn, noOut, clobFilled, ammFilled, builder);
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
        address noToken,
        bytes32 builder
    ) internal returns (uint256 usdcOut, uint256 clobFilled, uint256 ammFilled) {
        _ensureApproval(noToken, exchange);

        uint256 usdcBefore = IERC20(usdc).balanceOf(address(this));
        uint256 noRemaining;
        (, noRemaining) = _tryClobSell(
            marketId,
            IPrediXExchangeView.Side.SELL_NO,
            _convergeCap(marketId, IPrediXExchangeView.Side.SELL_NO, CapKind.SELL_NO, yesToken, noIn, maxFills),
            noIn,
            maxFills,
            deadline,
            builder
        );
        clobFilled = IERC20(usdc).balanceOf(address(this)) - usdcBefore;

        // AMM-leg fees carved from the post-swap gross (p = USDC-per-NO realized), gated ammGross>0. Fee-config
        // reads sit INSIDE the pool gate so a CLOB-only sell pays no extra SLOAD (mirrors the BUY paths).
        if (noRemaining > 0 && _hasPool(yesToken)) {
            (uint16 takerBps,,) =
                builder == bytes32(0) ? (uint16(0), uint16(0), address(0)) : builderRegistry.feeOf(builder);
            uint16 coefBps = IMarketFacet(diamond).getMarket(marketId).protocolFeeRateBps;
            uint256 ammGross = _executeAmmSellNo(marketId, yesToken, noToken, noRemaining, msg.sender);
            if (ammGross > 0) {
                uint256 builderFee = _feeOn(ammGross, takerBps);
                uint256 protocolFee = _curveFee(noRemaining, coefBps, (ammGross * PRICE_PRECISION) / noRemaining);
                ammFilled = ammGross - builderFee - protocolFee;
                if (builderFee > 0) IPrediXExchangeView(exchange).depositBuilderFee(builder, builderFee);
                if (protocolFee > 0) IPrediXExchangeView(exchange).depositProtocolFee(protocolFee);
            }
        }

        usdcOut = clobFilled + ammFilled;
        if (usdcOut == 0) revert ExactInUnfilled(noIn);
        if (usdcOut < minUsdcOut) revert InsufficientOutput(usdcOut, minUsdcOut);

        IERC20(usdc).safeTransfer(recipient, usdcOut);
        _finalizeAndAssertAllZero(yesToken, noToken);

        emit Trade(marketId, msg.sender, recipient, TradeType.SELL_NO, noIn, usdcOut, clobFilled, ammFilled, builder);
    }

    function _isClobGracefulError(bytes4 sel) private pure returns (bool) {
        return sel == _EX_PAUSED || sel == _EX_MARKET_PAUSED || sel == _EX_MARKET_EXPIRED || sel == _EX_MARKET_RESOLVED
            || sel == _EX_MARKET_REFUND || sel == _EX_DEADLINE || sel == _EX_NO_LIQUIDITY;
    }
}
