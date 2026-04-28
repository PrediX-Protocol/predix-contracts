// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

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
    error Exchange_AlreadyInitialized();

    event Paused(address indexed account);
    event Unpaused(address indexed account);
    event Initialized(address indexed diamond, address indexed usdc, address indexed feeRecipient);
    event FeeRecipientUpdated(address indexed previous, address indexed current);

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

    // ======== Constructor ========

    /// @dev No-op. State initialization happens in `initialize()`, called
    ///      atomically by the proxy constructor. Calling `initialize()` on
    ///      the bare impl is harmless: the impl has no proxy-storage state,
    ///      so any "admin" rights set there have no protocol effect.
    constructor() {}

    // ======== Initializer (called atomically by proxy constructor) ========

    /// @notice One-shot bootstrap. Binds the exchange to its diamond, USDC,
    ///         and initial fee recipient. MUST be called exactly once via the
    ///         proxy constructor's delegatecall.
    /// @dev Pre-approves diamond for max USDC (synthetic MINT path needs
    ///      diamond to pull USDC for `splitPosition`).
    function initialize(address _diamond, address _usdc, address _feeRecipient) external {
        if (_initialized) revert Exchange_AlreadyInitialized();
        if (_diamond == address(0) || _usdc == address(0) || _feeRecipient == address(0)) {
            revert ZeroAddress();
        }
        diamond = _diamond;
        usdc = _usdc;
        feeRecipient = _feeRecipient;
        _initialized = true;

        IERC20(_usdc).forceApprove(_diamond, type(uint256).max);
        emit Initialized(_diamond, _usdc, _feeRecipient);
    }

    // ======== Admin: fee recipient rotation ========

    /// @notice Update the fee recipient address. Gated by diamond's ADMIN_ROLE.
    ///         Enables migration to a FeeController contract without redeploying.
    function setFeeRecipient(address _feeRecipient) external onlyPauser {
        if (_feeRecipient == address(0)) revert ZeroAddress();
        address previous = feeRecipient;
        feeRecipient = _feeRecipient;
        emit FeeRecipientUpdated(previous, _feeRecipient);
    }

    // ======== Maker path (gated by Exchange pause) ========

    /// @inheritdoc IPrediXExchange
    function placeOrder(uint256 marketId, Side side, uint256 price, uint256 amount)
        external
        override
        nonReentrant
        whenNotPaused
        returns (bytes32 orderId, uint256 filledAmount)
    {
        return _placeOrder(marketId, side, price, amount);
    }

    /// @inheritdoc IPrediXExchange
    /// @dev Cancel is NOT gated by `whenNotPaused` — users must always be able to
    ///      withdraw locked deposits, even when the maker path is paused.
    function cancelOrder(bytes32 orderId) external override nonReentrant {
        _cancelOrder(orderId);
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
        uint256 deadline
    ) external override nonReentrant returns (uint256 filled, uint256 cost) {
        return _fillMarketOrder(marketId, takerSide, limitPrice, amountIn, taker, recipient, maxFills, deadline);
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
