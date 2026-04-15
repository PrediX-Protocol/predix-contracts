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
///      Pause authorisation is delegated to the diamond's `Roles.PAUSER_ROLE`, queried
///      via `IAccessControlFacet`. Exchange holds no separate admin key.
contract PrediXExchange is IPrediXExchange, MakerPath, TakerPath, Views, TransientReentrancyGuard {
    using SafeERC20 for IERC20;

    // ======== Exchange-level pause (maker path only) ========

    bool public paused;

    error ExchangePaused();
    error OnlyPauser();

    event Paused(address indexed account);
    event Unpaused(address indexed account);

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

    constructor(address _diamond, address _usdc, address _feeRecipient)
        ExchangeStorage(_diamond, _usdc, _feeRecipient)
    {
        if (_diamond == address(0) || _usdc == address(0) || _feeRecipient == address(0)) {
            revert ZeroAddress();
        }
        // Pre-approve diamond to pull USDC during `splitPosition` (synthetic MINT path).
        // No approval needed for outcome tokens — `OutcomeToken.burn` is `onlyFactory`
        // and the diamond burns directly without pulling.
        IERC20(_usdc).forceApprove(_diamond, type(uint256).max);
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
        uint256 maxFills
    ) external view override returns (uint256 filled, uint256 cost) {
        return _previewFillMarketOrder(marketId, takerSide, limitPrice, amountIn, maxFills);
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
