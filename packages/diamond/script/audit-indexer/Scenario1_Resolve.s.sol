// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import {AuditBase} from "./_AuditBase.sol";
import {console2} from "forge-std/Script.sol";
import {IMarketFacet} from "@predix/shared/interfaces/IMarketFacet.sol";
import {IManualOracle} from "@predix/oracle/interfaces/IManualOracle.sol";

/// @notice Scenario 1 resolve — after the 8-minute wait. Reporter publishes
///         outcome=true on ManualOracle, then anyone calls resolveMarket so
///         the indexer's accuracy aggregator can compute scores.
///         Requires `S1_MARKET_ID` env var (logged by Scenario1_Setup).
contract Scenario1_Resolve is AuditBase {
    function run() external {
        Ctx memory c = _load();
        uint256 marketId = vm.envUint("S1_MARKET_ID");
        bool outcome = vm.envOr("S1_OUTCOME", true);

        vm.startBroadcast(c.reporterKey);
        IManualOracle(c.oracleManual).report(marketId, outcome);
        vm.stopBroadcast();

        vm.startBroadcast(c.deployerKey);
        IMarketFacet(c.diamond).resolveMarket(marketId);
        vm.stopBroadcast();

        console2.log("=== Scenario 1 resolved ===");
        console2.log("marketId :", marketId);
        console2.log("outcome  :", outcome);
    }
}
