// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import {DevBase} from "./_DevBase.sol";
import {console2} from "forge-std/Script.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IMarketFacet} from "@predix/shared/interfaces/IMarketFacet.sol";
import {IPrediXExchange} from "@predix/exchange/IPrediXExchange.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";

/// @notice Variant 1 — full hybrid (AMM + CLOB).
///         LP provides 50 USDC + 100 YES into pool via PositionManager (full-range
///         NFT position), then seeds 4 CLOB maker orders @ $0.50 with depth 25
///         USDC each side. Tests cap convergence + waterfall routing under both
///         liquidity venues.
contract M1_Hybrid is DevBase {
    string internal constant QUESTION = "[Test] Will BTC hit $200K?";
    uint256 internal constant END_OFFSET = 24 hours;
    uint256 internal constant USDC_SPLIT = 200e6; // 200 USDC -> 200 YES + 200 NO
    uint256 internal constant AMM_USDC_AMT = 50e6;
    uint256 internal constant AMM_YES_AMT = 100e6;
    uint256 internal constant CLOB_ORDER_AMT = 50e6; // depth 25 USDC @ $0.50
    uint256 internal constant PRICE_HALF = 500000;

    function run() external {
        Ctx memory c = _load();
        address lp = vm.addr(c.lpKey);

        // 1. Creator creates market
        vm.startBroadcast(c.creatorKey);
        IERC20(c.usdc).approve(c.diamond, type(uint256).max);
        uint256 marketId =
            IMarketFacet(c.diamond).createMarket(QUESTION, block.timestamp + END_OFFSET, c.oracleManual);
        vm.stopBroadcast();

        (address yes, address no,,,) = IMarketFacet(c.diamond).getMarketStatus(marketId);

        // 2. LP splits 200 USDC -> 200 YES + 200 NO + grants Permit2 + AMM LP + CLOB orders
        vm.startBroadcast(c.lpKey);
        IERC20(c.usdc).approve(c.diamond, type(uint256).max);
        IMarketFacet(c.diamond).splitPosition(marketId, USDC_SPLIT);
        _grantPermit2(c, yes);
        (PoolKey memory key, uint256 tokenId) = _registerAndLpAmm(c, marketId, yes, lp, AMM_USDC_AMT, AMM_YES_AMT);

        IERC20(yes).approve(c.exchange, type(uint256).max);
        IERC20(no).approve(c.exchange, type(uint256).max);
        IERC20(c.usdc).approve(c.exchange, type(uint256).max);
        IPrediXExchange(c.exchange).placeOrder(marketId, IPrediXExchange.Side.SELL_YES, PRICE_HALF, CLOB_ORDER_AMT, bytes32(0));
        IPrediXExchange(c.exchange).placeOrder(marketId, IPrediXExchange.Side.SELL_NO, PRICE_HALF, CLOB_ORDER_AMT, bytes32(0));
        IPrediXExchange(c.exchange).placeOrder(marketId, IPrediXExchange.Side.BUY_YES, PRICE_HALF, CLOB_ORDER_AMT, bytes32(0));
        IPrediXExchange(c.exchange).placeOrder(marketId, IPrediXExchange.Side.BUY_NO, PRICE_HALF, CLOB_ORDER_AMT, bytes32(0));
        vm.stopBroadcast();

        console2.log("=== M1 hybrid complete ===");
        console2.log("marketId    :", marketId);
        console2.log("yesToken    :", yes);
        console2.log("noToken     :", no);
        console2.log("AMM tokenId :", tokenId);
        console2.log("endTime     :", block.timestamp + END_OFFSET);
    }
}
