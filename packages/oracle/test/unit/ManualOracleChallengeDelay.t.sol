// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import {Test} from "forge-std/Test.sol";

import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";

import {IManualOracle} from "@predix/oracle/interfaces/IManualOracle.sol";
import {ManualOracle} from "@predix/oracle/adapters/ManualOracle.sol";

import {MockDiamondStatus} from "../mocks/MockDiamondStatus.sol";

/// @notice Pins the ManualOracle challenge-delay window + admin reopen/correct path.
///         Default delay 0 = legacy immediate resolution; delay > 0 gates
///         `isResolved`/`outcome` until `finalizesAt`, giving the admin a race-free
///         window to abandon (`revoke`) or correct (`reopenReport`) a bad report.
contract ManualOracleChallengeDelayTest is Test {
    ManualOracle internal oracle;
    MockDiamondStatus internal diamond;

    address internal admin = makeAddr("admin");
    address internal reporter = makeAddr("reporter");
    address internal stranger = makeAddr("stranger");

    uint256 internal constant MARKET_ID = 42;
    uint256 internal constant EVENT_ID = 7;
    uint256 internal constant END_TIME = 1_700_000_000;
    uint256 internal constant DELAY = 1 days;

    function setUp() public {
        diamond = new MockDiamondStatus();
        oracle = new ManualOracle(admin, address(diamond));
        bytes32 reporterRole = oracle.REPORTER_ROLE();
        vm.prank(admin);
        oracle.grantRole(reporterRole, reporter);

        diamond.setEndTime(MARKET_ID, END_TIME);
        diamond.setEventStatus(EVENT_ID, END_TIME, 3);
        vm.warp(END_TIME);
    }

    function _setDelay(uint256 d) internal {
        vm.prank(admin);
        oracle.setChallengeDelay(d);
    }

    // ── default delay 0 = legacy immediate ──────────────────────────────

    function test_DefaultDelayZero_ImmediateResolution() public {
        assertEq(oracle.challengeDelay(), 0);
        vm.prank(reporter);
        oracle.report(MARKET_ID, true);
        assertTrue(oracle.isResolved(MARKET_ID));
        assertTrue(oracle.outcome(MARKET_ID));
    }

    // ── setChallengeDelay ───────────────────────────────────────────────

    function test_SetChallengeDelay_AdminOnly_Emits() public {
        vm.expectEmit(true, true, true, true);
        emit IManualOracle.ChallengeDelayUpdated(0, DELAY);
        vm.prank(admin);
        oracle.setChallengeDelay(DELAY);
        assertEq(oracle.challengeDelay(), DELAY);
    }

    function test_Revert_SetChallengeDelay_NotAdmin() public {
        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector, stranger, oracle.DEFAULT_ADMIN_ROLE()
            )
        );
        vm.prank(stranger);
        oracle.setChallengeDelay(DELAY);
    }

    function test_Revert_SetChallengeDelay_TooLong() public {
        uint256 tooLong = oracle.MAX_CHALLENGE_DELAY() + 1;
        vm.prank(admin);
        vm.expectRevert(IManualOracle.ManualOracle_DelayTooLong.selector);
        oracle.setChallengeDelay(tooLong);
    }

    // ── window gating ───────────────────────────────────────────────────

    function test_ChallengeWindow_NotResolvedUntilFinalizes() public {
        _setDelay(DELAY);
        vm.prank(reporter);
        oracle.report(MARKET_ID, true);

        // During window: not resolved, outcome reverts.
        assertFalse(oracle.isResolved(MARKET_ID));
        assertEq(oracle.finalizesAt(MARKET_ID), END_TIME + DELAY);
        vm.expectRevert(IManualOracle.ManualOracle_NotFinalized.selector);
        oracle.outcome(MARKET_ID);

        // After window: resolved, outcome readable.
        vm.warp(END_TIME + DELAY);
        assertTrue(oracle.isResolved(MARKET_ID));
        assertTrue(oracle.outcome(MARKET_ID));
    }

    function test_ChallengeDelay_SnapshotAtReport() public {
        _setDelay(DELAY);
        vm.prank(reporter);
        oracle.report(MARKET_ID, true);
        assertEq(oracle.finalizesAt(MARKET_ID), END_TIME + DELAY);

        // Admin lengthens the global delay AFTER the report — must not change the
        // already-reported market's window (snapshot, not retroactive).
        _setDelay(2 days);
        assertEq(oracle.finalizesAt(MARKET_ID), END_TIME + DELAY);

        vm.warp(END_TIME + DELAY);
        assertTrue(oracle.isResolved(MARKET_ID), "uses snapshot, not new global delay");
    }

    // ── reopen (correct) ────────────────────────────────────────────────

    function test_ReopenReport_DuringWindow_AllowsCorrectedReReport() public {
        _setDelay(DELAY);
        vm.prank(reporter);
        oracle.report(MARKET_ID, true); // wrong outcome

        vm.expectEmit(true, true, true, true);
        emit IManualOracle.ReportReopened(MARKET_ID, admin);
        vm.prank(admin);
        oracle.reopenReport(MARKET_ID);

        assertFalse(oracle.isResolved(MARKET_ID));

        // Reporter republishes the corrected outcome — fresh window.
        vm.prank(reporter);
        oracle.report(MARKET_ID, false);

        vm.warp(END_TIME + DELAY + 1);
        assertTrue(oracle.isResolved(MARKET_ID));
        assertFalse(oracle.outcome(MARKET_ID), "corrected outcome wins");
    }

    function test_Revert_ReopenReport_AfterWindowClosed() public {
        _setDelay(DELAY);
        vm.prank(reporter);
        oracle.report(MARKET_ID, true);

        vm.warp(END_TIME + DELAY); // window closed (finalized)
        vm.prank(admin);
        vm.expectRevert(IManualOracle.ManualOracle_ChallengeWindowClosed.selector);
        oracle.reopenReport(MARKET_ID);
    }

    function test_Revert_ReopenReport_NotReported() public {
        _setDelay(DELAY);
        vm.prank(admin);
        vm.expectRevert(IManualOracle.ManualOracle_NotReported.selector);
        oracle.reopenReport(MARKET_ID);
    }

    function test_Revert_ReopenReport_NotAdmin() public {
        _setDelay(DELAY);
        vm.prank(reporter);
        oracle.report(MARKET_ID, true);

        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector, reporter, oracle.DEFAULT_ADMIN_ROLE()
            )
        );
        vm.prank(reporter);
        oracle.reopenReport(MARKET_ID);
    }

    // ── revoke (abandon) still freezes even with a window (FinalH10 intact) ──

    function test_Revoke_StillFreezes_DuringWindow() public {
        _setDelay(DELAY);
        vm.prank(reporter);
        oracle.report(MARKET_ID, true);

        vm.prank(admin);
        oracle.revoke(MARKET_ID);

        vm.expectRevert(IManualOracle.ManualOracle_Frozen.selector);
        vm.prank(reporter);
        oracle.report(MARKET_ID, false);
    }

    // ── event path mirrors binary ───────────────────────────────────────

    function test_Event_ChallengeWindow_AndReopen() public {
        _setDelay(DELAY);
        vm.prank(reporter);
        oracle.reportEvent(EVENT_ID, 1);
        assertFalse(oracle.isEventResolved(EVENT_ID));
        assertEq(oracle.eventFinalizesAt(EVENT_ID), END_TIME + DELAY);
        vm.expectRevert(IManualOracle.ManualOracle_NotFinalized.selector);
        oracle.eventOutcome(EVENT_ID);

        // Admin reopens, reporter corrects the winning index.
        vm.prank(admin);
        oracle.reopenEventReport(EVENT_ID);
        vm.prank(reporter);
        oracle.reportEvent(EVENT_ID, 2);

        vm.warp(END_TIME + DELAY + 1);
        assertTrue(oracle.isEventResolved(EVENT_ID));
        assertEq(oracle.eventOutcome(EVENT_ID), 2, "corrected winning index");
    }
}
