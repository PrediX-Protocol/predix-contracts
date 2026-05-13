// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import {Script, console2} from "forge-std/Script.sol";
import {IAccessControlFacet} from "@predix/shared/interfaces/IAccessControlFacet.sol";
import {Roles} from "@predix/shared/constants/Roles.sol";
import {ManualOracle} from "@predix/oracle/adapters/ManualOracle.sol";

contract GrantOperatorReporter is Script {
    function run() external {
        address diamond = vm.envAddress("DIAMOND_ADDRESS");
        address oracle = vm.envAddress("MANUAL_ORACLE_ADDRESS");
        uint256 deployerKey = vm.envUint("DEPLOYER_PRIVATE_KEY");

        address[1] memory addrs = [
            0xFAD5643B461C9ECF81d1FdD093b3780769b1897F
        ];

        vm.startBroadcast(deployerKey);

        for (uint256 i; i < addrs.length; ++i) {
            IAccessControlFacet(diamond).grantRole(Roles.OPERATOR_ROLE, addrs[i]);
            console2.log("OPERATOR_ROLE on Diamond:", addrs[i]);

            ManualOracle(oracle).grantRole(ManualOracle(oracle).REPORTER_ROLE(), addrs[i]);
            console2.log("REPORTER_ROLE on Oracle: ", addrs[i]);
        }

        vm.stopBroadcast();
    }
}
