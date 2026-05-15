// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import {Script, console2} from "forge-std/Script.sol";

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";

import {PrediXMarketFactory} from "@predix/router/PrediXMarketFactory.sol";

/// @title DeployMarketFactory
/// @notice Deploys `PrediXMarketFactory` — batches market creation + AMM pool setup
///         into a single transaction for operational convenience.
///
///         Prerequisites:
///         - All core contracts deployed (Diamond, Hook, Exchange, Router)
///         - `LP_TEST_ADDRESS` set — a PoolModifyLiquidityTest instance (v4-core test
///           utility) must be deployed beforehand. See script/README.md for instructions.
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
        address lpTest = vm.envAddress("LP_TEST_ADDRESS");
        uint24 lpFeeFlag = uint24(vm.envUint("LP_FEE_FLAG"));
        int24 tickSpacing = int24(vm.envInt("TICK_SPACING"));

        vm.startBroadcast(vm.envUint("DEPLOYER_PRIVATE_KEY"));
        factory = address(new PrediXMarketFactory(poolManager, diamond, usdc, hook, lpTest, lpFeeFlag, tickSpacing));
        vm.stopBroadcast();

        console2.log("============================================================");
        console2.log("PrediXMarketFactory deployment");
        console2.log("============================================================");
        console2.log("MarketFactory:", factory);
        console2.log("Diamond:     ", diamond);
        console2.log("Hook:        ", hook);
        console2.log("LP Test:     ", lpTest);
        console2.log("LP Fee:      ", uint256(lpFeeFlag));
        console2.log("Tick Spacing:", int256(tickSpacing));
    }
}
