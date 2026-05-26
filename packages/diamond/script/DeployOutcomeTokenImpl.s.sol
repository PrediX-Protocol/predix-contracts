// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import {Script, console2} from "forge-std/Script.sol";
import {OutcomeTokenClone} from "@predix/shared/tokens/OutcomeTokenClone.sol";

/// @notice One-shot: deploy `OutcomeTokenClone` master with `factory == DIAMOND_ADDRESS`.
/// @dev    Output address must be passed to `MarketFacet.setOutcomeTokenImpl` AFTER
///         the diamondCut that adds the `setOutcomeTokenImpl` selector lands.
///
///         Required env:
///           - MNEMONIC (HD-0 deployer)
///           - DIAMOND_ADDRESS  (live diamond proxy — encoded as `factory` immutable)
///           - UNICHAIN_RPC_PRIMARY
contract DeployOutcomeTokenImpl is Script {
    function run() external {
        string memory mnemonic = vm.envString("MNEMONIC");
        uint256 pk = vm.deriveKey(mnemonic, 0); // HD-0 deployer
        address diamond = vm.envAddress("DIAMOND_ADDRESS");

        console2.log("Deployer:", vm.addr(pk));
        console2.log("Diamond:", diamond);

        vm.startBroadcast(pk);
        OutcomeTokenClone impl = new OutcomeTokenClone(diamond);
        vm.stopBroadcast();

        console2.log("OutcomeTokenClone master deployed at:", address(impl));
        console2.log(
            string.concat(
                "RESULT_JSON={\"outcomeTokenImpl\":\"", vm.toString(address(impl)), "\",\"factory\":\"",
                vm.toString(diamond), "\"}"
            )
        );
    }
}
