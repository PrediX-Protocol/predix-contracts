// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Script, console2} from "forge-std/Script.sol";

import {PrediXExchange} from "@predix/exchange/PrediXExchange.sol";
import {PrediXExchangeProxy} from "@predix/exchange/PrediXExchangeProxy.sol";

/// @title DeployExchange
/// @notice Deploys `PrediXExchange` (implementation) behind a `PrediXExchangeProxy`
///         (ERC-1967 style, 48h timelocked upgrades). The proxy constructor atomically
///         delegatecalls `initialize(diamond, usdc, feeRecipient)` so state lives in
///         the proxy's storage context from block zero.
contract DeployExchange is Script {
    function run() external returns (address impl, address proxy) {
        address diamond = vm.envAddress("DIAMOND_ADDRESS");
        address usdc = vm.envAddress("USDC_ADDRESS");
        address feeRecipient = vm.envAddress("FEE_RECIPIENT");
        address proxyAdmin = vm.envAddress("EXCHANGE_PROXY_ADMIN");

        vm.startBroadcast(vm.envUint("DEPLOYER_PRIVATE_KEY"));
        (impl, proxy) = _deploy(diamond, usdc, feeRecipient, proxyAdmin);
        vm.stopBroadcast();

        console2.log("Exchange impl: ", impl);
        console2.log("Exchange proxy:", proxy);
    }

    function deploy(address diamond, address usdc, address feeRecipient, address proxyAdmin)
        external
        returns (address impl, address proxy)
    {
        return _deploy(diamond, usdc, feeRecipient, proxyAdmin);
    }

    function _deploy(address diamond, address usdc, address feeRecipient, address proxyAdmin)
        internal
        returns (address impl, address proxy)
    {
        impl = address(new PrediXExchange());
        proxy = address(new PrediXExchangeProxy(impl, proxyAdmin, diamond, usdc, feeRecipient));
    }
}
