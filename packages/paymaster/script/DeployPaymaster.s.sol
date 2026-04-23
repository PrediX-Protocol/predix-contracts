// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Script, console2} from "forge-std/Script.sol";
import {IEntryPoint} from "@account-abstraction/contracts/interfaces/IEntryPoint.sol";

import {PrediXPaymaster} from "../src/PrediXPaymaster.sol";

/// @title DeployPaymaster
/// @notice One-shot deploy + initial funding of PrediXPaymaster on Unichain Sepolia.
/// @dev Reads required env (fail-loud via vm.envAddress / vm.envUint — no defaults).
contract DeployPaymaster is Script {
    function run() external returns (PrediXPaymaster paymaster) {
        address entryPoint = vm.envAddress("ENTRY_POINT_V07");
        address ownerAddr = vm.envAddress("PAYMASTER_OWNER");
        address signerAddr = vm.envAddress("PAYMASTER_INITIAL_SIGNER");
        uint256 deployerKey = vm.envUint("DEPLOYER_PRIVATE_KEY");

        console2.log("=== PrediXPaymaster deploy ===");
        console2.log("chainId:   ", block.chainid);
        console2.log("EntryPoint:", entryPoint);
        console2.log("Owner:     ", ownerAddr);
        console2.log("Signer:    ", signerAddr);

        vm.startBroadcast(deployerKey);

        paymaster = new PrediXPaymaster(IEntryPoint(entryPoint), ownerAddr, signerAddr);
        paymaster.deposit{value: 0.001 ether}();

        vm.stopBroadcast();

        console2.log("Paymaster: ", address(paymaster));
        console2.log("Deposit:   ", paymaster.getDeposit());
    }
}
