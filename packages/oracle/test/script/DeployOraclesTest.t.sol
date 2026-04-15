// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";

import {ChainlinkOracle} from "@predix/oracle/adapters/ChainlinkOracle.sol";
import {ManualOracle} from "@predix/oracle/adapters/ManualOracle.sol";

/// @notice Regression guard for the oracle deploy handover. Exercises the exact
///         4-call sequence that `DeployAll._deployOracles` and
///         `DeployOracles._deploy` use so that a re-introduction of the prior bug
///         (grantRole after assigning admin directly to multisig) is caught in CI.
///
///         A prior Unichain Sepolia dry-run reverted with
///         `AccessControlUnauthorizedAccount(deployer, DEFAULT_ADMIN_ROLE)` because
///         the deploy script tried to grant `REPORTER_ROLE` after handing
///         `DEFAULT_ADMIN_ROLE` directly to multisig. The fix keeps the deployer as
///         temporary admin, grants the operational role, then transfers and
///         renounces the admin role — mirrors `DiamondDeployLib.transferGovernance`.
contract DeployOraclesHandoverTest is Test {
    bytes32 internal constant DEFAULT_ADMIN_ROLE = 0x00;

    address internal deployer = makeAddr("deployer");
    address internal multisig = makeAddr("multisig");
    address internal diamond = makeAddr("diamond");
    address internal reporter = makeAddr("reporter");
    address internal registrar = makeAddr("registrar");

    function test_ManualOracle_HandoverSequence() public {
        vm.startPrank(deployer);
        ManualOracle oracle = new ManualOracle(deployer, diamond);
        oracle.grantRole(oracle.REPORTER_ROLE(), reporter);
        oracle.grantRole(DEFAULT_ADMIN_ROLE, multisig);
        oracle.renounceRole(DEFAULT_ADMIN_ROLE, deployer);
        vm.stopPrank();

        assertTrue(oracle.hasRole(DEFAULT_ADMIN_ROLE, multisig), "multisig DEFAULT_ADMIN_ROLE");
        assertFalse(oracle.hasRole(DEFAULT_ADMIN_ROLE, deployer), "deployer renounced DEFAULT_ADMIN_ROLE");
        assertTrue(oracle.hasRole(oracle.REPORTER_ROLE(), reporter), "reporter REPORTER_ROLE");
        assertEq(oracle.diamond(), diamond, "diamond bound");
    }

    function test_ChainlinkOracle_HandoverSequence() public {
        vm.startPrank(deployer);
        ChainlinkOracle oracle = new ChainlinkOracle(deployer, address(0));
        oracle.grantRole(oracle.REGISTRAR_ROLE(), registrar);
        oracle.grantRole(DEFAULT_ADMIN_ROLE, multisig);
        oracle.renounceRole(DEFAULT_ADMIN_ROLE, deployer);
        vm.stopPrank();

        assertTrue(oracle.hasRole(DEFAULT_ADMIN_ROLE, multisig), "multisig DEFAULT_ADMIN_ROLE");
        assertFalse(oracle.hasRole(DEFAULT_ADMIN_ROLE, deployer), "deployer renounced DEFAULT_ADMIN_ROLE");
        assertTrue(oracle.hasRole(oracle.REGISTRAR_ROLE(), registrar), "registrar REGISTRAR_ROLE");
        assertEq(oracle.sequencerUptimeFeed(), address(0), "sequencer feed address(0)");
    }
}
