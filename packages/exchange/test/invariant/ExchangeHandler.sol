// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {IPrediXExchange} from "../../src/IPrediXExchange.sol";
import {PrediXExchange} from "../../src/PrediXExchange.sol";

import {MockERC20} from "../mocks/MockERC20.sol";
import {MockDiamond} from "../mocks/MockDiamond.sol";

/// @title ExchangeHandler
/// @notice Invariant-test handler that drives randomized maker / taker activity
///         against a single Exchange instance. Tracks every placed orderId so
///         the invariant suite can sum `depositLocked` across the universe of
///         orders to prove solvency.
contract ExchangeHandler is Test {
    PrediXExchange public immutable exchange;
    MockERC20 public immutable usdc;
    MockDiamond public immutable diamond;
    uint256 public immutable marketId;
    address public immutable yesToken;
    address public immutable noToken;

    address[5] public actors;
    bytes32[] public orderIds;

    constructor(
        PrediXExchange exchange_,
        MockERC20 usdc_,
        MockDiamond diamond_,
        uint256 marketId_,
        address yesToken_,
        address noToken_
    ) {
        exchange = exchange_;
        usdc = usdc_;
        diamond = diamond_;
        marketId = marketId_;
        yesToken = yesToken_;
        noToken = noToken_;

        actors[0] = makeAddr("h_alice");
        actors[1] = makeAddr("h_bob");
        actors[2] = makeAddr("h_carol");
        actors[3] = makeAddr("h_dave");
        actors[4] = makeAddr("h_eve");

        for (uint256 i; i < actors.length; ++i) {
            usdc.mint(actors[i], 1_000_000e6);
            vm.startPrank(actors[i]);
            usdc.approve(address(exchange), type(uint256).max);
            usdc.approve(address(diamond), type(uint256).max);
            vm.stopPrank();
        }
    }

    function _actor(uint256 seed) internal view returns (address) {
        return actors[seed % actors.length];
    }

    function _clamp(uint256 x, uint256 lo, uint256 hi) internal pure returns (uint256) {
        if (hi <= lo) return lo;
        return lo + (x % (hi - lo + 1));
    }

    function placeBuy(uint256 actorSeed, uint256 priceSeed, uint256 amountSeed, bool yes) external {
        address a = _actor(actorSeed);
        uint256 price = _clamp(priceSeed, 1, 98) * 10_000;
        uint256 amount = _clamp(amountSeed, 1e6, 100e6);

        uint256 deposit = (amount * price) / 1e6;
        usdc.mint(a, deposit);

        vm.prank(a);
        try exchange.placeOrder(
            marketId, yes ? IPrediXExchange.Side.BUY_YES : IPrediXExchange.Side.BUY_NO, price, amount
        ) returns (
            bytes32 id, uint256
        ) {
            orderIds.push(id);
        } catch {}
    }

    function placeSell(uint256 actorSeed, uint256 priceSeed, uint256 amountSeed, bool yes) external {
        address a = _actor(actorSeed);
        uint256 price = _clamp(priceSeed, 1, 98) * 10_000;
        uint256 amount = _clamp(amountSeed, 1e6, 100e6);

        // Mint tokens via diamond.split (actor needs USDC for that).
        usdc.mint(a, amount);
        vm.startPrank(a);
        diamond.splitPosition(marketId, amount);
        IERC20(yesToken).approve(address(exchange), type(uint256).max);
        IERC20(noToken).approve(address(exchange), type(uint256).max);
        vm.stopPrank();

        vm.prank(a);
        try exchange.placeOrder(
            marketId, yes ? IPrediXExchange.Side.SELL_YES : IPrediXExchange.Side.SELL_NO, price, amount
        ) returns (
            bytes32 id, uint256
        ) {
            orderIds.push(id);
        } catch {}
    }

    function cancel(uint256 idxSeed) external {
        if (orderIds.length == 0) return;
        bytes32 id = orderIds[idxSeed % orderIds.length];
        IPrediXExchange.Order memory ord = exchange.getOrder(id);
        if (ord.owner == address(0) || ord.cancelled || ord.filled >= ord.amount) return;

        vm.prank(ord.owner);
        try exchange.cancelOrder(id) {} catch {}
    }

    function fill(uint256 actorSeed, uint256 sideSeed, uint256 amountSeed, uint256 limitSeed) external {
        address a = _actor(actorSeed);
        IPrediXExchange.Side side = IPrediXExchange.Side(sideSeed % 4);
        uint256 amountIn = _clamp(amountSeed, 1e6, 1_000e6);
        uint256 limit = _clamp(limitSeed, 1, 98) * 10_000;

        // Top up the input token.
        if (side == IPrediXExchange.Side.BUY_YES || side == IPrediXExchange.Side.BUY_NO) {
            usdc.mint(a, amountIn);
        } else {
            usdc.mint(a, amountIn);
            vm.startPrank(a);
            diamond.splitPosition(marketId, amountIn);
            IERC20(yesToken).approve(address(exchange), type(uint256).max);
            IERC20(noToken).approve(address(exchange), type(uint256).max);
            vm.stopPrank();
        }

        vm.prank(a);
        try exchange.fillMarketOrder(marketId, side, limit, amountIn, a, a, 0, block.timestamp + 60) {} catch {}
    }

    function orderCount() external view returns (uint256) {
        return orderIds.length;
    }

    function orderAt(uint256 i) external view returns (bytes32) {
        return orderIds[i];
    }
}
