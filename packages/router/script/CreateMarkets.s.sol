// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import {Script, console2} from "forge-std/Script.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {PrediXMarketFactory} from "@predix/router/PrediXMarketFactory.sol";

/// @title CreateMarkets
/// @notice One-shot script to create initial markets via MarketFactory.
contract CreateMarkets is Script {
    function run() external {
        uint256 deployerKey = vm.envUint("DEPLOYER_PRIVATE_KEY");
        address usdc = vm.envAddress("USDC_ADDRESS");
        address factory = vm.envAddress("MARKET_FACTORY_ADDRESS");
        address oracle = vm.envAddress("MANUAL_ORACLE_ADDRESS");

        uint256 liquidityDelta = 50e9;
        uint256 budgetPerMarket = 200_000e6;

        vm.startBroadcast(deployerKey);

        IERC20(usdc).approve(factory, type(uint256).max);

        // Market 1: BTS comeback — binary
        uint256 btsMarketId = PrediXMarketFactory(factory).createMarketWithPool(
            "Will BTS announce a full-group comeback before June 30, 2026?",
            1778616000, // 2026-05-12 20:00 UTC
            oracle,
            liquidityDelta,
            budgetPerMarket
        );
        console2.log("BTS market created, marketId:", btsMarketId);

        // Market 2: Netflix top show — multi-outcome event
        string[] memory candidates = new string[](3);
        candidates[0] = "Man on Fire";
        candidates[1] = "Legends";
        candidates[2] = "Others";

        (uint256 eventId, uint256[] memory childIds) = PrediXMarketFactory(factory).createEventWithPools(
            "What will be the top global Netflix show this week?",
            candidates,
            1778702400, // 2026-05-13 20:00 UTC
            oracle,
            liquidityDelta,
            budgetPerMarket * 3
        );
        console2.log("Netflix event created, eventId:", eventId);
        for (uint256 i; i < childIds.length; ++i) {
            console2.log("  child marketId:", childIds[i]);
        }

        vm.stopBroadcast();
    }
}
