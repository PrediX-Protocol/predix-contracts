// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import {DevBase, ITestUSDCMint} from "./_DevBase.sol";
import {console2} from "forge-std/Script.sol";

/// @notice Top up LP wallet with USDC + ETH before creating diverse test markets.
contract Funding is DevBase {
    uint256 internal constant LP_USDC_TOPUP = 600e6; // 600 USDC
    uint256 internal constant LP_ETH_TOPUP = 0.0001 ether;

    function run() external {
        Ctx memory c = _load();
        address lp = vm.addr(c.lpKey);

        vm.startBroadcast(c.deployerKey);
        ITestUSDCMint(c.usdc).mint(lp, LP_USDC_TOPUP);
        (bool ok,) = lp.call{value: LP_ETH_TOPUP}("");
        require(ok, "eth send to LP failed");
        vm.stopBroadcast();

        console2.log("=== Diverse-markets funding complete ===");
        console2.log("LP wallet :", lp);
        console2.log("USDC top-up:", LP_USDC_TOPUP);
        console2.log("ETH top-up :", LP_ETH_TOPUP);
    }
}
