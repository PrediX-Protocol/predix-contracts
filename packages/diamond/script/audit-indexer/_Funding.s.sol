// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import {AuditBase, ITestUSDCMint} from "./_AuditBase.sol";
import {console2} from "forge-std/Script.sol";

/// @notice Funding script: deployer mints USDC + sends ETH to 6 test wallets
///         (LP HD-9, A HD-10, B HD-11, X HD-12, Y HD-13, Z HD-14).
///         One-shot. Run before any scenario script.
contract Funding is AuditBase {
    function run() external {
        Ctx memory c = _load();

        address lp = vm.addr(c.lpKey);
        address a = vm.addr(c.aKey);
        address b = vm.addr(c.bKey);
        address x = vm.addr(c.xKey);
        address y = vm.addr(c.yKey);
        address z = vm.addr(c.zKey);

        address[6] memory addrs = [lp, a, b, x, y, z];
        // USDC in raw units (6 decimals). LP=600, A=100, B=100, X/Y/Z=50.
        uint256[6] memory usdcAmts = [uint256(600e6), 100e6, 100e6, 50e6, 50e6, 50e6];
        // ETH in wei. Unichain gas price ~1.5e6 wei (~0.0015 gwei) ⇒ 500k-gas tx
        // costs ~7.5e-7 ETH. Even 50 heavy txs ≈ 4e-5 ETH. Allocate with 5×
        // headroom. Deployer ETH balance ~0.00195 ETH (verified 2026-05-23);
        // total funding 0.0008 ETH leaves ~0.0012 ETH for deployer's own
        // resolve/enableRefundMode calls.
        uint256[6] memory ethAmts =
            [uint256(0.0003 ether), 0.0001 ether, 0.0001 ether, 0.0001 ether, 0.0001 ether, 0.0001 ether];

        vm.startBroadcast(c.deployerKey);

        ITestUSDCMint usdcMintable = ITestUSDCMint(c.usdc);
        require(usdcMintable.owner() == vm.addr(c.deployerKey), "deployer is not TestUSDC owner");

        for (uint256 i = 0; i < 6; i++) {
            usdcMintable.mint(addrs[i], usdcAmts[i]);
            (bool ok,) = addrs[i].call{value: ethAmts[i]}("");
            require(ok, "eth send failed");
            console2.log("funded", addrs[i]);
            console2.log("  usdc", usdcAmts[i]);
            console2.log("  eth", ethAmts[i]);
        }

        vm.stopBroadcast();

        console2.log("=== Funding complete ===");
        console2.log("LP HD-9 ", lp);
        console2.log("A  HD-10", a);
        console2.log("B  HD-11", b);
        console2.log("X  HD-12", x);
        console2.log("Y  HD-13", y);
        console2.log("Z  HD-14", z);
    }
}
