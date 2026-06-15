// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import {AuditBase} from "./_AuditBase.sol";
import {console2} from "forge-std/Script.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IMarketFacet} from "@predix/shared/interfaces/IMarketFacet.sol";
import {IPrediXExchange} from "@predix/exchange/IPrediXExchange.sol";
import {IPrediXRouter} from "@predix/router/interfaces/IPrediXRouter.sol";

/// @notice Scenario 1 setup — validates P1-E (NO-side trade coverage).
///         Creates fresh market endTime = now + 8 min. LP seeds 4 CLOB orders
///         (SELL_YES/SELL_NO/BUY_YES/BUY_NO @ $0.50). Trader A executes
///         Router.buyYes 25 USDC + buyNo 25 USDC. Trader B splits 25 USDC
///         then Router.sellNo 25 NO.
///
///         marketId is emitted via console2.log — capture for resolve step.
contract Scenario1_Setup is AuditBase {
    uint256 internal constant USDC_SPLIT = 50e6;
    uint256 internal constant ORDER_AMOUNT = 25e6; // SELL_*: 12.5 USDC cap, BUY_*: 12.5 USDC locked
    uint256 internal constant PRICE_HALF = 500000; // $0.50 in 6-dec
    // Taker input MUST be ≤ complementary capacity (12.5 USDC) so Router's
    // remainder doesn't trigger Synthetic MINT/MERGE which would also consume
    // opposite-direction maker orders (the BUY_NO that B needs to sell into).
    // Task spec says "~10 USDC per trade" anyway.
    uint256 internal constant TRADER_USDC = 10e6;
    uint256 internal constant END_OFFSET = 8 minutes;

    function run() external {
        Ctx memory c = _load();
        address a = vm.addr(c.aKey);
        address b = vm.addr(c.bKey);

        // 1. Creator creates market
        vm.startBroadcast(c.creatorKey);
        IERC20(c.usdc).approve(c.diamond, type(uint256).max);
        uint256 marketId = IMarketFacet(c.diamond)
            .createMarket("Indexer audit S1 (NO-side)", block.timestamp + END_OFFSET, c.oracleManual);
        vm.stopBroadcast();

        (address yes, address no,,,) = IMarketFacet(c.diamond).getMarketStatus(marketId);

        // 2. LP seeds CLOB
        vm.startBroadcast(c.lpKey);
        IERC20(c.usdc).approve(c.diamond, type(uint256).max);
        IMarketFacet(c.diamond).splitPosition(marketId, USDC_SPLIT);
        IERC20(yes).approve(c.exchange, type(uint256).max);
        IERC20(no).approve(c.exchange, type(uint256).max);
        IERC20(c.usdc).approve(c.exchange, type(uint256).max);
        IPrediXExchange(c.exchange)
            .placeOrder(marketId, IPrediXExchange.Side.SELL_YES, PRICE_HALF, ORDER_AMOUNT, bytes32(0));
        IPrediXExchange(c.exchange)
            .placeOrder(marketId, IPrediXExchange.Side.SELL_NO, PRICE_HALF, ORDER_AMOUNT, bytes32(0));
        IPrediXExchange(c.exchange)
            .placeOrder(marketId, IPrediXExchange.Side.BUY_YES, PRICE_HALF, ORDER_AMOUNT, bytes32(0));
        IPrediXExchange(c.exchange)
            .placeOrder(marketId, IPrediXExchange.Side.BUY_NO, PRICE_HALF, ORDER_AMOUNT, bytes32(0));
        vm.stopBroadcast();

        // 3. Trader A: Router.buyYes + Router.buyNo (the critical NO-side trade)
        vm.startBroadcast(c.aKey);
        IERC20(c.usdc).approve(c.router, type(uint256).max);
        IPrediXRouter(c.router).buyYes(marketId, TRADER_USDC, 1, a, 5, block.timestamp + 5 minutes, bytes32(0));
        IPrediXRouter(c.router).buyNo(marketId, TRADER_USDC, 1, a, 5, block.timestamp + 5 minutes, bytes32(0));
        vm.stopBroadcast();

        // 4. Trader B: split to get NO, then Router.sellNo
        vm.startBroadcast(c.bKey);
        IERC20(c.usdc).approve(c.diamond, type(uint256).max);
        IMarketFacet(c.diamond).splitPosition(marketId, TRADER_USDC);
        IERC20(no).approve(c.router, type(uint256).max);
        IPrediXRouter(c.router).sellNo(marketId, TRADER_USDC, 1, b, 5, block.timestamp + 5 minutes, bytes32(0));
        vm.stopBroadcast();

        console2.log("=== Scenario 1 setup complete ===");
        console2.log("S1_MARKET_ID =", marketId);
        console2.log("yesToken    =", yes);
        console2.log("noToken     =", no);
        console2.log("traderA     =", a);
        console2.log("traderB     =", b);
        console2.log("endTime     =", block.timestamp + END_OFFSET);
        console2.log("Wait", END_OFFSET, "sec then run Scenario1_Resolve");
    }
}
