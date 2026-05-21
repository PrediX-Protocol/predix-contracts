// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import {Script, console2} from "forge-std/Script.sol";

import {ChainlinkOracle} from "@predix/oracle/adapters/ChainlinkOracle.sol";

/// @title DeployChainlinkOracle
/// @notice Standalone deploy of `ChainlinkOracle`. Unlike `DeployOracles` it
///         does not redeploy `ManualOracle` — use this when the manual oracle is
///         already live and only the Chainlink adapter is being added. Grants
///         `REGISTRAR_ROLE`, hands `DEFAULT_ADMIN_ROLE` to the multisig, and
///         renounces the deployer's admin (grant-before-renounce keeps the
///         last-admin guard satisfied). The post-deploy
///         `IMarketFacet.approveOracle(...)` is left to governance because it
///         requires `ADMIN_ROLE` on the diamond.
///
///         Required env: MULTISIG_ADDRESS, DIAMOND_ADDRESS, REGISTRAR_ADDRESS,
///         MNEMONIC or DEPLOYER_PRIVATE_KEY.
///         Optional env: CHAINLINK_SEQUENCER_UPTIME_FEED (pass the L2 sequencer
///         uptime feed; omit / address(0) skips the sequencer check on L1).
///
///         Usage:
///           forge script packages/oracle/script/DeployChainlinkOracle.s.sol:DeployChainlinkOracle \
///               --rpc-url $RPC_URL --broadcast
contract DeployChainlinkOracle is Script {
    function run() external returns (address chainlinkOracle) {
        address multisig = vm.envAddress("MULTISIG_ADDRESS");
        address diamond = vm.envAddress("DIAMOND_ADDRESS");
        address registrar = vm.envAddress("REGISTRAR_ADDRESS");
        // address(0) skips the sequencer check (L1); on L2 pass the Chainlink feed.
        address sequencerFeed = vm.envOr("CHAINLINK_SEQUENCER_UPTIME_FEED", address(0));

        // Deployer key resolution mirrors DeployAll / DeployMarketFactory:
        // MNEMONIC (BIP-44 index 0) takes precedence over DEPLOYER_PRIVATE_KEY.
        uint256 deployerKey;
        string memory mnemonic = vm.envOr("MNEMONIC", string(""));
        if (bytes(mnemonic).length > 0) {
            deployerKey = vm.deriveKey(mnemonic, 0);
        } else {
            deployerKey = vm.envUint("DEPLOYER_PRIVATE_KEY");
        }
        address deployer = vm.addr(deployerKey);

        vm.startBroadcast(deployerKey);
        // Deployer holds DEFAULT_ADMIN_ROLE temporarily so the registrar grant can
        // settle in the same broadcast; final handover to the multisig is the last
        // two calls. Mirrors DiamondDeployLib.transferGovernance.
        ChainlinkOracle oracle = new ChainlinkOracle(deployer, sequencerFeed, diamond);
        oracle.grantRole(oracle.REGISTRAR_ROLE(), registrar);
        oracle.grantRole(oracle.DEFAULT_ADMIN_ROLE(), multisig);
        oracle.renounceRole(oracle.DEFAULT_ADMIN_ROLE(), deployer);
        vm.stopBroadcast();

        chainlinkOracle = address(oracle);

        console2.log("============================================================");
        console2.log("ChainlinkOracle deployment");
        console2.log("============================================================");
        console2.log("ChainlinkOracle:", chainlinkOracle);
        console2.log("diamond:        ", diamond);
        console2.log("sequencerFeed:  ", sequencerFeed);
        console2.log("registrar:      ", registrar);
        console2.log("admin(multisig):", multisig);
        console2.log("");
        console2.log("Next (governance, ADMIN_ROLE on diamond):");
        console2.log("  IMarketFacet.approveOracle(ChainlinkOracle)");
    }
}
