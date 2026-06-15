// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import {AuditBase} from "./_AuditBase.sol";
import {console2} from "forge-std/Script.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IMarketFacet} from "@predix/shared/interfaces/IMarketFacet.sol";
import {IPrediXExchange} from "@predix/exchange/IPrediXExchange.sol";
import {IPrediXRouter} from "@predix/router/interfaces/IPrediXRouter.sol";

/// @notice Scenario 8 — mixed user M does Router.buyYes AND Exchange direct.
///         New market endTime = now + 5 min. LP seeds 4 orders @ $0.50
///         depth 20 USDC each. M (HD-17) does:
///           1. Router.buyYes(5 USDC) → ~10 YES (Router path: writes Trade
///              event with trader=M, recipient=M)
///           2. Exchange.fillMarketOrder(BUY_YES, limit=$0.60, 5 USDC, taker=M)
///              → ~10 YES (direct path: writes Maker fills only, takerOrderId=0
///              ⇒ Gap 1 — no position update for M from this leg)
///         M ends with ~20 YES. After resolve+redeem in Scenario8_ResolveRedeem,
///         the indexer's position.totalSpent should reflect only the 5 USDC
///         Router leg, missing the 5 USDC direct-Exchange leg ⇒ overstated
///         PnL on redeem.
contract Scenario8_Setup is AuditBase {
    uint256 internal constant USDC_SPLIT_LP = 80e6;
    uint256 internal constant ORDER_AMOUNT = 40e6; // 20 USDC depth @ $0.50
    uint256 internal constant PRICE_HALF = 500000;
    uint256 internal constant M_TRADE = 5e6;
    uint256 internal constant DIRECT_LIMIT_PRICE = 600000; // $0.60
    uint256 internal constant END_OFFSET = 5 minutes;

    function run() external {
        Ctx memory c = _load();
        string memory mnemonic = vm.envString("MNEMONIC");
        uint256 mKey = vm.deriveKey(mnemonic, 17);
        address m = vm.addr(mKey);

        vm.startBroadcast(c.creatorKey);
        uint256 marketId = IMarketFacet(c.diamond)
            .createMarket("Indexer audit S8 (mixed Router+Exchange)", block.timestamp + END_OFFSET, c.oracleManual);
        vm.stopBroadcast();

        (address yes, address no,,,) = IMarketFacet(c.diamond).getMarketStatus(marketId);

        vm.startBroadcast(c.lpKey);
        IERC20(c.usdc).approve(c.diamond, type(uint256).max);
        IMarketFacet(c.diamond).splitPosition(marketId, USDC_SPLIT_LP);
        IERC20(yes).approve(c.exchange, type(uint256).max);
        IERC20(no).approve(c.exchange, type(uint256).max);
        IPrediXExchange(c.exchange)
            .placeOrder(marketId, IPrediXExchange.Side.SELL_YES, PRICE_HALF, ORDER_AMOUNT, bytes32(0));
        IPrediXExchange(c.exchange)
            .placeOrder(marketId, IPrediXExchange.Side.SELL_NO, PRICE_HALF, ORDER_AMOUNT, bytes32(0));
        IPrediXExchange(c.exchange)
            .placeOrder(marketId, IPrediXExchange.Side.BUY_YES, PRICE_HALF, ORDER_AMOUNT, bytes32(0));
        IPrediXExchange(c.exchange)
            .placeOrder(marketId, IPrediXExchange.Side.BUY_NO, PRICE_HALF, ORDER_AMOUNT, bytes32(0));
        vm.stopBroadcast();

        uint256 deadline = block.timestamp + 5 minutes;

        vm.startBroadcast(mKey);
        // Leg 1: Router (writes Trade event with recipient=M)
        IERC20(c.usdc).approve(c.router, type(uint256).max);
        IPrediXRouter(c.router).buyYes(marketId, M_TRADE, 1, m, 5, deadline, bytes32(0));
        // Leg 2: direct Exchange (no Trade event, only maker fills observed)
        IERC20(c.usdc).approve(c.exchange, type(uint256).max);
        IPrediXExchange(c.exchange)
            .fillMarketOrder(
                marketId, IPrediXExchange.Side.BUY_YES, DIRECT_LIMIT_PRICE, M_TRADE, m, m, 5, deadline, bytes32(0)
            );
        vm.stopBroadcast();

        console2.log("=== Scenario 8 setup complete ===");
        console2.log("S8_MARKET_ID =", marketId);
        console2.log("M (HD-17)    =", m);
        console2.log("yesToken     =", yes);
        console2.log("endTime      =", block.timestamp + END_OFFSET);
    }
}
