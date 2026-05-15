// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import {Script, console2} from "forge-std/Script.sol";

import {FaucetRelayedV2} from "@predix/shared/faucet/FaucetRelayedV2.sol";

/// @title DeployFaucet
/// @notice Deploys `FaucetRelayedV2` for testnet USDC + optional ETH dispensing.
///         After deploy, the faucet address must be:
///         1. Whitelisted on TestUSDC via `setWhitelistBatch`
///         2. Funded with USDC via `TestUSDC.mint(faucet, amount)`
///
///         Usage:
///           forge script packages/shared/script/DeployFaucet.s.sol:DeployFaucet \
///               --rpc-url $RPC_URL --broadcast
contract DeployFaucet is Script {
    function run() external returns (FaucetRelayedV2 faucet) {
        address usdc = vm.envAddress("USDC_ADDRESS");
        address relayer = vm.envAddress("FAUCET_RELAYER");
        uint256 usdcAmount = vm.envUint("FAUCET_USDC_AMOUNT");
        uint256 ethAmount = vm.envUint("FAUCET_ETH_AMOUNT");
        uint256 cooldownSec = vm.envUint("FAUCET_COOLDOWN_SEC");
        uint256 deployerKey = vm.envUint("DEPLOYER_PRIVATE_KEY");
        address deployer = vm.addr(deployerKey);

        vm.startBroadcast(deployerKey);
        faucet = new FaucetRelayedV2(usdc, relayer, usdcAmount, ethAmount, cooldownSec, deployer);
        vm.stopBroadcast();

        console2.log("============================================================");
        console2.log("FaucetRelayedV2 deployment");
        console2.log("============================================================");
        console2.log("Faucet:      ", address(faucet));
        console2.log("Owner:       ", deployer);
        console2.log("Relayer:     ", relayer);
        console2.log("USDC amount: ", usdcAmount);
        console2.log("ETH amount:  ", ethAmount);
        console2.log("Cooldown:    ", cooldownSec, "seconds");
    }
}
