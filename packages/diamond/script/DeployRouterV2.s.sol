// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import {Script, console2} from "forge-std/Script.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IV4Quoter} from "@uniswap/v4-periphery/src/interfaces/IV4Quoter.sol";
import {IAllowanceTransfer} from "permit2/src/interfaces/IAllowanceTransfer.sol";
import {LPFeeLibrary} from "@uniswap/v4-core/src/libraries/LPFeeLibrary.sol";
import {IBuilderRegistry} from "@predix/shared/interfaces/IBuilderRegistry.sol";
import {PrediXRouter} from "@predix/router/PrediXRouter.sol";

/// @notice Deploy the new (Sub-plan 04) PrediXRouter with the +builderRegistry ctor arg (10th, appended last)
///         + the +bytes32 builder entries. Router is NOT upgradeable -> REDEPLOY; the OLD router stays live
///         for migration, FE/indexer repoint to this address.
/// @dev Sub-plan 05 Task 1 Step 4. Local/fork DRY-RUN only — run WITHOUT `--broadcast`. builderRegistry comes
///      from the Step 1 deploy (BUILDER_REGISTRY_ADDRESS); the ctor takes it as IBuilderRegistry (verified
///      against PrediXRouter.constructor: it is the 10th arg).
contract DeployRouterV2 is Script {
    int24 internal constant TICK_SPACING = 60;

    function run() external returns (address router) {
        address poolManager = vm.envAddress("POOL_MANAGER_ADDRESS");
        address diamond = vm.envOr("DIAMOND_ADDRESS", 0xC8F12AF2a396c9C906ac36Bc0AC2279BBb69Ef96);
        address usdc = vm.envAddress("USDC_ADDRESS");
        address hook = vm.envAddress("HOOK_PROXY_ADDRESS");
        address exchange = vm.envOr("EXCHANGE_ADDRESS", 0x506367C7c48C95A4843F45d5C2F177B35e69594E);
        address quoter = vm.envAddress("V4_QUOTER_ADDRESS");
        address permit2 = vm.envAddress("PERMIT2_ADDRESS");
        address builderRegistry = vm.envAddress("BUILDER_REGISTRY_ADDRESS"); // from Task 1 Step 1 deploy

        uint256 key = _deployerKey();
        vm.startBroadcast(key);
        router = address(
            new PrediXRouter(
                IPoolManager(poolManager),
                diamond,
                usdc,
                hook,
                exchange,
                IV4Quoter(quoter),
                IAllowanceTransfer(permit2),
                LPFeeLibrary.DYNAMIC_FEE_FLAG,
                TICK_SPACING,
                IBuilderRegistry(builderRegistry) // NEW Sub-plan 04 arg (10th, appended)
            )
        );
        vm.stopBroadcast();
        console2.log("new PrediXRouter:", router);
        console2.log("  builderRegistry:", builderRegistry);
        console2.log("  exchange       :", exchange);
        console2.log("  diamond        :", diamond);
    }

    function _deployerKey() internal view returns (uint256) {
        string memory m = vm.envOr("MNEMONIC", string(""));
        return bytes(m).length > 0 ? vm.deriveKey(m, 0) : vm.envUint("DEPLOYER_PRIVATE_KEY");
    }
}
