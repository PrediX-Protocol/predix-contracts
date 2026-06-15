// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import {AuditBase, ITestUSDCMint} from "./_AuditBase.sol";
import {console2} from "forge-std/Script.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IMarketFacet} from "@predix/shared/interfaces/IMarketFacet.sol";
import {IPrediXExchange} from "@predix/exchange/IPrediXExchange.sol";
import {IPrediXRouter} from "@predix/router/interfaces/IPrediXRouter.sol";

/// @notice Scenario 2 setup — recipient attribution (validates P1-F).
///         Creates fresh market endTime = now + 8 min. LP seeds SELL_YES 25
///         @ $0.50 (12.5 USDC cap, ≥ R's 10 USDC trade — no synthetic engages).
///         Deployer funds R (HD-15) with 30 USDC + tiny ETH. R then calls
///         Router.buyYes with recipient=U (HD-16), so the Trade event has
///         trader=R, recipient=U. After resolve, indexer should attribute
///         the accuracy score to U (not R).
///
///         Uses the Router `recipient` param directly — no Permit2 / ERC-4337
///         needed. The indexer P1-F fix only depends on which event field is
///         read; the actual UserOp infra is orthogonal.
contract Scenario2_Setup is AuditBase {
    uint256 internal constant FUND_USDC_R = 30e6;
    uint256 internal constant FUND_ETH_R = 0.00005 ether;
    uint256 internal constant USDC_SPLIT_LP = 50e6;
    uint256 internal constant ORDER_AMOUNT = 25e6;
    uint256 internal constant PRICE_HALF = 500000;
    uint256 internal constant TRADER_USDC = 10e6;
    uint256 internal constant END_OFFSET = 8 minutes;

    function run() external {
        Ctx memory c = _load();
        string memory mnemonic = vm.envString("MNEMONIC");
        uint256 rKey = vm.deriveKey(mnemonic, 15);
        uint256 uKey = vm.deriveKey(mnemonic, 16);
        address r = vm.addr(rKey);
        address u = vm.addr(uKey);

        // Fund R from deployer (USDC mint + tiny ETH for gas)
        vm.startBroadcast(c.deployerKey);
        ITestUSDCMint(c.usdc).mint(r, FUND_USDC_R);
        (bool okEth,) = r.call{value: FUND_ETH_R}("");
        require(okEth, "eth send to R failed");
        vm.stopBroadcast();

        // Creator creates market
        vm.startBroadcast(c.creatorKey);
        uint256 marketId = IMarketFacet(c.diamond)
            .createMarket("Indexer audit S2 (recipient attribution)", block.timestamp + END_OFFSET, c.oracleManual);
        vm.stopBroadcast();

        (address yes,,,,) = IMarketFacet(c.diamond).getMarketStatus(marketId);

        // LP seeds SELL_YES only (R is only doing buyYes, so don't need other sides)
        vm.startBroadcast(c.lpKey);
        IERC20(c.usdc).approve(c.diamond, type(uint256).max);
        IMarketFacet(c.diamond).splitPosition(marketId, USDC_SPLIT_LP);
        IERC20(yes).approve(c.exchange, type(uint256).max);
        IPrediXExchange(c.exchange)
            .placeOrder(marketId, IPrediXExchange.Side.SELL_YES, PRICE_HALF, ORDER_AMOUNT, bytes32(0));
        vm.stopBroadcast();

        // R (relayer EOA) executes Router.buyYes with recipient = U
        // R pays USDC + gas; U receives YES tokens.
        // Trade event: trader = R (msg.sender to Router), recipient = U.
        vm.startBroadcast(rKey);
        IERC20(c.usdc).approve(c.router, type(uint256).max);
        IPrediXRouter(c.router).buyYes(marketId, TRADER_USDC, 1, u, 5, block.timestamp + 5 minutes, bytes32(0));
        vm.stopBroadcast();

        console2.log("=== Scenario 2 setup complete ===");
        console2.log("S2_MARKET_ID =", marketId);
        console2.log("R (relayer)  =", r);
        console2.log("U (end user) =", u);
        console2.log("yesToken     =", yes);
        console2.log("endTime      =", block.timestamp + END_OFFSET);
        console2.log("Wait", END_OFFSET, "sec then run Scenario2_Resolve");
    }
}
