// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import {AuditBase} from "./_AuditBase.sol";
import {console2} from "forge-std/Script.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IMarketFacet} from "@predix/shared/interfaces/IMarketFacet.sol";
import {IPrediXExchange} from "@predix/exchange/IPrediXExchange.sol";

/// @notice Scenario 3 — direct-Exchange takers (validates P1-A + P1-H).
///         Creates fresh market. LP seeds 4 CLOB maker orders @ $0.50.
///         Users X / Y / Z each call PrediXExchange.fillMarketOrder DIRECTLY
///         (NOT via Router) on different sides:
///           X: BUY_YES (10 USDC)
///           Y: SELL_YES (10 YES, after splitting 10 USDC)
///           Z: BUY_NO (10 USDC)
///         Indexer should see user_stats rows with fill_count >= 1 and
///         /api/users/{X|Y|Z}/maker-fills returning role:"direct-taker".
contract Scenario3 is AuditBase {
    uint256 internal constant USDC_SPLIT_LP = 50e6;
    uint256 internal constant ORDER_AMOUNT = 25e6;
    uint256 internal constant PRICE_HALF = 500000;
    uint256 internal constant TAKER_USDC = 10e6;
    uint256 internal constant TAKER_TOKEN = 10e6;
    uint256 internal constant USDC_SPLIT_Y = 10e6;
    uint256 internal constant END_OFFSET = 30 minutes; // long — we don't resolve in this scenario

    function run() external {
        Ctx memory c = _load();
        address x = vm.addr(c.xKey);
        address y = vm.addr(c.yKey);
        address z = vm.addr(c.zKey);

        // Creator creates market
        vm.startBroadcast(c.creatorKey);
        uint256 marketId = IMarketFacet(c.diamond).createMarket(
            "Indexer audit S3 (direct-takers)", block.timestamp + END_OFFSET, c.oracleManual
        );
        vm.stopBroadcast();

        (address yes, address no,,,) = IMarketFacet(c.diamond).getMarketStatus(marketId);

        // LP seeds 4 maker orders (so all 3 takers have something to fill against)
        vm.startBroadcast(c.lpKey);
        IERC20(c.usdc).approve(c.diamond, type(uint256).max);
        IMarketFacet(c.diamond).splitPosition(marketId, USDC_SPLIT_LP);
        IERC20(yes).approve(c.exchange, type(uint256).max);
        IERC20(no).approve(c.exchange, type(uint256).max);
        IERC20(c.usdc).approve(c.exchange, type(uint256).max);
        IPrediXExchange(c.exchange).placeOrder(marketId, IPrediXExchange.Side.SELL_YES, PRICE_HALF, ORDER_AMOUNT, bytes32(0));
        IPrediXExchange(c.exchange).placeOrder(marketId, IPrediXExchange.Side.SELL_NO, PRICE_HALF, ORDER_AMOUNT, bytes32(0));
        IPrediXExchange(c.exchange).placeOrder(marketId, IPrediXExchange.Side.BUY_YES, PRICE_HALF, ORDER_AMOUNT, bytes32(0));
        IPrediXExchange(c.exchange).placeOrder(marketId, IPrediXExchange.Side.BUY_NO, PRICE_HALF, ORDER_AMOUNT, bytes32(0));
        vm.stopBroadcast();

        uint256 deadline = block.timestamp + 5 minutes;

        // X: BUY_YES direct
        vm.startBroadcast(c.xKey);
        IERC20(c.usdc).approve(c.exchange, type(uint256).max);
        IPrediXExchange(c.exchange).fillMarketOrder(
            marketId, IPrediXExchange.Side.BUY_YES, PRICE_HALF, TAKER_USDC, x, x, 5, deadline, bytes32(0)
        );
        vm.stopBroadcast();

        // Y: split first then SELL_YES direct
        vm.startBroadcast(c.yKey);
        IERC20(c.usdc).approve(c.diamond, type(uint256).max);
        IMarketFacet(c.diamond).splitPosition(marketId, USDC_SPLIT_Y);
        IERC20(yes).approve(c.exchange, type(uint256).max);
        IPrediXExchange(c.exchange).fillMarketOrder(
            marketId, IPrediXExchange.Side.SELL_YES, PRICE_HALF, TAKER_TOKEN, y, y, 5, deadline, bytes32(0)
        );
        vm.stopBroadcast();

        // Z: BUY_NO direct
        vm.startBroadcast(c.zKey);
        IERC20(c.usdc).approve(c.exchange, type(uint256).max);
        IPrediXExchange(c.exchange).fillMarketOrder(
            marketId, IPrediXExchange.Side.BUY_NO, PRICE_HALF, TAKER_USDC, z, z, 5, deadline, bytes32(0)
        );
        vm.stopBroadcast();

        console2.log("=== Scenario 3 complete ===");
        console2.log("S3_MARKET_ID =", marketId);
        console2.log("X (BUY_YES)  :", x);
        console2.log("Y (SELL_YES) :", y);
        console2.log("Z (BUY_NO)   :", z);
    }
}
