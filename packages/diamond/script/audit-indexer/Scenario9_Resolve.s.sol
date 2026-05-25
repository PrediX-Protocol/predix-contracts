// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import {AuditBase} from "./_AuditBase.sol";
import {console2} from "forge-std/Script.sol";
import {IMarketFacet} from "@predix/shared/interfaces/IMarketFacet.sol";
import {IManualOracle} from "@predix/oracle/interfaces/IManualOracle.sol";

/// @notice Scenario 9 resolve. N does NOT redeem (per task). N is left holding
///         ~10 YES (winning side) — the indexer should be able to see that
///         N's position never had a row written, even with a non-zero token
///         balance — confirming Gap 1.
contract Scenario9_Resolve is AuditBase {
    function run() external {
        Ctx memory c = _load();
        uint256 marketId = vm.envUint("S9_MARKET_ID");
        bool outcome = vm.envOr("S9_OUTCOME", true);

        vm.startBroadcast(c.reporterKey);
        IManualOracle(c.oracleManual).report(marketId, outcome);
        vm.stopBroadcast();

        vm.startBroadcast(c.deployerKey);
        IMarketFacet(c.diamond).resolveMarket(marketId);
        vm.stopBroadcast();

        console2.log("=== Scenario 9 resolved (N intentionally does NOT redeem) ===");
        console2.log("marketId :", marketId);
        console2.log("outcome  :", outcome);
    }
}
