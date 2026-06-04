// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import {Script, console2} from "forge-std/Script.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {ILinkedEventFacet} from "@predix/shared/interfaces/ILinkedEventFacet.sol";

/// @notice Phase-2 SETUP (HD-6): approve -> createLinkedEvent with a SHORT endTime -> mintCompleteSet.
///         Run as one forge broadcast so the approve/create/mint nonce sequence is managed reliably
///         (raw back-to-back `cast send` races the load-balanced public RPC). Emits the new eventId +
///         endTime for the orchestrator to wait on before running RunLinkedResolveB.
/// @dev Required env: DIAMOND_ADDRESS, USDC_ADDRESS, ORACLE_MANUAL_ADDRESS, MNEMONIC, CREATOR_HD_INDEX,
///      END_OFFSET (seconds until the event ends; must exceed this script's own run time).
contract RunLinkedResolveA is Script {
    uint256 internal constant MINT = 50e6; // 50 USDC complete set
    uint256 internal constant APPROVE_AMT = 80e6; // 50 mint + 3x10 creation fee

    function run() external {
        address diamond = vm.envAddress("DIAMOND_ADDRESS");
        IERC20 usdc = IERC20(vm.envAddress("USDC_ADDRESS"));
        address oracle = vm.envAddress("ORACLE_MANUAL_ADDRESS");
        uint256 pk = vm.deriveKey(vm.envString("MNEMONIC"), uint32(vm.envUint("CREATOR_HD_INDEX")));
        uint256 endTime = block.timestamp + vm.envUint("END_OFFSET");

        string[] memory q = new string[](3);
        q[0] = "A wins?";
        q[1] = "B wins?";
        q[2] = "C wins?";

        vm.startBroadcast(pk);
        usdc.approve(diamond, APPROVE_AMT);
        (uint256 eventId,) = ILinkedEventFacet(diamond).createLinkedEvent("LINKED RESOLVE TEST", q, endTime, oracle);
        ILinkedEventFacet(diamond).mintCompleteSet(eventId, MINT);
        vm.stopBroadcast();

        require(ILinkedEventFacet(diamond).isLinkedEvent(eventId), "not linked");
        require(ILinkedEventFacet(diamond).eventPoolOf(eventId) == MINT, "pool != mint");

        console2.log("RESULT_EVENTID", eventId);
        console2.log("RESULT_ENDTIME", endTime);
    }
}
