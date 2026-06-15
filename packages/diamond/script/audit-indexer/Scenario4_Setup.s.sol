// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import {AuditBase} from "./_AuditBase.sol";
import {console2} from "forge-std/Script.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IMarketFacet} from "@predix/shared/interfaces/IMarketFacet.sol";
import {IEventFacet} from "@predix/shared/interfaces/IEventFacet.sol";
import {IPrediXExchange} from "@predix/exchange/IPrediXExchange.sol";
import {IPrediXRouter} from "@predix/router/interfaces/IPrediXRouter.sol";

/// @notice Scenario 4 setup — event lifecycle (validates R3-A + R3-B + P1-G).
///         Creator creates event with 3 children, endTime = now + 10 min.
///         LP seeds each child's CLOB (4 orders per child = 12 maker orders).
///         Traders execute 1+ trade per child (mix sides):
///           Child 0: A.Router.buyYes 10 USDC
///           Child 1: B.Router.buyNo 10 USDC
///           Child 2: A.splitPosition 10 + A.Router.sellNo 10
///         After this script: WAIT for endTime + 5 min hold (~15 min total)
///         for indexer to expose markets in /api/markets?status=ended-unresolved.
///         Then run Scenario4_Resolve.
contract Scenario4_Setup is AuditBase {
    uint256 internal constant USDC_SPLIT_LP = 50e6;
    uint256 internal constant ORDER_AMOUNT = 25e6;
    uint256 internal constant PRICE_HALF = 500000;
    uint256 internal constant TRADER_USDC = 10e6;
    uint256 internal constant END_OFFSET = 10 minutes;

    function run() external {
        Ctx memory c = _load();
        address a = vm.addr(c.aKey);
        address b = vm.addr(c.bKey);

        // Creator creates event with 3 candidates
        string[] memory candidates = new string[](3);
        candidates[0] = "Outcome A";
        candidates[1] = "Outcome B";
        candidates[2] = "Outcome C";

        vm.startBroadcast(c.creatorKey);
        (uint256 eventId, uint256[] memory marketIds) = IEventFacet(c.diamond)
            .createEvent("Indexer audit S4 (event lifecycle)", candidates, block.timestamp + END_OFFSET, c.oracleManual);
        vm.stopBroadcast();

        // LP seeds CLOB for each child
        vm.startBroadcast(c.lpKey);
        IERC20(c.usdc).approve(c.diamond, type(uint256).max);
        IERC20(c.usdc).approve(c.exchange, type(uint256).max);
        for (uint256 i = 0; i < marketIds.length; i++) {
            uint256 mid = marketIds[i];
            (address yes, address no,,,) = IMarketFacet(c.diamond).getMarketStatus(mid);
            IMarketFacet(c.diamond).splitPosition(mid, USDC_SPLIT_LP);
            IERC20(yes).approve(c.exchange, type(uint256).max);
            IERC20(no).approve(c.exchange, type(uint256).max);
            IPrediXExchange(c.exchange)
                .placeOrder(mid, IPrediXExchange.Side.SELL_YES, PRICE_HALF, ORDER_AMOUNT, bytes32(0));
            IPrediXExchange(c.exchange)
                .placeOrder(mid, IPrediXExchange.Side.SELL_NO, PRICE_HALF, ORDER_AMOUNT, bytes32(0));
            IPrediXExchange(c.exchange)
                .placeOrder(mid, IPrediXExchange.Side.BUY_YES, PRICE_HALF, ORDER_AMOUNT, bytes32(0));
            IPrediXExchange(c.exchange)
                .placeOrder(mid, IPrediXExchange.Side.BUY_NO, PRICE_HALF, ORDER_AMOUNT, bytes32(0));
        }
        vm.stopBroadcast();

        uint256 deadline = block.timestamp + 5 minutes;

        // Child 0: A.Router.buyYes 10 USDC
        vm.startBroadcast(c.aKey);
        IERC20(c.usdc).approve(c.router, type(uint256).max);
        IPrediXRouter(c.router).buyYes(marketIds[0], TRADER_USDC, 1, a, 5, deadline, bytes32(0));
        vm.stopBroadcast();

        // Child 1: B.Router.buyNo 10 USDC
        vm.startBroadcast(c.bKey);
        IERC20(c.usdc).approve(c.router, type(uint256).max);
        IPrediXRouter(c.router).buyNo(marketIds[1], TRADER_USDC, 1, b, 5, deadline, bytes32(0));
        vm.stopBroadcast();

        // Child 2: A.splitPosition 10 USDC + Router.sellNo 10
        (, address no2,,,) = IMarketFacet(c.diamond).getMarketStatus(marketIds[2]);
        vm.startBroadcast(c.aKey);
        IERC20(c.usdc).approve(c.diamond, type(uint256).max);
        IMarketFacet(c.diamond).splitPosition(marketIds[2], TRADER_USDC);
        IERC20(no2).approve(c.router, type(uint256).max);
        IPrediXRouter(c.router).sellNo(marketIds[2], TRADER_USDC, 1, a, 5, deadline, bytes32(0));
        vm.stopBroadcast();

        console2.log("=== Scenario 4 setup complete ===");
        console2.log("S4_EVENT_ID    =", eventId);
        console2.log("child 0        =", marketIds[0]);
        console2.log("child 1        =", marketIds[1]);
        console2.log("child 2        =", marketIds[2]);
        console2.log("endTime        =", block.timestamp + END_OFFSET);
        console2.log("Hold +5 min past endTime, then run Scenario4_Resolve");
    }
}
