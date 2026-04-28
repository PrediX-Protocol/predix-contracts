// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Script, console2} from "forge-std/Script.sol";

import {PrediXExchange} from "@predix/exchange/PrediXExchange.sol";

/// @title DeployExchange
/// @notice Deploys `PrediXExchange` — a standalone CLOB contract that reads from the diamond
///         via interface. No post-deploy wiring is required; the constructor force-approves
///         the diamond for USDC internally.
contract DeployExchange is Script {
    function run() external returns (address exchange) {
        address diamond = vm.envAddress("DIAMOND_ADDRESS");
        address usdc = vm.envAddress("USDC_ADDRESS");
        address feeRecipient = vm.envAddress("FEE_RECIPIENT");

        vm.startBroadcast(vm.envUint("DEPLOYER_PRIVATE_KEY"));
        exchange = _deploy(diamond, usdc, feeRecipient);
        vm.stopBroadcast();

        console2.log("PrediXExchange:", exchange);
    }

    function deploy(address diamond, address usdc, address feeRecipient) external returns (address) {
        return _deploy(diamond, usdc, feeRecipient);
    }

    function _deploy(address diamond, address usdc, address feeRecipient) internal returns (address) {
        PrediXExchange impl = new PrediXExchange();
        impl.initialize(diamond, usdc, feeRecipient);
        return address(impl);
    }
}
