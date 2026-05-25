// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import {AuditBase} from "./_AuditBase.sol";
import {console2} from "forge-std/Script.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IMarketFacet} from "@predix/shared/interfaces/IMarketFacet.sol";
import {IPrediXExchange} from "@predix/exchange/IPrediXExchange.sol";

/// @notice Scenario 9 — direct-Exchange taker N does buy then sell on same market.
///         New market endTime = now + 5 min. LP seeds 4 orders depth 30 USDC.
///         N (HD-18):
///           1. Exchange.fillMarketOrder(BUY_YES, limit=$0.99, 10 USDC, taker=N) → ~20 YES
///           2. Exchange.fillMarketOrder(SELL_YES, limit=0, 10 YES, taker=N) → ~5 USDC
///         N ends with ~10 YES, +5 USDC (net spent 5 USDC).
///         Indexer expectation:
///         - taker_fill: 2 rows (BUY + SELL)
///         - user_stats: fill_count=2, total_volume=15M (10 BUY + 5 SELL)
///         - position table: NO ROW until redeem (Gap 1) — net cost basis lost
///         - holder: yesBalance reflects net 10 YES ✓
///         N does NOT redeem in this scenario (per task) — only holds 10 YES
///         worth ~10 USDC if YES wins.
contract Scenario9_Setup is AuditBase {
    uint256 internal constant USDC_SPLIT_LP = 120e6;
    uint256 internal constant ORDER_AMOUNT = 60e6; // 30 USDC depth @ $0.50
    uint256 internal constant PRICE_HALF = 500000;
    uint256 internal constant N_BUY_USDC = 10e6;
    uint256 internal constant N_SELL_YES = 10e6;
    uint256 internal constant BUY_LIMIT = 990000; // $0.99 (any reasonable price)
    uint256 internal constant SELL_LIMIT = 0;
    uint256 internal constant END_OFFSET = 5 minutes;

    function run() external {
        Ctx memory c = _load();
        string memory mnemonic = vm.envString("MNEMONIC");
        uint256 nKey = vm.deriveKey(mnemonic, 18);
        address n = vm.addr(nKey);

        vm.startBroadcast(c.creatorKey);
        uint256 marketId = IMarketFacet(c.diamond).createMarket(
            "Indexer audit S9 (direct-Exchange buy+sell)", block.timestamp + END_OFFSET, c.oracleManual
        );
        vm.stopBroadcast();

        (address yes, address no,,,) = IMarketFacet(c.diamond).getMarketStatus(marketId);

        vm.startBroadcast(c.lpKey);
        IERC20(c.usdc).approve(c.diamond, type(uint256).max);
        IMarketFacet(c.diamond).splitPosition(marketId, USDC_SPLIT_LP);
        IERC20(yes).approve(c.exchange, type(uint256).max);
        IERC20(no).approve(c.exchange, type(uint256).max);
        IPrediXExchange(c.exchange).placeOrder(marketId, IPrediXExchange.Side.SELL_YES, PRICE_HALF, ORDER_AMOUNT, bytes32(0));
        IPrediXExchange(c.exchange).placeOrder(marketId, IPrediXExchange.Side.SELL_NO, PRICE_HALF, ORDER_AMOUNT, bytes32(0));
        IPrediXExchange(c.exchange).placeOrder(marketId, IPrediXExchange.Side.BUY_YES, PRICE_HALF, ORDER_AMOUNT, bytes32(0));
        IPrediXExchange(c.exchange).placeOrder(marketId, IPrediXExchange.Side.BUY_NO, PRICE_HALF, ORDER_AMOUNT, bytes32(0));
        vm.stopBroadcast();

        uint256 deadline = block.timestamp + 5 minutes;

        // N BUY_YES via direct Exchange
        vm.startBroadcast(nKey);
        IERC20(c.usdc).approve(c.exchange, type(uint256).max);
        IPrediXExchange(c.exchange).fillMarketOrder(
            marketId, IPrediXExchange.Side.BUY_YES, BUY_LIMIT, N_BUY_USDC, n, n, 5, deadline, bytes32(0)
        );
        // N SELL_YES via direct Exchange (need YES approval to exchange)
        IERC20(yes).approve(c.exchange, type(uint256).max);
        IPrediXExchange(c.exchange).fillMarketOrder(
            marketId, IPrediXExchange.Side.SELL_YES, SELL_LIMIT, N_SELL_YES, n, n, 5, deadline, bytes32(0)
        );
        vm.stopBroadcast();

        console2.log("=== Scenario 9 setup complete ===");
        console2.log("S9_MARKET_ID =", marketId);
        console2.log("N (HD-18)    =", n);
        console2.log("yesToken     =", yes);
        console2.log("endTime      =", block.timestamp + END_OFFSET);
    }
}
