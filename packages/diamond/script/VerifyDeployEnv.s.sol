// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import {Script, console2} from "forge-std/Script.sol";

import {DeployEnvVerifier} from "./lib/DeployEnvVerifier.sol";

/// @title VerifyDeployEnv
/// @notice Standalone pre-flight that asserts the deploy environment binds to
///         known canonical infrastructure addresses on the target chain. Same
///         checks `DeployAll` runs in-broadcast — surface them in a separate
///         script so ops can dry-run the env vars before opening a broadcast.
///
///         Usage:
///             forge script VerifyDeployEnv --rpc-url $UNICHAIN_RPC_PRIMARY
///
///         No state changes; safe to repeat.
contract VerifyDeployEnv is Script {
    function run() external view {
        uint256 chainId = block.chainid;
        address permit2 = vm.envAddress("PERMIT2_ADDRESS");
        bool chainlinkEnabled = vm.envBool("CHAINLINK_ENABLED");
        address sequencerFeed = vm.envOr("CHAINLINK_SEQUENCER_UPTIME_FEED", address(0));

        DeployEnvVerifier.verifyPermit2(chainId, permit2);
        if (chainlinkEnabled) {
            DeployEnvVerifier.verifySequencerFeed(chainId, sequencerFeed);
        }

        console2.log("VerifyDeployEnv: chainId =", chainId);
        console2.log("VerifyDeployEnv: PERMIT2_ADDRESS =", permit2, "OK");
        if (chainlinkEnabled) {
            if (sequencerFeed == address(0)) {
                console2.log("VerifyDeployEnv: CHAINLINK_SEQUENCER_UPTIME_FEED = 0x0 (L1 / not required)");
            } else {
                console2.log("VerifyDeployEnv: CHAINLINK_SEQUENCER_UPTIME_FEED =", sequencerFeed, "OK");
            }
        } else {
            console2.log("VerifyDeployEnv: CHAINLINK_ENABLED=false (sequencer check skipped)");
        }
    }
}
