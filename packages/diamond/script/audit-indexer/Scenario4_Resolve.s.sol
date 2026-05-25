// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import {AuditBase} from "./_AuditBase.sol";
import {console2} from "forge-std/Script.sol";
import {IEventFacet} from "@predix/shared/interfaces/IEventFacet.sol";
import {IManualOracle} from "@predix/oracle/interfaces/IManualOracle.sol";

/// @notice Scenario 4 resolve — after endTime + 5-minute hold. Reporter
///         publishes event winningIndex on ManualOracle, then anyone calls
///         resolveEvent which atomically resolves all children.
///         Requires `S4_EVENT_ID` env var (logged by Scenario4_Setup).
///         Optional `S4_WINNING_INDEX` (default 0).
contract Scenario4_Resolve is AuditBase {
    function run() external {
        Ctx memory c = _load();
        uint256 eventId = vm.envUint("S4_EVENT_ID");
        uint256 winningIndex = vm.envOr("S4_WINNING_INDEX", uint256(0));

        vm.startBroadcast(c.reporterKey);
        IManualOracle(c.oracleManual).reportEvent(eventId, winningIndex);
        vm.stopBroadcast();

        vm.startBroadcast(c.deployerKey);
        IEventFacet(c.diamond).resolveEvent(eventId);
        vm.stopBroadcast();

        console2.log("=== Scenario 4 event resolved ===");
        console2.log("eventId      :", eventId);
        console2.log("winningIndex :", winningIndex);
    }
}
