// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import {Script, console2} from "forge-std/Script.sol";

/// @title DeriveAccountsFromMnemonic
/// @notice Prints the first N addresses derived from `MNEMONIC` along the
///         standard BIP-44 Ethereum path `m/44'/60'/0'/0/{i}`. Run once
///         locally, import the same mnemonic into Metamask, and rename each
///         account to the suggested role label so the on-call surface is
///         self-documenting.
///
///         The script reads only env and computes addresses off-chain --it
///         does not open a broadcast scope, send transactions, or touch any
///         RPC. Safe to run anywhere the mnemonic is already in scope.
///
///         Usage:
///             MNEMONIC="word1 word2 ..." forge script DeriveAccountsFromMnemonic
///
///         Optional env:
///             MNEMONIC_COUNT  (default 8) --number of indices to print.
///
///         The suggested labels match the dev-beta deploy env layout in
///         `.env.dev-beta.example`. Production deploys with the four-Safe
///         model bind these roles to multisigs, not to mnemonic-derived
///         EOAs --see `KEY_MANAGEMENT_POLICY.md`.
contract DeriveAccountsFromMnemonic is Script {
    struct Slot {
        uint32 index;
        string label;
        string description;
    }

    function run() external view {
        string memory mnemonic = vm.envString("MNEMONIC");
        uint256 count = vm.envOr("MNEMONIC_COUNT", uint256(8));

        Slot[8] memory defaults = [
            Slot({index: 0, label: "deployer", description: "DEPLOYER_PRIVATE_KEY --runs DeployAll, renounces in-broadcast"}),
            Slot({index: 1, label: "team-safe-owner-1", description: "Suggested owner #1 for the team Safe (MULTISIG_ADDRESS)"}),
            Slot({index: 2, label: "team-safe-owner-2", description: "Suggested owner #2 for the team Safe"}),
            Slot({index: 3, label: "team-safe-owner-3", description: "Suggested owner #3 for the team Safe"}),
            Slot({index: 4, label: "pauser", description: "PAUSER_ADDRESS --hot wallet for emergency pause"}),
            Slot({index: 5, label: "fee-recipient", description: "FEE_RECIPIENT --receives creation + redemption fees"}),
            Slot({index: 6, label: "creator", description: "CREATOR_ROLE backend wallet (post-deploy role grant)"}),
            Slot({index: 7, label: "reporter", description: "REPORTER_ROLE on ManualOracle (post-deploy role grant)"})
        ];

        console2.log("============================================================");
        console2.log("Mnemonic-derived accounts (BIP-44 m/44'/60'/0'/0/{i})");
        console2.log("============================================================");
        console2.log("Import the mnemonic into Metamask, then rename each account");
        console2.log("to the label below for clear ops segregation.");
        console2.log("");

        uint256 toPrint = count < defaults.length ? count : defaults.length;
        for (uint256 i = 0; i < toPrint; ++i) {
            uint256 key = vm.deriveKey(mnemonic, defaults[i].index);
            address addr = vm.addr(key);
            console2.log("--------------------------------------------------------");
            console2.log("Index:      ", defaults[i].index);
            console2.log("Label:      ", defaults[i].label);
            console2.log("Address:    ", addr);
            console2.log("Purpose:    ", defaults[i].description);
        }

        // Print any additional indices the operator asked for beyond the
        // labelled defaults. These have no suggested role; useful when
        // generating spare hot wallets.
        for (uint256 i = defaults.length; i < count; ++i) {
            uint256 key = vm.deriveKey(mnemonic, uint32(i));
            address addr = vm.addr(key);
            console2.log("--------------------------------------------------------");
            console2.log("Index:      ", i);
            console2.log("Label:      ", "spare");
            console2.log("Address:    ", addr);
        }

        console2.log("============================================================");
    }
}
