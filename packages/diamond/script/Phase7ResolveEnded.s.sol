// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import {Script, console2} from "forge-std/Script.sol";

import {IMarketFacet} from "@predix/shared/interfaces/IMarketFacet.sol";
import {IEventFacet} from "@predix/shared/interfaces/IEventFacet.sol";

/// @notice Minimal view of ManualOracle's reporter entrypoints.
interface IManualOracleReport {
    function report(uint256 marketId, bool outcome) external;
    function reportEvent(uint256 eventId, uint256 winningIndex) external;
}

/// @notice Resolves the backlog of ended-but-unresolved markets on Unichain
///         mainnet with arbitrarily chosen outcomes (challengeDelay == 0, so a
///         report finalizes immediately and resolveMarket/resolveEvent can
///         consume it in the same broadcast).
/// @dev    Two on-chain steps per market, both from the REPORTER_ROLE signer
///         (REPORTER_MNEMONIC_INDEX, default 7 = 0x67934f80...): report the
///         outcome to ManualOracle, then resolve on the diamond (resolve* is
///         permissionless once the oracle has an answer).
///
///         Binary markets resolve individually; event children resolve
///         atomically via resolveEvent at the event level. Winning indices are
///         all < the event's candidate count.
contract Phase7ResolveEnded is Script {
    function run() external {
        address diamond = vm.envAddress("DIAMOND_ADDRESS");
        address oracle = vm.envAddress("ORACLE_MANUAL_ADDRESS");
        uint256 reporterPk =
            vm.deriveKey(vm.envString("MNEMONIC"), uint32(vm.envOr("REPORTER_MNEMONIC_INDEX", uint256(7))));

        // Binary ended-unresolved markets + chosen outcome.
        uint256[7] memory binIds = [uint256(1), 32, 33, 34, 72, 104, 116];
        bool[7] memory binOut = [false, false, true, false, true, true, false];

        // Event ended-unresolved + chosen winning index (verified < candidate count).
        uint256[19] memory evIds = [uint256(7), 8, 9, 10, 11, 12, 13, 14, 15, 16, 17, 18, 19, 20, 21, 22, 23, 24, 25];
        uint256[19] memory evWin = [uint256(2), 0, 1, 3, 0, 2, 1, 3, 0, 2, 4, 1, 0, 2, 0, 3, 1, 0, 3];

        vm.startBroadcast(reporterPk);

        for (uint256 i; i < binIds.length; ++i) {
            IManualOracleReport(oracle).report(binIds[i], binOut[i]);
            IMarketFacet(diamond).resolveMarket(binIds[i]);
            console2.log("Resolved binary marketId:", binIds[i]);
            console2.log("  outcome (YES=true):", binOut[i]);
        }

        for (uint256 i; i < evIds.length; ++i) {
            IManualOracleReport(oracle).reportEvent(evIds[i], evWin[i]);
            IEventFacet(diamond).resolveEvent(evIds[i]);
            console2.log("Resolved eventId:", evIds[i]);
            console2.log("  winningIndex:", evWin[i]);
        }

        vm.stopBroadcast();
        console2.log("DONE: resolved 7 binary markets + 19 events");
    }
}
