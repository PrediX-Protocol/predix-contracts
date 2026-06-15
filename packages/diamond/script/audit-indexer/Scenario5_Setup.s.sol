// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import {AuditBase} from "./_AuditBase.sol";
import {console2} from "forge-std/Script.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IMarketFacet} from "@predix/shared/interfaces/IMarketFacet.sol";
import {IPrediXExchange} from "@predix/exchange/IPrediXExchange.sol";
import {IPrediXRouter} from "@predix/router/interfaces/IPrediXRouter.sol";

/// @notice Scenario 5 setup — refund flow precursor (validates R3-A
///         activeMarkets path). Creates fresh market endTime = now + 5 min.
///         LP seeds CLOB. Trader A executes one buyYes trade so there's
///         outstanding YES + NO supply when refund mode is enabled.
///         After this script + 5-min wait, run a Safe tx to
///         grantRole(ADMIN_ROLE, deployer) on the diamond, then
///         Scenario5_Refund.
contract Scenario5_Setup is AuditBase {
    uint256 internal constant USDC_SPLIT_LP = 50e6;
    uint256 internal constant ORDER_AMOUNT = 25e6;
    uint256 internal constant PRICE_HALF = 500000;
    uint256 internal constant TRADER_USDC = 10e6;
    uint256 internal constant END_OFFSET = 5 minutes;

    function run() external {
        Ctx memory c = _load();
        address a = vm.addr(c.aKey);

        vm.startBroadcast(c.creatorKey);
        uint256 marketId = IMarketFacet(c.diamond)
            .createMarket("Indexer audit S5 (refund flow)", block.timestamp + END_OFFSET, c.oracleManual);
        vm.stopBroadcast();

        (address yes, address no,,,) = IMarketFacet(c.diamond).getMarketStatus(marketId);

        vm.startBroadcast(c.lpKey);
        IERC20(c.usdc).approve(c.diamond, type(uint256).max);
        IMarketFacet(c.diamond).splitPosition(marketId, USDC_SPLIT_LP);
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

        vm.startBroadcast(c.aKey);
        IERC20(c.usdc).approve(c.router, type(uint256).max);
        IPrediXRouter(c.router).buyYes(marketId, TRADER_USDC, 1, a, 5, block.timestamp + 5 minutes, bytes32(0));
        // A also needs a matched pair (YES + NO) to call refund. Split to ensure
        // A holds equal yes+no for the refund call.
        IERC20(c.usdc).approve(c.diamond, type(uint256).max);
        IMarketFacet(c.diamond).splitPosition(marketId, TRADER_USDC);
        vm.stopBroadcast();

        console2.log("=== Scenario 5 setup complete ===");
        console2.log("S5_MARKET_ID =", marketId);
        console2.log("traderA      =", a);
        console2.log("yesToken     =", yes);
        console2.log("noToken      =", no);
        console2.log("endTime      =", block.timestamp + END_OFFSET);
        console2.log("Next: Safe-grant ADMIN_ROLE to deployer, then Scenario5_Refund");
    }
}
