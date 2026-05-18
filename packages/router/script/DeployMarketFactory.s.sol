// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import {Script, console2} from "forge-std/Script.sol";

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";

import {PrediXMarketFactory} from "@predix/router/PrediXMarketFactory.sol";

/// @title DeployMarketFactory
/// @notice Deploys `PrediXMarketFactory` — atomically creates markets +
///         registers + initializes the v4 pool with the canonical PrediX
///         hook binding. Liquidity provisioning is a separate user step
///         against the v4 PositionManager — see SECURITY.md and the README
///         for the full mainnet flow.
///
///         Prerequisites:
///         - All core contracts deployed (Diamond, Hook, Exchange, Router)
///         - `POOL_MANAGER_ADDRESS`, `DIAMOND_ADDRESS`, `USDC_ADDRESS`,
///           `HOOK_PROXY_ADDRESS`, `LP_FEE_FLAG`, `TICK_SPACING` set in env.
///
///         After deploy, the factory address must be:
///         1. Granted `CREATOR_ROLE` on Diamond
///         2. Whitelisted on TestUSDC (if using restricted USDC)
///
///         Usage:
///           forge script packages/router/script/DeployMarketFactory.s.sol:DeployMarketFactory \
///               --rpc-url $RPC_URL --broadcast
contract DeployMarketFactory is Script {
    function run() external returns (address factory) {
        IPoolManager poolManager = IPoolManager(vm.envAddress("POOL_MANAGER_ADDRESS"));
        address diamond = vm.envAddress("DIAMOND_ADDRESS");
        address usdc = vm.envAddress("USDC_ADDRESS");
        address hook = vm.envAddress("HOOK_PROXY_ADDRESS");
        uint24 lpFeeFlag = uint24(vm.envUint("LP_FEE_FLAG"));
        int24 tickSpacing = int24(vm.envInt("TICK_SPACING"));

        vm.startBroadcast(vm.envUint("DEPLOYER_PRIVATE_KEY"));
        factory = address(new PrediXMarketFactory(poolManager, diamond, usdc, hook, lpFeeFlag, tickSpacing));
        vm.stopBroadcast();

        console2.log("============================================================");
        console2.log("PrediXMarketFactory deployment");
        console2.log("============================================================");
        console2.log("MarketFactory:", factory);
        console2.log("Diamond:     ", diamond);
        console2.log("Hook:        ", hook);
        console2.log("LP Fee:      ", uint256(lpFeeFlag));
        console2.log("Tick Spacing:", int256(tickSpacing));
        console2.log("");
        console2.log("Liquidity provisioning is now a downstream step against the");
        console2.log("canonical v4 PositionManager (see SECURITY.md). The factory");
        console2.log("only batches createMarket + registerMarketPool + initialize.");
    }
}
