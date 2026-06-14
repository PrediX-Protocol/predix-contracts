// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {IAccessControlFacet} from "@predix/shared/interfaces/IAccessControlFacet.sol";
import {Roles} from "@predix/shared/constants/Roles.sol";
import {TransientReentrancyGuard} from "@predix/shared/utils/TransientReentrancyGuard.sol";

import {IPrediXExchange} from "./IPrediXExchange.sol";
import {ExchangeStorage} from "./ExchangeStorage.sol";
import {MakerPath} from "./mixins/MakerPath.sol";
import {TakerPath} from "./mixins/TakerPath.sol";
import {Views} from "./mixins/Views.sol";
import {IBuilderRegistry} from "@predix/shared/interfaces/IBuilderRegistry.sol";
import {LibBuilderFeeStorage} from "./libraries/LibBuilderFeeStorage.sol";
import {LibProtocolFeeStorage} from "./libraries/LibProtocolFeeStorage.sol";

/// @title PrediXExchange
/// @notice On-chain CLOB with 4-way waterfall matching for PrediX binary prediction markets.
/// @dev Composed contract: external API + reentrancy guard + Exchange-level pause for the
///      maker path. The taker path is permissionless and stays callable while paused so
///      users can always exit a position.
///
///      DEPLOYMENT MODEL: this contract is the LOGIC CONTRACT behind
///      `PrediXExchangeProxy`. It uses the initializer pattern — the constructor
///      only sets `_initialized = true` as defense-in-depth (prevents direct
///      init on the bare impl). State lives in the proxy's storage context.
///
///      Pause authorisation is delegated to the diamond's `Roles.PAUSER_ROLE`, queried
///      via `IAccessControlFacet`. Exchange holds no separate admin key.
contract PrediXExchange is IPrediXExchange, MakerPath, TakerPath, Views, TransientReentrancyGuard {
    using SafeERC20 for IERC20;

    // ======== Exchange-level pause (maker path only) ========

    bool public paused;

    error ExchangePaused();
    error OnlyPauser();
    error OnlyAdmin();
    error Exchange_AlreadyInitialized();
    error Exchange_CannotRevokeCurrentDiamond();

    event Paused(address indexed account);
    event Unpaused(address indexed account);
    event Initialized(address indexed diamond, address indexed usdc, address indexed feeRecipient);
    event FeeRecipientUpdated(address indexed previous, address indexed current);
    event OldDiamondAllowanceRevoked(address indexed oldDiamond);

    modifier whenNotPaused() {
        if (paused) revert ExchangePaused();
        _;
    }

    modifier onlyPauser() {
        if (!IAccessControlFacet(diamond).hasRole(Roles.PAUSER_ROLE, msg.sender)) {
            revert OnlyPauser();
        }
        _;
    }

    modifier onlyAdmin() {
        if (!IAccessControlFacet(diamond).hasRole(Roles.ADMIN_ROLE, msg.sender)) {
            revert OnlyAdmin();
        }
        _;
    }

    // ======== Constructor ========

    /// @dev Disable initialization on the bare implementation contract.
    constructor() {
        _initialized = true;
    }

    // ======== Initializer (called atomically by proxy constructor) ========

    /// @notice One-shot bootstrap. Binds the exchange to its diamond, USDC,
    ///         and initial fee recipient. MUST be called exactly once via the
    ///         proxy constructor's delegatecall.
    /// @dev No standing diamond allowance is granted. The synthetic MINT path
    ///      approves the diamond an exact, single-use amount immediately before
    ///      each `splitPosition` (see `_approveSplit`); the split consumes it
    ///      back to zero, so an idle exchange balance is never exposed to the
    ///      diamond's `transferFrom` right.
    function initialize(address _diamond, address _usdc, address _feeRecipient) external {
        if (_initialized) revert Exchange_AlreadyInitialized();
        if (_diamond == address(0) || _usdc == address(0) || _feeRecipient == address(0)) {
            revert ZeroAddress();
        }
        diamond = _diamond;
        usdc = _usdc;
        feeRecipient = _feeRecipient;
        _initialized = true;

        emit Initialized(_diamond, _usdc, _feeRecipient);
    }

    // ======== Admin: fee recipient rotation ========

    /// @notice Update the fee recipient address. Gated by diamond's ADMIN_ROLE.
    ///         Enables migration to a FeeController contract without redeploying.
    function setFeeRecipient(address _feeRecipient) external onlyAdmin {
        if (_feeRecipient == address(0)) revert ZeroAddress();
        address previous = feeRecipient;
        feeRecipient = _feeRecipient;
        emit FeeRecipientUpdated(previous, _feeRecipient);
    }

    // ======== Admin: builder registry + protocol-fee recipient ========

    function setBuilderRegistry(address registry) external onlyAdmin {
        if (registry == address(0)) revert ZeroAddress();
        address prev = LibBuilderFeeStorage.layout().builderRegistry;
        LibBuilderFeeStorage.layout().builderRegistry = registry;
        emit BuilderRegistrySet(prev, registry);
    }

    function setProtocolFeeRecipient(address recipient) external onlyAdmin {
        if (recipient == address(0)) revert ZeroAddress();
        address prev = LibProtocolFeeStorage.layout().protocolFeeRecipient;
        LibProtocolFeeStorage.layout().protocolFeeRecipient = recipient;
        emit ProtocolFeeRecipientSet(prev, recipient);
    }

    // ======== Builder fee: claim + deposit + view ========

    /// @notice Claim accrued builder fee out to the registry-defined recipient. Permissionless.
    function claimBuilderFee(bytes32 code) external nonReentrant returns (uint256 amount) {
        LibBuilderFeeStorage.Layout storage l = LibBuilderFeeStorage.layout();
        if (l.builderRegistry == address(0)) revert Exchange_RegistryNotSet();
        amount = l.accrued[code];
        if (amount == 0) revert Exchange_NothingToClaim();
        address recipient = IBuilderRegistry(l.builderRegistry).recipientOf(code);
        if (recipient == address(0)) revert ZeroAddress();
        l.accrued[code] = 0; // CEI
        IERC20(usdc).safeTransfer(recipient, amount);
        emit BuilderFeeClaimed(code, recipient, amount);
    }

    /// @notice Donate / forward USDC into a builder's accrual ledger. code==0 MUST early-return
    ///         BEFORE the pull (else untracked unclaimable USDC; breaks I3).
    function depositBuilderFee(bytes32 code, uint256 amount) external {
        if (code == bytes32(0)) return;
        if (amount == 0) return;
        IERC20(usdc).safeTransferFrom(msg.sender, address(this), amount);
        _accrueBuilderFee(code, amount);
    }

    function accruedBuilderFee(bytes32 code) external view returns (uint256) {
        return LibBuilderFeeStorage.layout().accrued[code];
    }

    // ======== Protocol fee: deposit + sweep + view ========

    /// @notice Forward an AMM-leg treasury cut into the protocol-fee accrual. amount==0 early-return.
    function depositProtocolFee(uint256 amount) external {
        if (amount == 0) return;
        IERC20(usdc).safeTransferFrom(msg.sender, address(this), amount);
        _accrueProtocol(amount);
    }

    /// @notice Sweep the accrued treasury cut to the protocol-fee recipient. Permissionless, CEI.
    function sweepProtocolFee() external nonReentrant returns (uint256 amount) {
        LibProtocolFeeStorage.Layout storage l = LibProtocolFeeStorage.layout();
        address recipient = l.protocolFeeRecipient;
        if (recipient == address(0)) revert Exchange_ProtocolRecipientNotSet();
        amount = l.accruedProtocolFee;
        if (amount == 0) return 0;
        l.accruedProtocolFee = 0; // CEI: zero BEFORE transfer
        IERC20(usdc).safeTransfer(recipient, amount);
        emit ProtocolFeeSwept(recipient, amount);
    }

    function accruedProtocolFee() external view returns (uint256) {
        return LibProtocolFeeStorage.layout().accruedProtocolFee;
    }

    // ======== Admin: stale allowance cleanup ========

    /// @notice Zero any USDC allowance still held by a diamond that is no longer
    ///         the live binding. Gated by the CURRENT diamond's ADMIN_ROLE.
    /// @dev The synthetic MINT path grants only an exact, single-use allowance
    ///      per `splitPosition` (consumed back to zero by the split), so no
    ///      standing allowance is expected under normal operation. This remains
    ///      a defensive cleanup: if an impl upgrade rebinds the exchange to a new
    ///      diamond, or any residual is ever left behind, this zeroes the stale
    ///      grant. Idempotent on already-zero allowances. Reverts when targeting
    ///      the live diamond.
    function revokeOldDiamondAllowance(address oldDiamond) external onlyAdmin {
        if (oldDiamond == address(0)) revert ZeroAddress();
        if (oldDiamond == diamond) revert Exchange_CannotRevokeCurrentDiamond();
        IERC20(usdc).forceApprove(oldDiamond, 0);
        emit OldDiamondAllowanceRevoked(oldDiamond);
    }

    // ======== Maker path (gated by Exchange pause) ========

    /// @inheritdoc IPrediXExchange
    function placeOrder(uint256 marketId, Side side, uint256 price, uint256 amount, bytes32 builder)
        external
        override
        nonReentrant
        whenNotPaused
        returns (bytes32 orderId, uint256 filledAmount)
    {
        return _placeOrder(marketId, side, price, amount, builder);
    }

    /// @inheritdoc IPrediXExchange
    /// @dev Cancel is NOT gated by `whenNotPaused` — users must always be able to
    ///      withdraw locked deposits, even when the maker path is paused.
    function cancelOrder(bytes32 orderId) external override nonReentrant {
        _cancelOrder(orderId);
    }

    /// @inheritdoc IPrediXExchange
    /// @dev Bypass pause (user exit guarantee). Partial success — skips orders that
    ///      are already cancelled, fully filled, or that the caller may not cancel
    ///      (not the owner, and the market is not terminal). On terminal markets a
    ///      keeper may batch-cancel others' orders; `_cancelOrder` refunds the locked
    ///      deposit to the order owner, never to the caller.
    function cancelOrders(bytes32[] calldata orderIds) external override nonReentrant returns (uint256 cancelledCount) {
        uint256 len = orderIds.length;
        if (len == 0) revert Exchange_EmptyArray();
        if (len > MAX_BATCH_CANCEL) revert Exchange_BatchTooLarge();

        for (uint256 i; i < len;) {
            if (_tryCancel(orderIds[i])) {
                unchecked {
                    ++cancelledCount;
                }
            }
            unchecked {
                ++i;
            }
        }
    }

    /// @dev Attempt to cancel a single order. Returns false (no revert) if the
    ///      order is invalid, already terminal, or the caller is neither the owner
    ///      nor a keeper acting on a terminal market. Mirrors `cancelOrder`'s
    ///      authorization so a keeper can batch-return resting escrow once a market
    ///      closes; `_cancelOrder` always refunds to `order.owner`, so a keeper
    ///      cannot divert funds.
    function _tryCancel(bytes32 orderId) internal returns (bool) {
        Order storage order = orders[orderId];
        if (order.owner == address(0)) return false;
        if (order.cancelled) return false;
        if (order.filled >= order.amount) return false;
        if (order.owner != msg.sender && !_isMarketTerminal(order.marketId)) return false;

        _cancelOrder(orderId);
        return true;
    }

    // ======== Taker path (permissionless) ========

    /// @inheritdoc IPrediXExchange
    /// @dev Permissionless: no `whenNotPaused`, no role check. Self-defending via
    ///      `_validateMarketActive` + `nonReentrant` + upfront-pull/exact-refund.
    function fillMarketOrder(
        uint256 marketId,
        Side takerSide,
        uint256 limitPrice,
        uint256 amountIn,
        address taker,
        address recipient,
        uint256 maxFills,
        uint256 deadline,
        bytes32 takerBuilder
    ) external override nonReentrant returns (uint256 filled, uint256 cost) {
        return _fillMarketOrder(
            marketId, takerSide, limitPrice, amountIn, taker, recipient, maxFills, deadline, takerBuilder
        );
    }

    // ======== Views (E2c stubs delegate to mixin) ========

    /// @inheritdoc IPrediXExchange
    function previewFillMarketOrder(
        uint256 marketId,
        Side takerSide,
        uint256 limitPrice,
        uint256 amountIn,
        uint256 maxFills,
        address taker
    ) external view override returns (uint256 filled, uint256 cost) {
        return _previewFillMarketOrder(marketId, takerSide, limitPrice, amountIn, maxFills, taker);
    }

    /// @inheritdoc IPrediXExchange
    function previewProtocolFee(
        uint256 marketId,
        Side takerSide,
        uint256 limitPrice,
        uint256 amountIn,
        uint256 maxFills,
        address taker
    ) external view override returns (uint256 protocolFee) {
        return _previewProtocolFee(marketId, takerSide, limitPrice, amountIn, maxFills, taker);
    }

    /// @inheritdoc IPrediXExchange
    function getBestPrices(uint256 marketId)
        external
        view
        override
        returns (uint256 bestBidYes, uint256 bestAskYes, uint256 bestBidNo, uint256 bestAskNo)
    {
        return _getBestPrices(marketId);
    }

    /// @inheritdoc IPrediXExchange
    function getDepthAtPrice(uint256 marketId, Side side, uint256 price)
        external
        view
        override
        returns (uint256 totalAmount)
    {
        return _getDepthAtPrice(marketId, side, price);
    }

    /// @inheritdoc IPrediXExchange
    function getOrderBook(uint256 marketId, uint8 depth)
        external
        view
        override
        returns (
            PriceLevel[] memory yesBids,
            PriceLevel[] memory yesAsks,
            PriceLevel[] memory noBids,
            PriceLevel[] memory noAsks
        )
    {
        return _getOrderBook(marketId, depth);
    }

    /// @inheritdoc IPrediXExchange
    function getOrder(bytes32 orderId) external view override returns (Order memory) {
        return orders[orderId];
    }

    // ======== Pause control (gated by diamond's PAUSER_ROLE) ========

    function pause() external onlyPauser {
        paused = true;
        emit Paused(msg.sender);
    }

    function unpause() external onlyPauser {
        paused = false;
        emit Unpaused(msg.sender);
    }
}
