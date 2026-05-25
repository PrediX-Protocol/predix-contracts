// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import {AuditBase, ITestUSDCMint} from "./_AuditBase.sol";
import {console2} from "forge-std/Script.sol";

/// @notice Round 2 funding. Tops up LP for the 2 new markets (S8+S9), then
///         funds three fresh test EOAs:
///           HD-17 M — mixed Router + direct-Exchange
///           HD-18 N — direct-Exchange buy + sell same market
///           HD-19 P — ERC20-transfer recipient (gas only)
///         All from deployer (TestUSDC owner) in one broadcast.
contract Round2_Funding is AuditBase {
    uint256 internal constant LP_TOP_UP = 250e6;
    uint256 internal constant M_USDC = 20e6;
    uint256 internal constant N_USDC = 20e6;
    uint256 internal constant TRADER_ETH = 0.00005 ether;

    function run() external {
        Ctx memory c = _load();
        string memory mnemonic = vm.envString("MNEMONIC");
        address m = vm.addr(vm.deriveKey(mnemonic, 17));
        address n = vm.addr(vm.deriveKey(mnemonic, 18));
        address p = vm.addr(vm.deriveKey(mnemonic, 19));
        address lp = vm.addr(c.lpKey);

        vm.startBroadcast(c.deployerKey);
        ITestUSDCMint(c.usdc).mint(lp, LP_TOP_UP);
        ITestUSDCMint(c.usdc).mint(m, M_USDC);
        ITestUSDCMint(c.usdc).mint(n, N_USDC);
        (bool okM,) = m.call{value: TRADER_ETH}("");
        require(okM, "eth send to M failed");
        (bool okN,) = n.call{value: TRADER_ETH}("");
        require(okN, "eth send to N failed");
        (bool okP,) = p.call{value: TRADER_ETH}("");
        require(okP, "eth send to P failed");
        vm.stopBroadcast();

        console2.log("=== Round 2 funding complete ===");
        console2.log("LP +USDC:", LP_TOP_UP);
        console2.log("M HD-17:", m);
        console2.log("N HD-18:", n);
        console2.log("P HD-19:", p);
    }
}
