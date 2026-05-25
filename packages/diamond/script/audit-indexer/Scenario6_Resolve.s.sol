// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import {AuditBase} from "./_AuditBase.sol";
import {console2} from "forge-std/Script.sol";
import {IMarketFacet} from "@predix/shared/interfaces/IMarketFacet.sol";
import {IManualOracle} from "@predix/oracle/interfaces/IManualOracle.sol";

/// @notice Scenario 6 — resolve market 10 (from round 1 S3) with outcome=true.
///         Three direct-Exchange takers (X/Y/Z) hold positions on this market.
///         After resolution, the indexer's Gap 1 should manifest: X/Y/Z's
///         `position` rows are missing / partial because their fills went
///         through Exchange directly (writePositionForOrder runs only on
///         maker side, takerOrderId=0x0 skips taker).
///         No redeem in this script — leave window open for indexer query.
contract Scenario6_Resolve is AuditBase {
    uint256 internal constant MARKET_ID = 10;

    function run() external {
        Ctx memory c = _load();
        bool outcome = vm.envOr("S6_OUTCOME", true);

        vm.startBroadcast(c.reporterKey);
        IManualOracle(c.oracleManual).report(MARKET_ID, outcome);
        vm.stopBroadcast();

        vm.startBroadcast(c.deployerKey);
        IMarketFacet(c.diamond).resolveMarket(MARKET_ID);
        vm.stopBroadcast();

        console2.log("=== Scenario 6: market 10 resolved ===");
        console2.log("outcome=", outcome);
    }
}
