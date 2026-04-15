// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Script, console2} from "forge-std/Script.sol";
import {TimelockController} from "@openzeppelin/contracts/governance/TimelockController.sol";

/// @title DeployTimelock
/// @notice Deploys an OpenZeppelin TimelockController that will hold `CUT_EXECUTOR_ROLE` on the
///         diamond. Proposer and executor are both the protocol multisig; admin is `address(0)`
///         so post-deploy config change is impossible — governance is locked to multisig + delay.
contract DeployTimelock is Script {
    function run() external returns (address timelock) {
        address multisig = vm.envAddress("MULTISIG_ADDRESS");
        uint256 delay = vm.envUint("TIMELOCK_DELAY_SECONDS");

        address[] memory proposers = new address[](1);
        proposers[0] = multisig;
        address[] memory executors = new address[](1);
        executors[0] = multisig;

        vm.startBroadcast(vm.envUint("DEPLOYER_PRIVATE_KEY"));
        timelock = address(new TimelockController(delay, proposers, executors, address(0)));
        vm.stopBroadcast();

        console2.log("TimelockController:", timelock);
        console2.log("  multisig:", multisig);
        console2.log("  delay:", delay);
    }
}
