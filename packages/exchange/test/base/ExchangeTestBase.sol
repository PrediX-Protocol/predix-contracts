// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {IPrediXExchange} from "../../src/IPrediXExchange.sol";
import {PrediXExchange} from "../../src/PrediXExchange.sol";

import {MockERC20} from "../mocks/MockERC20.sol";
import {MockDiamond} from "../mocks/MockDiamond.sol";

/// @title ExchangeTestBase
/// @notice Shared fixture for every Exchange unit-test suite. Owns deployment of
///         the mock USDC, the mock diamond, the real `PrediXExchange`, and a single
///         binary market with real OutcomeTokens. Provides token-distribution and
///         orderbook-seeding helpers so individual test files focus on behaviour.
abstract contract ExchangeTestBase is Test {
    MockERC20 internal usdc;
    MockDiamond internal diamond;
    PrediXExchange internal exchange;

    address internal feeRecipient = makeAddr("feeRecipient");
    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");
    address internal carol = makeAddr("carol");
    address internal dave = makeAddr("dave");
    address internal pauser = makeAddr("pauser");

    uint256 internal constant MARKET_ID = 1;
    uint256 internal constant ONE_SHARE = 1e6;
    uint256 internal constant DEFAULT_DEADLINE_OFFSET = 300;

    address internal yesToken;
    address internal noToken;

    function setUp() public virtual {
        usdc = new MockERC20("USD Coin", "USDC", 6);
        diamond = new MockDiamond(address(usdc));
        exchange = new PrediXExchange(address(diamond), address(usdc), feeRecipient);
        (yesToken, noToken) = diamond.createMarket(MARKET_ID, block.timestamp + 7 days, address(this));
    }

    // ============ Token distribution ============

    function _giveUsdc(address to, uint256 amount) internal {
        usdc.mint(to, amount);
        vm.prank(to);
        usdc.approve(address(exchange), type(uint256).max);
    }

    function _giveYesNo(address to, uint256 amount) internal {
        usdc.mint(to, amount);
        vm.startPrank(to);
        usdc.approve(address(diamond), amount);
        diamond.splitPosition(MARKET_ID, amount);
        IERC20(yesToken).approve(address(exchange), type(uint256).max);
        IERC20(noToken).approve(address(exchange), type(uint256).max);
        vm.stopPrank();
    }

    // ============ Orderbook seeding (real placeOrder) ============

    function _placeBuyYes(address owner_, uint256 price, uint256 amount) internal returns (bytes32 orderId) {
        _giveUsdc(owner_, (amount * price) / 1e6);
        vm.prank(owner_);
        (orderId,) = exchange.placeOrder(MARKET_ID, IPrediXExchange.Side.BUY_YES, price, amount);
    }

    function _placeBuyNo(address owner_, uint256 price, uint256 amount) internal returns (bytes32 orderId) {
        _giveUsdc(owner_, (amount * price) / 1e6);
        vm.prank(owner_);
        (orderId,) = exchange.placeOrder(MARKET_ID, IPrediXExchange.Side.BUY_NO, price, amount);
    }

    function _placeSellYes(address owner_, uint256 price, uint256 amount) internal returns (bytes32 orderId) {
        _giveYesNo(owner_, amount);
        vm.prank(owner_);
        (orderId,) = exchange.placeOrder(MARKET_ID, IPrediXExchange.Side.SELL_YES, price, amount);
    }

    function _placeSellNo(address owner_, uint256 price, uint256 amount) internal returns (bytes32 orderId) {
        _giveYesNo(owner_, amount);
        vm.prank(owner_);
        (orderId,) = exchange.placeOrder(MARKET_ID, IPrediXExchange.Side.SELL_NO, price, amount);
    }

    // ============ Convenience accessors ============

    function _deadline() internal view returns (uint256) {
        return block.timestamp + DEFAULT_DEADLINE_OFFSET;
    }

    function _yesBalance(address who) internal view returns (uint256) {
        return IERC20(yesToken).balanceOf(who);
    }

    function _noBalance(address who) internal view returns (uint256) {
        return IERC20(noToken).balanceOf(who);
    }

    function _usdcBalance(address who) internal view returns (uint256) {
        return usdc.balanceOf(who);
    }
}
