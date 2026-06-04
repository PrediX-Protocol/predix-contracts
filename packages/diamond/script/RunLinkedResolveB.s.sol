// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import {Script, console2} from "forge-std/Script.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {ILinkedEventFacet} from "@predix/shared/interfaces/ILinkedEventFacet.sol";
import {IEventFacet} from "@predix/shared/interfaces/IEventFacet.sol";

/// @notice Minimal reporter surface of ManualOracle (avoids a cross-package interface import in a script).
interface IReporter {
    function reportEvent(uint256 eventId, uint256 winningIndex) external;
}

/// @notice Phase-2 FINISH (multi-signer): HD-7 (REPORTER_ROLE) reports the winning outcome to the oracle,
///         then HD-6 resolves the event and redeems the complete set from the shared pool. Asserts the
///         solvency theorem under resolution: the complete-set holder's payout == the full pre-redeem pool,
///         and the pool drains to 0. Must be run only AFTER the event endTime has passed (orchestrator waits)
///         so resolveEvent's `block.timestamp >= endTime` gate is satisfied; challengeDelay==0 makes the
///         report immediately consumable in the same tx batch.
/// @dev Required env: DIAMOND_ADDRESS, USDC_ADDRESS, ORACLE_MANUAL_ADDRESS, MNEMONIC, CREATOR_HD_INDEX,
///      REPORTER_HD_INDEX, RESOLVE_EVENT_ID, WINNING_INDEX.
contract RunLinkedResolveB is Script {
    function run() external {
        address diamond = vm.envAddress("DIAMOND_ADDRESS");
        IERC20 usdc = IERC20(vm.envAddress("USDC_ADDRESS"));
        address oracle = vm.envAddress("ORACLE_MANUAL_ADDRESS");
        uint256 pk6 = vm.deriveKey(vm.envString("MNEMONIC"), uint32(vm.envUint("CREATOR_HD_INDEX")));
        uint256 pk7 = vm.deriveKey(vm.envString("MNEMONIC"), uint32(vm.envUint("REPORTER_HD_INDEX")));
        address h6 = vm.addr(pk6);
        uint256 eventId = vm.envUint("RESOLVE_EVENT_ID");
        uint256 winningIndex = vm.envUint("WINNING_INDEX");

        uint256 poolBefore = ILinkedEventFacet(diamond).eventPoolOf(eventId);
        uint256 usdcBefore = usdc.balanceOf(h6);

        // 1) reporter (HD-7) publishes the winning outcome to the oracle
        vm.startBroadcast(pk7);
        IReporter(oracle).reportEvent(eventId, winningIndex);
        vm.stopBroadcast();

        // 2) HD-6 pulls the resolution into the diamond, then redeems the complete set from the pool
        vm.startBroadcast(pk6);
        IEventFacet(diamond).resolveEvent(eventId);
        uint256 payout = ILinkedEventFacet(diamond).redeemLinked(eventId);
        vm.stopBroadcast();

        uint256 usdcAfter = usdc.balanceOf(h6);
        uint256 poolAfter = ILinkedEventFacet(diamond).eventPoolOf(eventId);

        require(payout == poolBefore, "SOLVENCY VIOLATED: payout != pool");
        require(poolAfter == 0, "pool not drained to 0");
        require(usdcAfter - usdcBefore == poolBefore, "USDC delta != pool");

        console2.log("RESULT_PAYOUT", payout);
        console2.log("RESULT_POOL_BEFORE", poolBefore);
        console2.log("RESULT_POOL_AFTER", poolAfter);
        console2.log("RESULT_PHASE2_PASS", uint256(1));
    }
}
