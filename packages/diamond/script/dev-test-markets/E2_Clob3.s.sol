// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import {DevBase} from "./_DevBase.sol";
import {console2} from "forge-std/Script.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IMarketFacet} from "@predix/shared/interfaces/IMarketFacet.sol";
import {IEventFacet} from "@predix/shared/interfaces/IEventFacet.sol";
import {IPrediXExchange} from "@predix/exchange/IPrediXExchange.sol";

/// @notice Event variant 2 — 3 children, ALL CLOB-only (no AMM pools).
///         Cheaper setup, tests event resolution + multi-child CLOB liquidity.
contract E2_Clob3 is DevBase {
    string internal constant EVENT_NAME = "[Test Event] Top 3 picks (CLOB only)";
    uint256 internal constant END_OFFSET = 24 hours;
    uint256 internal constant USDC_SPLIT_PER_CHILD = 30e6;
    uint256 internal constant CLOB_ORDER_AMT = 20e6; // depth 10 USDC @ $0.50
    uint256 internal constant PRICE_HALF = 500000;

    function run() external {
        Ctx memory c = _load();

        string[] memory candidates = new string[](3);
        candidates[0] = "Pick X";
        candidates[1] = "Pick Y";
        candidates[2] = "Pick Z";

        vm.startBroadcast(c.creatorKey);
        IERC20(c.usdc).approve(c.diamond, type(uint256).max);
        (uint256 eventId, uint256[] memory marketIds) =
            IEventFacet(c.diamond).createEvent(EVENT_NAME, candidates, block.timestamp + END_OFFSET, c.oracleManual);
        vm.stopBroadcast();

        vm.startBroadcast(c.lpKey);
        IERC20(c.usdc).approve(c.diamond, type(uint256).max);
        IERC20(c.usdc).approve(c.exchange, type(uint256).max);

        for (uint256 i = 0; i < marketIds.length; i++) {
            uint256 mid = marketIds[i];
            (address yes, address no,,,) = IMarketFacet(c.diamond).getMarketStatus(mid);

            IMarketFacet(c.diamond).splitPosition(mid, USDC_SPLIT_PER_CHILD);

            IERC20(yes).approve(c.exchange, type(uint256).max);
            IERC20(no).approve(c.exchange, type(uint256).max);
            IPrediXExchange(c.exchange).placeOrder(mid, IPrediXExchange.Side.SELL_YES, PRICE_HALF, CLOB_ORDER_AMT, bytes32(0));
            IPrediXExchange(c.exchange).placeOrder(mid, IPrediXExchange.Side.SELL_NO, PRICE_HALF, CLOB_ORDER_AMT, bytes32(0));
            IPrediXExchange(c.exchange).placeOrder(mid, IPrediXExchange.Side.BUY_YES, PRICE_HALF, CLOB_ORDER_AMT, bytes32(0));
            IPrediXExchange(c.exchange).placeOrder(mid, IPrediXExchange.Side.BUY_NO, PRICE_HALF, CLOB_ORDER_AMT, bytes32(0));
        }
        vm.stopBroadcast();

        console2.log("=== E2 CLOB-only event complete ===");
        console2.log("eventId       :", eventId);
        console2.log("child 0       :", marketIds[0]);
        console2.log("child 1       :", marketIds[1]);
        console2.log("child 2       :", marketIds[2]);
        console2.log("endTime       :", block.timestamp + END_OFFSET);
    }
}
