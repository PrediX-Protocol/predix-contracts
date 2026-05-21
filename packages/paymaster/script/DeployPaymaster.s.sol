// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import {Script, console2} from "forge-std/Script.sol";
import {IEntryPoint} from "@account-abstraction/contracts/interfaces/IEntryPoint.sol";

import {PrediXPaymaster} from "../src/PrediXPaymaster.sol";

/// @title DeployPaymaster
/// @notice One-shot deploy + funding + staking of PrediXPaymaster.
/// @dev Reads required env (fail-loud via vm.envAddress / vm.envUint — no defaults):
///        ENTRY_POINT_V07, PAYMASTER_OWNER, PAYMASTER_INITIAL_SIGNER,
///        MNEMONIC or DEPLOYER_PRIVATE_KEY, PAYMASTER_STAKE_WEI,
///        PAYMASTER_UNSTAKE_DELAY_SEC.
///      Staking is MANDATORY: `_validatePaymasterUserOp` reads the paymaster's
///      own storage (signer / paused / allowlist), which ERC-7562 only permits
///      for a STAKED entity. An unstaked paymaster is rejected by every
///      compliant bundler, so the gasless feature would silently fail.
contract DeployPaymaster is Script {
    function run() external returns (PrediXPaymaster paymaster) {
        address entryPoint = vm.envAddress("ENTRY_POINT_V07");
        address ownerAddr = vm.envAddress("PAYMASTER_OWNER");
        address signerAddr = vm.envAddress("PAYMASTER_INITIAL_SIGNER");
        // Deployer key resolution mirrors DeployAll / DeployMarketFactory:
        // MNEMONIC (BIP-44 index 0) takes precedence over DEPLOYER_PRIVATE_KEY.
        uint256 deployerKey;
        string memory mnemonic = vm.envOr("MNEMONIC", string(""));
        if (bytes(mnemonic).length > 0) {
            deployerKey = vm.deriveKey(mnemonic, 0);
        } else {
            deployerKey = vm.envUint("DEPLOYER_PRIVATE_KEY");
        }
        uint256 stakeWei = vm.envUint("PAYMASTER_STAKE_WEI");
        uint256 unstakeDelaySec = vm.envUint("PAYMASTER_UNSTAKE_DELAY_SEC");

        require(unstakeDelaySec <= type(uint32).max, "unstake delay > uint32");

        address deployer = vm.addr(deployerKey);

        console2.log("=== PrediXPaymaster deploy ===");
        console2.log("chainId:    ", block.chainid);
        console2.log("EntryPoint: ", entryPoint);
        console2.log("Owner:      ", ownerAddr);
        console2.log("Signer:     ", signerAddr);
        console2.log("Stake wei:  ", stakeWei);
        console2.log("Unstake sec:", unstakeDelaySec);

        vm.startBroadcast(deployerKey);

        paymaster = new PrediXPaymaster(IEntryPoint(entryPoint), ownerAddr, signerAddr);
        paymaster.deposit{value: 0.001 ether}();

        // `addStake` is onlyOwner. Stake in-script only when the broadcasting
        // deployer is also the owner (single-key deploy). With a multisig owner
        // the owner MUST run `addStake` post-deploy — until then, compliant
        // bundlers reject every sponsored UserOp because validation touches the
        // paymaster's own storage (ERC-7562 staked-entity rule).
        if (ownerAddr == deployer) {
            paymaster.addStake{value: stakeWei}(uint32(unstakeDelaySec));
            console2.log("Staked in-script (deployer == owner).");
        } else {
            console2.log("!! NOT STAKED: owner != deployer.");
            console2.log("!! Owner MUST call addStake{value: PAYMASTER_STAKE_WEI}(PAYMASTER_UNSTAKE_DELAY_SEC)");
            console2.log("!! before enabling gasless, or bundlers reject every sponsored UserOp.");
        }

        vm.stopBroadcast();

        console2.log("Paymaster:  ", address(paymaster));
        console2.log("Deposit:    ", paymaster.getDeposit());
    }
}
