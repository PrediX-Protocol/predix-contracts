// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";

import {IManualOracle} from "@predix/oracle/interfaces/IManualOracle.sol";
import {ManualOracle} from "@predix/oracle/adapters/ManualOracle.sol";

import {MockDiamondStatus} from "../mocks/MockDiamondStatus.sol";

/// @notice Regression for FINAL-H10:
///         (a) `report` must reject pre-`endTime` publications so reporters
///             cannot race `resolveMarket`.
///         (b) `revoke` must tombstone the slot so a re-`report` with the
///             opposite outcome is impossible.
contract FinalH10_ReportBeforeEnd is Test {
    ManualOracle internal oracleContract;
    MockDiamondStatus internal diamond;

    address internal admin = makeAddr("admin");
    address internal reporter = makeAddr("reporter");

    uint256 internal constant MARKET_ID = 42;
    uint256 internal constant END_TIME = 1_800_000_000;

    function setUp() public {
        diamond = new MockDiamondStatus();
        diamond.setEndTime(MARKET_ID, END_TIME);

        oracleContract = new ManualOracle(admin, address(diamond));
        bytes32 reporterRole = oracleContract.REPORTER_ROLE();
        vm.prank(admin);
        oracleContract.grantRole(reporterRole, reporter);
    }

    function test_Revert_Report_BeforeMarketEnd() public {
        vm.warp(END_TIME - 1);

        vm.expectRevert(IManualOracle.ManualOracle_BeforeMarketEnd.selector);
        vm.prank(reporter);
        oracleContract.report(MARKET_ID, true);
    }

    function test_Report_AtEndTime_Succeeds() public {
        vm.warp(END_TIME);

        vm.prank(reporter);
        oracleContract.report(MARKET_ID, true);

        assertTrue(oracleContract.isResolved(MARKET_ID));
        assertTrue(oracleContract.outcome(MARKET_ID));
    }

    function test_Revert_Report_AfterRevoke_Frozen() public {
        vm.warp(END_TIME);

        vm.prank(reporter);
        oracleContract.report(MARKET_ID, true);

        vm.prank(admin);
        oracleContract.revoke(MARKET_ID);

        assertFalse(oracleContract.isResolved(MARKET_ID));

        vm.expectRevert(IManualOracle.ManualOracle_Frozen.selector);
        vm.prank(reporter);
        oracleContract.report(MARKET_ID, false);
    }

    function test_Revert_Constructor_ZeroDiamond() public {
        vm.expectRevert(IManualOracle.ManualOracle_ZeroDiamond.selector);
        new ManualOracle(admin, address(0));
    }
}
