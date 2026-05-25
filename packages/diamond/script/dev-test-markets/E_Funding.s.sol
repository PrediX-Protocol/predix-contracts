// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import {DevBase, ITestUSDCMint} from "./_DevBase.sol";
import {console2} from "forge-std/Script.sol";

/// @notice Top up LP + creator USDC for 2 multi-outcome event variants.
contract E_Funding is DevBase {
    uint256 internal constant LP_USDC_TOPUP = 500e6;
    uint256 internal constant CREATOR_USDC_TOPUP = 50e6;

    function run() external {
        Ctx memory c = _load();
        address lp = vm.addr(c.lpKey);
        address creator = vm.addr(c.creatorKey);

        vm.startBroadcast(c.deployerKey);
        ITestUSDCMint(c.usdc).mint(lp, LP_USDC_TOPUP);
        ITestUSDCMint(c.usdc).mint(creator, CREATOR_USDC_TOPUP);
        vm.stopBroadcast();

        console2.log("=== Event funding complete ===");
        console2.log("LP +USDC      :", LP_USDC_TOPUP);
        console2.log("creator +USDC :", CREATOR_USDC_TOPUP);
    }
}
