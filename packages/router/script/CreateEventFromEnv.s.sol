// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import {Script, console2} from "forge-std/Script.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {PrediXMarketFactory} from "@predix/router/PrediXMarketFactory.sol";

/// @notice One-shot script: create a single event (with N child markets) from env.
/// @dev    Reads from env:
///           - EVENT_NAME            (string)
///           - EVENT_CANDIDATES      (string with '|' delimiter, e.g. "A|B|C")
///           - EVENT_END_OFFSET_SEC  (uint, default 7200)
///           - MNEMONIC              (mnemonic for HD-6 creator EOA)
///           - MARKET_FACTORY_ADDRESS, ORACLE_MANUAL_ADDRESS, USDC_ADDRESS
///         Broadcasts via HD-6 (must have CREATOR_ROLE on Diamond).
contract CreateEventFromEnv is Script {
    function run() external {
        address factory = vm.envAddress("MARKET_FACTORY_ADDRESS");
        address oracle = vm.envAddress("ORACLE_MANUAL_ADDRESS");
        address usdc = vm.envAddress("USDC_ADDRESS");

        string memory name = vm.envString("EVENT_NAME");
        string[] memory candidates = vm.envString("EVENT_CANDIDATES", "|");
        uint256 endOffset = vm.envOr("EVENT_END_OFFSET_SEC", uint256(7200));
        uint256 endTime = block.timestamp + endOffset;
        uint256 budget = candidates.length * 11_000_000; // 11 USDC per child

        string memory mnemonic = vm.envString("MNEMONIC");
        uint256 pk = vm.deriveKey(mnemonic, 6); // HD-6 creator

        console2.log("=== CreateEventFromEnv ===");
        console2.log("name:        ", name);
        console2.log("candidates:  ", candidates.length);
        console2.log("endTime:     ", endTime);
        console2.log("budget USDC: ", budget / 1_000_000);

        vm.startBroadcast(pk);

        // Ensure approval (idempotent — sets max if not yet)
        if (IERC20(usdc).allowance(vm.addr(pk), factory) < budget) {
            IERC20(usdc).approve(factory, type(uint256).max);
        }

        (uint256 eventId, uint256[] memory marketIds) =
            PrediXMarketFactory(factory).createEventWithPools(name, candidates, endTime, oracle, budget);

        vm.stopBroadcast();

        console2.log("---");
        console2.log("eventId:", eventId);
        for (uint256 i; i < marketIds.length; ++i) {
            console2.log("  child marketId:", marketIds[i]);
        }

        // Machine-parseable
        string memory ids = "[";
        for (uint256 i; i < marketIds.length; ++i) {
            ids = string.concat(ids, vm.toString(marketIds[i]));
            if (i + 1 < marketIds.length) ids = string.concat(ids, ",");
        }
        ids = string.concat(ids, "]");
        console2.log(string.concat("RESULT_JSON={\"eventId\":", vm.toString(eventId), ",\"marketIds\":", ids, "}"));
    }
}
