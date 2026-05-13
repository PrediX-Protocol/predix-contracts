// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import {Script, console2} from "forge-std/Script.sol";
import {IAccessControlFacet} from "@predix/shared/interfaces/IAccessControlFacet.sol";
import {Roles} from "@predix/shared/constants/Roles.sol";

contract GrantCreatorRole is Script {
    function run() external {
        address diamond = vm.envAddress("DIAMOND_ADDRESS");
        uint256 deployerKey = vm.envUint("DEPLOYER_PRIVATE_KEY");

        address[1] memory addrs = [
            0xFAD5643B461C9ECF81d1FdD093b3780769b1897F
        ];

        vm.startBroadcast(deployerKey);
        for (uint256 i; i < addrs.length; ++i) {
            IAccessControlFacet(diamond).grantRole(Roles.CREATOR_ROLE, addrs[i]);
            console2.log("granted CREATOR_ROLE:", addrs[i]);
        }
        vm.stopBroadcast();
    }
}
