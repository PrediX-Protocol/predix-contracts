// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Script, console2} from "forge-std/Script.sol";

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IV4Quoter} from "@uniswap/v4-periphery/src/interfaces/IV4Quoter.sol";
import {IAllowanceTransfer} from "permit2/src/interfaces/IAllowanceTransfer.sol";

import {PrediXRouter} from "@predix/router/PrediXRouter.sol";

/// @title DeployRouter
/// @notice Deploys the stateless aggregator `PrediXRouter`. Every dependency address must be
///         deployed beforehand — this script enforces ordering by reading each address from
///         env and rejecting zero. The router's constructor force-approves both the diamond
///         and exchange for USDC.
contract DeployRouter is Script {
    struct Params {
        IPoolManager poolManager;
        address diamond;
        address usdc;
        address hook;
        address exchange;
        IV4Quoter quoter;
        IAllowanceTransfer permit2;
        uint24 lpFeeFlag;
        int24 tickSpacing;
    }

    function run() external returns (address router) {
        Params memory p = Params({
            poolManager: IPoolManager(vm.envAddress("POOL_MANAGER_ADDRESS")),
            diamond: vm.envAddress("DIAMOND_ADDRESS"),
            usdc: vm.envAddress("USDC_ADDRESS"),
            hook: vm.envAddress("HOOK_PROXY_ADDRESS"),
            exchange: vm.envAddress("EXCHANGE_ADDRESS"),
            quoter: IV4Quoter(vm.envAddress("V4_QUOTER_ADDRESS")),
            permit2: IAllowanceTransfer(vm.envAddress("PERMIT2_ADDRESS")),
            lpFeeFlag: uint24(vm.envUint("LP_FEE_FLAG")),
            tickSpacing: int24(vm.envInt("TICK_SPACING"))
        });

        vm.startBroadcast(vm.envUint("DEPLOYER_PRIVATE_KEY"));
        router = _deploy(p);
        vm.stopBroadcast();

        console2.log("PrediXRouter:", router);
    }

    function deploy(Params memory p) external returns (address) {
        return _deploy(p);
    }

    function _deploy(Params memory p) internal returns (address) {
        return address(
            new PrediXRouter(
                p.poolManager, p.diamond, p.usdc, p.hook, p.exchange, p.quoter, p.permit2, p.lpFeeFlag, p.tickSpacing
            )
        );
    }
}
