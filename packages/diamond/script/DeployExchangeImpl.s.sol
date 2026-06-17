// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import {Script, console2} from "forge-std/Script.sol";
import {PrediXExchange} from "@predix/exchange/PrediXExchange.sol";

/// @notice Deploy a fresh PrediXExchange implementation (Sub-plan 03). NO proxy, NO init:
///         this impl is the `newImpl` for the live proxy's proposeUpgrade -> 48h -> executeUpgrade.
/// @dev Sub-plan 05 Task 1 Step 2. Local/fork DRY-RUN only — run WITHOUT `--broadcast`.
contract DeployExchangeImpl is Script {
    function run() external returns (address impl) {
        uint256 key = _deployerKey();
        vm.startBroadcast(key);
        impl = address(new PrediXExchange());
        vm.stopBroadcast();
        console2.log("new PrediXExchange impl:", impl);
    }

    function _deployerKey() internal view returns (uint256) {
        string memory m = vm.envOr("MNEMONIC", string(""));
        return bytes(m).length > 0 ? vm.deriveKey(m, 0) : vm.envUint("DEPLOYER_PRIVATE_KEY");
    }
}
