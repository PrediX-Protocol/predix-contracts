// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import {DevBase} from "./_DevBase.sol";
import {console2} from "forge-std/Script.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IMarketFacet} from "@predix/shared/interfaces/IMarketFacet.sol";
import {IPrediXExchange} from "@predix/exchange/IPrediXExchange.sol";

/// @notice Variant 3 — CLOB-only market (no AMM pool registered). LP seeds 4 maker
///         orders @ $0.50 with depth 25 USDC each side. Router.buyYes/sellNo will
///         fall back to CLOB-only path (no AMM cap convergence).
contract M3_ClobOnly is DevBase {
    string internal constant QUESTION = "[Test] Will SOL pass $300?";
    uint256 internal constant END_OFFSET = 24 hours;
    uint256 internal constant USDC_SPLIT = 50e6;
    uint256 internal constant ORDER_AMOUNT = 50e6; // depth 25 USDC @ $0.50
    uint256 internal constant PRICE_HALF = 500000;

    function run() external {
        Ctx memory c = _load();

        vm.startBroadcast(c.creatorKey);
        IERC20(c.usdc).approve(c.diamond, type(uint256).max);
        uint256 marketId =
            IMarketFacet(c.diamond).createMarket(QUESTION, block.timestamp + END_OFFSET, c.oracleManual);
        vm.stopBroadcast();

        (address yes, address no,,,) = IMarketFacet(c.diamond).getMarketStatus(marketId);

        vm.startBroadcast(c.lpKey);
        IERC20(c.usdc).approve(c.diamond, type(uint256).max);
        IMarketFacet(c.diamond).splitPosition(marketId, USDC_SPLIT);
        IERC20(yes).approve(c.exchange, type(uint256).max);
        IERC20(no).approve(c.exchange, type(uint256).max);
        IERC20(c.usdc).approve(c.exchange, type(uint256).max);
        IPrediXExchange(c.exchange).placeOrder(marketId, IPrediXExchange.Side.SELL_YES, PRICE_HALF, ORDER_AMOUNT, bytes32(0));
        IPrediXExchange(c.exchange).placeOrder(marketId, IPrediXExchange.Side.SELL_NO, PRICE_HALF, ORDER_AMOUNT, bytes32(0));
        IPrediXExchange(c.exchange).placeOrder(marketId, IPrediXExchange.Side.BUY_YES, PRICE_HALF, ORDER_AMOUNT, bytes32(0));
        IPrediXExchange(c.exchange).placeOrder(marketId, IPrediXExchange.Side.BUY_NO, PRICE_HALF, ORDER_AMOUNT, bytes32(0));
        vm.stopBroadcast();

        console2.log("=== M3 CLOB-only complete ===");
        console2.log("marketId :", marketId);
        console2.log("yesToken :", yes);
        console2.log("noToken  :", no);
        console2.log("endTime  :", block.timestamp + END_OFFSET);
    }
}
