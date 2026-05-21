// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import {Test} from "forge-std/Test.sol";

import {IManualOracle} from "@predix/oracle/interfaces/IManualOracle.sol";
import {ManualOracle} from "@predix/oracle/adapters/ManualOracle.sol";
import {IChainlinkOracle} from "@predix/oracle/interfaces/IChainlinkOracle.sol";
import {ChainlinkOracle} from "@predix/oracle/adapters/ChainlinkOracle.sol";

/// @notice Pins the oracle last-admin guard: the standalone OZ-AccessControl
///         oracles cannot have their FINAL `DEFAULT_ADMIN_ROLE` holder removed (via
///         either `revoke` or `renounce`). Emptying the admin set is
///         irrecoverable — no `REPORTER_ROLE`/`REGISTRAR_ROLE` could ever be
///         granted again. Mirrors the diamond AccessControlFacet last-admin
///         guard, which vanilla OZ `AccessControl` lacks. The two-admin path
///         (grant a successor, then renounce/revoke the original) — the exact
///         deploy-handover sequence — must still succeed.
contract OracleLastAdminGuardTest is Test {
    bytes32 internal constant DEFAULT_ADMIN_ROLE = 0x00;

    address internal admin = makeAddr("admin");
    address internal admin2 = makeAddr("admin2");
    address internal diamond = makeAddr("diamond");

    ManualOracle internal manual;
    ChainlinkOracle internal chainlink;

    function setUp() public {
        manual = new ManualOracle(admin, diamond);
        chainlink = new ChainlinkOracle(admin, address(0), diamond);
    }

    // ── ManualOracle: last admin is protected ───────────────────────────

    function test_Revert_Manual_RenounceLastAdmin() public {
        vm.prank(admin);
        vm.expectRevert(IManualOracle.ManualOracle_LastAdmin.selector);
        manual.renounceRole(DEFAULT_ADMIN_ROLE, admin);
    }

    function test_Revert_Manual_RevokeLastAdmin() public {
        vm.prank(admin);
        vm.expectRevert(IManualOracle.ManualOracle_LastAdmin.selector);
        manual.revokeRole(DEFAULT_ADMIN_ROLE, admin);
    }

    // ── ManualOracle: two-admin paths still work ────────────────────────

    function test_Manual_RenounceAllowedWithSecondAdmin() public {
        vm.startPrank(admin);
        manual.grantRole(DEFAULT_ADMIN_ROLE, admin2);
        manual.renounceRole(DEFAULT_ADMIN_ROLE, admin);
        vm.stopPrank();

        assertFalse(manual.hasRole(DEFAULT_ADMIN_ROLE, admin), "original admin renounced");
        assertTrue(manual.hasRole(DEFAULT_ADMIN_ROLE, admin2), "successor retains admin");

        // admin2 is now the last admin — protected again.
        vm.prank(admin2);
        vm.expectRevert(IManualOracle.ManualOracle_LastAdmin.selector);
        manual.renounceRole(DEFAULT_ADMIN_ROLE, admin2);
    }

    function test_Manual_RevokeAllowedWithSecondAdmin() public {
        vm.prank(admin);
        manual.grantRole(DEFAULT_ADMIN_ROLE, admin2);

        vm.prank(admin2);
        manual.revokeRole(DEFAULT_ADMIN_ROLE, admin);

        assertFalse(manual.hasRole(DEFAULT_ADMIN_ROLE, admin), "original admin revoked");
        assertTrue(manual.hasRole(DEFAULT_ADMIN_ROLE, admin2), "successor retains admin");
    }

    function test_Manual_RevokeNonAdminRoleUnaffected() public {
        bytes32 reporterRole = manual.REPORTER_ROLE();
        address reporter = makeAddr("reporter");

        vm.startPrank(admin);
        manual.grantRole(reporterRole, reporter);
        // Non-admin role: the last-admin guard must not interfere even though
        // there is only a single DEFAULT_ADMIN_ROLE holder.
        manual.revokeRole(reporterRole, reporter);
        vm.stopPrank();

        assertFalse(manual.hasRole(reporterRole, reporter), "reporter revoked normally");
        assertTrue(manual.hasRole(DEFAULT_ADMIN_ROLE, admin), "admin untouched");
    }

    // ── ChainlinkOracle: last admin is protected ────────────────────────

    function test_Revert_Chainlink_RenounceLastAdmin() public {
        vm.prank(admin);
        vm.expectRevert(IChainlinkOracle.ChainlinkOracle_LastAdmin.selector);
        chainlink.renounceRole(DEFAULT_ADMIN_ROLE, admin);
    }

    function test_Revert_Chainlink_RevokeLastAdmin() public {
        vm.prank(admin);
        vm.expectRevert(IChainlinkOracle.ChainlinkOracle_LastAdmin.selector);
        chainlink.revokeRole(DEFAULT_ADMIN_ROLE, admin);
    }

    // ── ChainlinkOracle: full deploy-handover sequence ──────────────────

    function test_Chainlink_HandoverSequence_LeavesExactlyOneAdmin() public {
        address registrar = makeAddr("registrar");

        // Mirror DeployOracles: grant the operational role, hand admin to the
        // successor, then renounce the deployer.
        vm.startPrank(admin);
        chainlink.grantRole(chainlink.REGISTRAR_ROLE(), registrar);
        chainlink.grantRole(DEFAULT_ADMIN_ROLE, admin2);
        chainlink.renounceRole(DEFAULT_ADMIN_ROLE, admin);
        vm.stopPrank();

        assertFalse(chainlink.hasRole(DEFAULT_ADMIN_ROLE, admin), "deployer renounced");
        assertTrue(chainlink.hasRole(DEFAULT_ADMIN_ROLE, admin2), "successor is admin");
        assertTrue(chainlink.hasRole(chainlink.REGISTRAR_ROLE(), registrar), "registrar set");

        // Successor is the last admin — protected.
        vm.prank(admin2);
        vm.expectRevert(IChainlinkOracle.ChainlinkOracle_LastAdmin.selector);
        chainlink.renounceRole(DEFAULT_ADMIN_ROLE, admin2);
    }
}
