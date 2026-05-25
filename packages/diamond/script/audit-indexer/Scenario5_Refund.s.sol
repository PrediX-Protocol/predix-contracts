// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import {AuditBase} from "./_AuditBase.sol";
import {console2} from "forge-std/Script.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IMarketFacet} from "@predix/shared/interfaces/IMarketFacet.sol";
import {IAccessControlFacet} from "@predix/shared/interfaces/IAccessControlFacet.sol";

/// @notice Scenario 5 refund — runs AFTER:
///         (a) Scenario5_Setup completed
///         (b) market endTime elapsed
///         (c) Safe executed `grantRole(ADMIN_ROLE, deployer)` on diamond
///
///         Deployer (now temporary ADMIN) enables refund mode. Trader A then
///         burns matched yes+no pair via refund to recover collateral.
///         Requires `S5_MARKET_ID` env var.
///
///         After this script completes, immediately submit Safe tx to
///         `revokeRole(ADMIN_ROLE, deployer)` to close the temporary
///         elevation window.
contract Scenario5_Refund is AuditBase {
    bytes32 internal constant ADMIN_ROLE = keccak256("predix.role.admin");
    uint256 internal constant REFUND_AMOUNT = 10e6;

    function run() external {
        Ctx memory c = _load();
        uint256 marketId = vm.envUint("S5_MARKET_ID");
        address deployer = vm.addr(c.deployerKey);
        address a = vm.addr(c.aKey);

        // Pre-flight: deployer must hold ADMIN_ROLE (granted via Safe tx)
        bool hasAdmin = IAccessControlFacet(c.diamond).hasRole(ADMIN_ROLE, deployer);
        require(hasAdmin, "deployer lacks ADMIN_ROLE - Safe must grantRole first");

        vm.startBroadcast(c.deployerKey);
        IMarketFacet(c.diamond).enableRefundMode(marketId);
        vm.stopBroadcast();

        // Trader A refunds matched pair (10 yes + 10 no for 10 USDC back)
        vm.startBroadcast(c.aKey);
        IMarketFacet(c.diamond).refund(marketId, REFUND_AMOUNT, REFUND_AMOUNT);
        vm.stopBroadcast();

        console2.log("=== Scenario 5 refund complete ===");
        console2.log("marketId     :", marketId);
        console2.log("refundAmount :", REFUND_AMOUNT);
        console2.log("ACTION: Submit Safe tx to revokeRole(ADMIN_ROLE, deployer)");
    }
}
