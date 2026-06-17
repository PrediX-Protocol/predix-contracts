// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import {Script, console2} from "forge-std/Script.sol";
import {BuilderRegistry} from "@predix/exchange/BuilderRegistry.sol";

/// @notice Deploy the standalone BuilderRegistry (Sub-plan 01). ctor = (diamond).
///         Governance is gated by the diamond's ADMIN_ROLE (registry reads hasRole).
/// @dev Sub-plan 05 Task 1 Step 1. Local/fork DRY-RUN only — run WITHOUT `--broadcast`;
///      `--broadcast` is gated to the mainnet runbook (README_FEE_DEPLOY.md) on explicit human go.
contract DeployBuilderRegistry is Script {
    function run() external returns (address registry) {
        address diamond = vm.envOr("DIAMOND_ADDRESS", 0xC8F12AF2a396c9C906ac36Bc0AC2279BBb69Ef96);
        uint256 key = _deployerKey();
        vm.startBroadcast(key);
        registry = address(new BuilderRegistry(diamond));
        vm.stopBroadcast();
        console2.log("BuilderRegistry:", registry);
        console2.log("  diamond arg  :", diamond);
    }

    function _deployerKey() internal view returns (uint256) {
        string memory m = vm.envOr("MNEMONIC", string(""));
        return bytes(m).length > 0 ? vm.deriveKey(m, 0) : vm.envUint("DEPLOYER_PRIVATE_KEY");
    }
}
