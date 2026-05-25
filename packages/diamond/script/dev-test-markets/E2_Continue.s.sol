// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import {DevBase} from "./_DevBase.sol";
import {console2} from "forge-std/Script.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IMarketFacet} from "@predix/shared/interfaces/IMarketFacet.sol";
import {IEventFacet} from "@predix/shared/interfaces/IEventFacet.sol";
import {IPrediXExchange} from "@predix/exchange/IPrediXExchange.sol";

/// @notice Continue E2 setup — event already created, but LP step nonce-conflicted.
///         Reads event via E2_EVENT_ID env var and finishes split + CLOB seed for each child.
contract E2_Continue is DevBase {
    uint256 internal constant USDC_SPLIT_PER_CHILD = 30e6;
    uint256 internal constant CLOB_ORDER_AMT = 20e6;
    uint256 internal constant PRICE_HALF = 500000;

    function run() external {
        Ctx memory c = _load();
        uint256 eventId = vm.envUint("E2_EVENT_ID");
        IEventFacet.EventView memory ev = IEventFacet(c.diamond).getEvent(eventId);
        require(ev.marketIds.length > 0, "event not found");

        vm.startBroadcast(c.lpKey);
        IERC20(c.usdc).approve(c.diamond, type(uint256).max);
        IERC20(c.usdc).approve(c.exchange, type(uint256).max);

        for (uint256 i = 0; i < ev.marketIds.length; i++) {
            uint256 mid = ev.marketIds[i];
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

        console2.log("=== E2 continue complete ===");
        console2.log("eventId        :", eventId);
        for (uint256 i = 0; i < ev.marketIds.length; i++) {
            console2.log("  child", i, "=", ev.marketIds[i]);
        }
    }
}
