// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";

import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";

import {IManualOracle} from "@predix/oracle/interfaces/IManualOracle.sol";
import {ManualOracle} from "@predix/oracle/adapters/ManualOracle.sol";

import {MockDiamondStatus} from "../mocks/MockDiamondStatus.sol";

contract ManualOracleTest is Test {
    ManualOracle internal oracleContract;
    MockDiamondStatus internal diamond;

    address internal admin = makeAddr("admin");
    address internal reporter = makeAddr("reporter");
    address internal stranger = makeAddr("stranger");

    uint256 internal constant MARKET_ID = 42;
    uint256 internal constant END_TIME = 1_700_000_000;

    function setUp() public {
        diamond = new MockDiamondStatus();
        oracleContract = new ManualOracle(admin, address(diamond));
        bytes32 reporterRole = oracleContract.REPORTER_ROLE();
        vm.prank(admin);
        oracleContract.grantRole(reporterRole, reporter);

        // Default: every market id used by these tests is past its end time.
        vm.warp(END_TIME);
    }

    function _setMarketEnded(uint256 marketId) internal {
        diamond.setEndTime(marketId, END_TIME);
    }

    // -------------------------------------------------------------------
    // Constructor
    // -------------------------------------------------------------------

    function test_Constructor_GrantsAdmin() public view {
        assertTrue(oracleContract.hasRole(oracleContract.DEFAULT_ADMIN_ROLE(), admin));
    }

    function test_Revert_Constructor_ZeroAdmin() public {
        vm.expectRevert(IManualOracle.ManualOracle_ZeroAdmin.selector);
        new ManualOracle(address(0), address(diamond));
    }

    function test_Revert_Constructor_ZeroDiamond() public {
        vm.expectRevert(IManualOracle.ManualOracle_ZeroDiamond.selector);
        new ManualOracle(admin, address(0));
    }

    function test_Constructor_StoresDiamond() public view {
        assertEq(oracleContract.diamond(), address(diamond));
    }

    // -------------------------------------------------------------------
    // report
    // -------------------------------------------------------------------

    function test_Report_HappyPath() public {
        vm.expectEmit(true, true, true, true);
        emit IManualOracle.OutcomeReported(MARKET_ID, true, reporter);

        vm.prank(reporter);
        oracleContract.report(MARKET_ID, true);

        assertTrue(oracleContract.isResolved(MARKET_ID));
        assertTrue(oracleContract.outcome(MARKET_ID));
    }

    function test_Report_StoresAllFields() public {
        vm.prank(reporter);
        oracleContract.report(MARKET_ID, false);

        assertTrue(oracleContract.isResolved(MARKET_ID));
        assertFalse(oracleContract.outcome(MARKET_ID));
        assertEq(oracleContract.reportedAt(MARKET_ID), uint64(block.timestamp));
        assertEq(oracleContract.reporterOf(MARKET_ID), reporter);
    }

    function test_Outcome_ReturnsStored_True() public {
        vm.prank(reporter);
        oracleContract.report(MARKET_ID, true);
        assertTrue(oracleContract.outcome(MARKET_ID));
    }

    function test_Outcome_ReturnsStored_False() public {
        vm.prank(reporter);
        oracleContract.report(MARKET_ID, false);
        assertFalse(oracleContract.outcome(MARKET_ID));
    }

    function test_Revert_Report_NotReporter() public {
        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector, stranger, oracleContract.REPORTER_ROLE()
            )
        );
        vm.prank(stranger);
        oracleContract.report(MARKET_ID, true);
    }

    function test_Revert_Report_AlreadyReported() public {
        vm.prank(reporter);
        oracleContract.report(MARKET_ID, true);

        vm.expectRevert(IManualOracle.ManualOracle_AlreadyReported.selector);
        vm.prank(reporter);
        oracleContract.report(MARKET_ID, false);
    }

    function test_Revert_Outcome_NotReported() public {
        vm.expectRevert(IManualOracle.ManualOracle_NotReported.selector);
        oracleContract.outcome(MARKET_ID);
    }

    // -------------------------------------------------------------------
    // revoke
    // -------------------------------------------------------------------

    function test_Revoke_HappyPath_ClearsResolved() public {
        vm.prank(reporter);
        oracleContract.report(MARKET_ID, true);

        vm.expectEmit(true, true, true, true);
        emit IManualOracle.OutcomeRevoked(MARKET_ID, admin);

        vm.prank(admin);
        oracleContract.revoke(MARKET_ID);

        assertFalse(oracleContract.isResolved(MARKET_ID));
    }

    function test_Revert_Revoke_ThenReport_Frozen() public {
        vm.prank(reporter);
        oracleContract.report(MARKET_ID, true);

        vm.prank(admin);
        oracleContract.revoke(MARKET_ID);

        vm.expectRevert(IManualOracle.ManualOracle_Frozen.selector);
        vm.prank(reporter);
        oracleContract.report(MARKET_ID, false);
    }

    function test_Revert_Revoke_NotAdmin() public {
        vm.prank(reporter);
        oracleContract.report(MARKET_ID, true);

        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector, reporter, oracleContract.DEFAULT_ADMIN_ROLE()
            )
        );
        vm.prank(reporter);
        oracleContract.revoke(MARKET_ID);
    }

    function test_Revert_Revoke_NotReported() public {
        vm.expectRevert(IManualOracle.ManualOracle_NotReported.selector);
        vm.prank(admin);
        oracleContract.revoke(MARKET_ID);
    }

    // -------------------------------------------------------------------
    // Fuzz
    // -------------------------------------------------------------------

    function testFuzz_Report_AnyMarketId(uint256 marketId, bool outcome_) public {
        vm.prank(reporter);
        oracleContract.report(marketId, outcome_);

        assertTrue(oracleContract.isResolved(marketId));
        assertEq(oracleContract.outcome(marketId), outcome_);
        assertEq(oracleContract.reporterOf(marketId), reporter);
    }
}
