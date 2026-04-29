// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IMarketFacet} from "@predix/shared/interfaces/IMarketFacet.sol";
import {IEventFacet} from "@predix/shared/interfaces/IEventFacet.sol";
import {IAccessControlFacet} from "@predix/shared/interfaces/IAccessControlFacet.sol";
import {IPausableFacet} from "@predix/shared/interfaces/IPausableFacet.sol";
import {ManualOracle} from "@predix/oracle/adapters/ManualOracle.sol";
import {E2EForkBase} from "./E2EForkBase.t.sol";

/// @title E2E_EventAccessOracle
/// @notice Groups R (Event), S (Access Control), T (Pause), U (Oracle).
contract E2E_EventAccessOracle is E2EForkBase {
    // ================================================================
    // R. Event
    // ================================================================

    function test_R01_createEvent_2candidates() public {
        _grantCreatorRole(alice);
        string[] memory questions = new string[](2);
        questions[0] = "A wins?";
        questions[1] = "B wins?";

        vm.prank(alice);
        (uint256 eventId, uint256[] memory marketIds) = eventFacet.createEvent("Election", questions, block.timestamp + 7 days);

        assertEq(marketIds.length, 2);
        assertGt(eventId, 0);
    }

    function test_R04_createEvent_Revert_1candidate() public {
        _grantCreatorRole(alice);
        string[] memory questions = new string[](1);
        questions[0] = "Only one?";

        vm.prank(alice);
        vm.expectRevert();
        eventFacet.createEvent("Bad event", questions, block.timestamp + 7 days);
    }

    function test_R05_resolveEvent_winnerIndex0() public {
        _grantCreatorRole(alice);
        string[] memory questions = new string[](3);
        questions[0] = "A?";
        questions[1] = "B?";
        questions[2] = "C?";

        vm.prank(alice);
        (uint256 eventId, uint256[] memory marketIds) = eventFacet.createEvent("Race", questions, block.timestamp + 1 hours);

        _splitPosition(alice, marketIds[0], 100e6);
        _splitPosition(alice, marketIds[1], 100e6);

        vm.warp(block.timestamp + 2 hours);
        vm.prank(DEPLOYER);
        eventFacet.resolveEvent(eventId, 0);

        // Winner (index 0) resolved YES
        assertTrue(diamond.getMarket(marketIds[0]).isResolved);
        assertTrue(diamond.getMarket(marketIds[0]).outcome);
        // Loser (index 1) resolved NO
        assertTrue(diamond.getMarket(marketIds[1]).isResolved);
        assertFalse(diamond.getMarket(marketIds[1]).outcome);
    }

    function test_R06_resolveEvent_Revert_invalidIndex() public {
        _grantCreatorRole(alice);
        string[] memory questions = new string[](2);
        questions[0] = "A?";
        questions[1] = "B?";

        vm.prank(alice);
        (uint256 eventId,) = eventFacet.createEvent("Test", questions, block.timestamp + 1 hours);

        vm.warp(block.timestamp + 2 hours);
        vm.prank(DEPLOYER);
        vm.expectRevert();
        eventFacet.resolveEvent(eventId, 5); // index out of bounds
    }

    function test_R07_enableEventRefundMode() public {
        _grantCreatorRole(alice);
        string[] memory questions = new string[](2);
        questions[0] = "A?";
        questions[1] = "B?";

        vm.prank(alice);
        (uint256 eventId, uint256[] memory marketIds) = eventFacet.createEvent("Refund test", questions, block.timestamp + 1 hours);

        vm.warp(block.timestamp + 2 hours);
        vm.prank(DEPLOYER);
        eventFacet.enableEventRefundMode(eventId);

        assertTrue(diamond.getMarket(marketIds[0]).refundModeActive);
        assertTrue(diamond.getMarket(marketIds[1]).refundModeActive);
    }

    function test_R08_resolveEvent_Revert_alreadyResolved() public {
        _grantCreatorRole(alice);
        string[] memory questions = new string[](2);
        questions[0] = "A?";
        questions[1] = "B?";

        vm.prank(alice);
        (uint256 eventId,) = eventFacet.createEvent("Once", questions, block.timestamp + 1 hours);

        vm.warp(block.timestamp + 2 hours);
        vm.prank(DEPLOYER);
        eventFacet.resolveEvent(eventId, 0);

        vm.prank(DEPLOYER);
        vm.expectRevert();
        eventFacet.resolveEvent(eventId, 1);
    }

    // ================================================================
    // S. Access Control
    // ================================================================

    function test_S01_grantRole_revokeRole() public {
        vm.prank(DEPLOYER);
        accessControl.grantRole(ROLE_CREATOR, eve);
        assertTrue(accessControl.hasRole(ROLE_CREATOR, eve));

        vm.prank(DEPLOYER);
        accessControl.revokeRole(ROLE_CREATOR, eve);
        assertFalse(accessControl.hasRole(ROLE_CREATOR, eve));
    }

    function test_S02_Revert_revokeLastDefaultAdmin() public {
        // DEPLOYER is DEFAULT_ADMIN. Try to renounce → should revert (last admin guard)
        vm.prank(DEPLOYER);
        vm.expectRevert();
        accessControl.renounceRole(bytes32(0), DEPLOYER);
    }

    function test_S04_CUT_EXECUTOR_selfAdministered() public {
        // CUT_EXECUTOR is self-administered: only existing holders can grant.
        // alice (non-holder) cannot grant even if she has DEFAULT_ADMIN_ROLE.
        vm.prank(DEPLOYER);
        accessControl.grantRole(bytes32(0), alice); // give alice DEFAULT_ADMIN

        vm.prank(alice);
        vm.expectRevert();
        accessControl.grantRole(ROLE_CUT_EXECUTOR, bob);
    }

    function test_S05_renounceRole_Revert_wrongConfirmation() public {
        _grantCreatorRole(alice);

        // alice tries to renounce but passes wrong address as confirmation
        vm.prank(alice);
        vm.expectRevert();
        accessControl.renounceRole(ROLE_CREATOR, bob); // should be alice
    }

    function test_S08_nonAdmin_Revert_approveOracle() public {
        vm.prank(eve);
        vm.expectRevert();
        diamond.approveOracle(address(0xdead));
    }

    // ================================================================
    // T. Pause
    // ================================================================

    function test_T01_pauseMarket_blocksSplit() public {
        _grantCreatorRole(alice);
        uint256 mid = _createMarket(alice, block.timestamp + 7 days);

        vm.prank(DEPLOYER);
        pausable.pauseModule(MODULE_MARKET);

        vm.startPrank(alice);
        IERC20(USDC).approve(DIAMOND, 100e6);
        vm.expectRevert();
        diamond.splitPosition(mid, 100e6);
        vm.stopPrank();

        vm.prank(DEPLOYER);
        pausable.unpauseModule(MODULE_MARKET);
    }

    function test_T02_pauseMarket_redeemBypasses() public {
        _grantCreatorRole(alice);
        uint256 mid = _createMarket(alice, block.timestamp + 1 hours);
        _splitPosition(alice, mid, 1000e6);
        vm.warp(block.timestamp + 2 hours);
        _reportOutcome(mid, true);
        _resolveMarket(mid);

        vm.prank(DEPLOYER);
        pausable.pauseModule(MODULE_MARKET);

        // Redeem still works
        vm.prank(alice);
        uint256 payout = diamond.redeem(mid);
        assertGt(payout, 0);

        vm.prank(DEPLOYER);
        pausable.unpauseModule(MODULE_MARKET);
    }

    function test_T03_pauseMarket_refundBypasses() public {
        _grantCreatorRole(alice);
        uint256 mid = _createMarket(alice, block.timestamp + 1 hours);
        _splitPosition(alice, mid, 1000e6);
        vm.warp(block.timestamp + 2 hours);
        vm.prank(DEPLOYER);
        diamond.enableRefundMode(mid);

        vm.prank(DEPLOYER);
        pausable.pauseModule(MODULE_MARKET);

        // Refund still works
        vm.prank(alice);
        uint256 payout = diamond.refund(mid, 1000e6, 1000e6);
        assertGt(payout, 0);

        vm.prank(DEPLOYER);
        pausable.unpauseModule(MODULE_MARKET);
    }

    function test_T04_pauseMarket_emergencyResolveBypasses() public {
        _grantCreatorRole(alice);
        uint256 mid = _createMarket(alice, block.timestamp + 1 hours);
        _splitPosition(alice, mid, 100e6);
        vm.warp(block.timestamp + 1 hours + 7 days + 1);

        vm.prank(DEPLOYER);
        pausable.pauseModule(MODULE_MARKET);

        // Emergency resolve still works
        vm.prank(DEPLOYER);
        diamond.emergencyResolve(mid, true);
        assertTrue(diamond.getMarket(mid).isResolved);

        vm.prank(DEPLOYER);
        pausable.unpauseModule(MODULE_MARKET);
    }

    function test_T06_globalPause_blocksAll() public {
        _grantCreatorRole(alice);
        uint256 mid = _createMarket(alice, block.timestamp + 7 days);

        vm.prank(DEPLOYER);
        pausable.pause();

        vm.startPrank(alice);
        IERC20(USDC).approve(DIAMOND, 100e6);
        vm.expectRevert();
        diamond.splitPosition(mid, 100e6);
        vm.stopPrank();

        vm.prank(DEPLOYER);
        pausable.unpause();
    }

    // ================================================================
    // U. Oracle
    // ================================================================

    function test_U01_manualOracle_report() public {
        _grantCreatorRole(alice);
        uint256 mid = _createMarket(alice, block.timestamp + 1 hours);
        vm.warp(block.timestamp + 2 hours);

        vm.prank(OPERATOR);
        oracle.report(mid, true);

        assertTrue(oracle.isResolved(mid));
        assertTrue(oracle.outcome(mid));
    }

    function test_U02_report_Revert_beforeEndTime() public {
        _grantCreatorRole(alice);
        uint256 mid = _createMarket(alice, block.timestamp + 1 days);

        vm.prank(OPERATOR);
        vm.expectRevert();
        oracle.report(mid, true);
    }

    function test_U03_report_Revert_twice() public {
        _grantCreatorRole(alice);
        uint256 mid = _createMarket(alice, block.timestamp + 1 hours);
        vm.warp(block.timestamp + 2 hours);

        vm.prank(OPERATOR);
        oracle.report(mid, true);

        vm.prank(OPERATOR);
        vm.expectRevert();
        oracle.report(mid, false);
    }

    function test_U04_revoke_thenReport_Revert_frozen() public {
        _grantCreatorRole(alice);
        uint256 mid = _createMarket(alice, block.timestamp + 1 hours);
        vm.warp(block.timestamp + 2 hours);

        // Must report first, then revoke freezes the market
        vm.prank(OPERATOR);
        oracle.report(mid, true);

        vm.prank(DEPLOYER);
        oracle.revoke(mid);

        // After revoke: isResolved=false, frozen=true → cannot re-report
        assertFalse(oracle.isResolved(mid));
        vm.prank(OPERATOR);
        vm.expectRevert();
        oracle.report(mid, false);
    }

    function test_U06_outcome_Revert_beforeReport() public {
        _grantCreatorRole(alice);
        uint256 mid = _createMarket(alice, block.timestamp + 1 hours);

        vm.expectRevert();
        oracle.outcome(mid);
    }

    function test_U07_report_Revert_nonReporter() public {
        _grantCreatorRole(alice);
        uint256 mid = _createMarket(alice, block.timestamp + 1 hours);
        vm.warp(block.timestamp + 2 hours);

        vm.prank(eve);
        vm.expectRevert();
        oracle.report(mid, true);
    }
}
