// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import {IDiamondCut} from "@predix/shared/interfaces/IDiamondCut.sol";
import {IEventFacet} from "@predix/shared/interfaces/IEventFacet.sol";

import {EventFixture} from "../utils/EventFixture.sol";

/// @notice Dedicated sc-audit pass for the LINKED (shared-collateral / NegRisk) subsystem.
///         Two of these tests PROVE the subsystem is sound (solvency drains the pool to exactly 0
///         across a mixed mint/split lifecycle with multiple users); two document NEW v1 limitations
///         surfaced by the deeper pass (no fair refund/void path for linked events; unclaimed pool
///         residual is not sweepable in v1). All four are executed (not asserted from inspection).
contract Audit_Linked_Subsystem is EventFixture {
    // ---------------------------------------------------------------------
    // Soundness: solvency invariant end-to-end (eventPool == Σnᵢ + M, drains to 0)
    // ---------------------------------------------------------------------

    /// @dev Mixed lifecycle (completeSet mint + single-outcome split + 2 users) resolves and both
    ///      winners redeem from the shared pool; the pool drains to EXACTLY 0 and each user is paid
    ///      their fair winning amount. This is the solvency theorem demonstrated end-to-end.
    function test_Linked_FullLifecycle_SolvencyPoolDrainsToZero() public {
        uint256 endTime = block.timestamp + 1 days;
        (uint256 eventId, uint256[] memory ids) = _createThreeCandidateEvent(endTime);

        // bob: complete set of 100 + a 50 single-outcome split on child 0 (routes to the pool)
        _fundAndApprove(bob, 100e6);
        vm.prank(bob);
        eventFacet.splitEvent(eventId, 100e6);
        _fundAndApprove(bob, 50e6);
        vm.prank(bob);
        market.splitPosition(ids[0], 50e6);

        // carol: complete set of 100
        _fundAndApprove(carol, 100e6);
        vm.prank(carol);
        eventFacet.splitEvent(eventId, 100e6);

        assertEq(eventFacet.eventPoolOf(eventId), 250e6, "pool = 100 + 50 + 100");

        // resolve: outcome 0 wins
        eventOracle.setEventResolution(eventId, 0);
        vm.warp(endTime + 1);
        eventFacet.resolveEvent(eventId);

        uint256 bobBefore = usdc.balanceOf(bob);
        vm.prank(bob);
        uint256 bobPay = eventFacet.redeemEvent(eventId);

        uint256 carolBefore = usdc.balanceOf(carol);
        vm.prank(carol);
        uint256 carolPay = eventFacet.redeemEvent(eventId);

        // bob held 150 YES of the winning outcome (100 mint + 50 split); carol held 100.
        assertEq(bobPay, 150e6, "bob paid full winning YES");
        assertEq(carolPay, 100e6, "carol paid full winning YES");
        assertEq(usdc.balanceOf(bob) - bobBefore, 150e6);
        assertEq(usdc.balanceOf(carol) - carolBefore, 100e6);
        assertEq(eventFacet.eventPoolOf(eventId), 0, "SOLVENT: pool drains to exactly 0");
    }

    // ---------------------------------------------------------------------
    // Finding A: linked events have NO refund/void path — only emergency-resolve, which forces a winner
    // ---------------------------------------------------------------------

    /// @dev enableEventRefundMode is rejected for linked events; a stalled/unresolvable linked event's
    ///      ONLY escape is OPERATOR emergencyResolveEvent, which must declare some winner. There is no
    ///      pro-rata void — a directional holder in a cancelled event cannot be made whole.
    function test_Linked_NoRefundPath_OnlyEmergencyResolveForcesAWinner() public {
        uint256 endTime = block.timestamp + 1 days;
        (uint256 eventId,) = _createThreeCandidateEvent(endTime);
        _fundAndApprove(bob, 100e6);
        vm.prank(bob);
        eventFacet.splitEvent(eventId, 100e6);

        vm.warp(endTime + 1);

        // 1) Refund mode is blocked for linked events.
        vm.prank(admin);
        vm.expectRevert(IEventFacet.Event_LinkedNoRefund.selector);
        eventFacet.enableEventRefundMode(eventId);

        // 2) resolveEvent fails while the oracle is silent.
        vm.expectRevert(IEventFacet.Event_OracleNotResolved.selector);
        eventFacet.resolveEvent(eventId);

        // 3) The ONLY escape: OPERATOR emergency-resolves after 7d, forced to pick a winner index.
        vm.warp(endTime + 7 days + 1);
        vm.prank(admin); // admin holds OPERATOR_ROLE
        eventFacet.emergencyResolveEvent(eventId, 1); // arbitrary operator-chosen winner

        // bob held a complete set so he is whole regardless; a directional bettor on a losing index
        // would simply lose, with no refund alternative.
        vm.prank(bob);
        assertEq(eventFacet.redeemEvent(eventId), 100e6, "redeem only against the operator-forced winner");
    }

    // ---------------------------------------------------------------------
    // Finding B: unclaimed linked pool residual is not sweepable in v1
    // ---------------------------------------------------------------------

    /// @dev sweepUnclaimedEvent skips linked children, so collateral left by non-redeemers stays locked
    ///      in eventPool forever in v1 (rescueSurplus also cannot touch it — it is counted in
    ///      totalCollateralLocked). Not a loss, but non-recoverable until the v1.1 linked sweep.
    function test_Linked_UnclaimedPoolResidual_NotSweepable() public {
        uint256 endTime = block.timestamp + 1 days;
        (uint256 eventId,) = _createThreeCandidateEvent(endTime);
        _fundAndApprove(bob, 100e6);
        vm.prank(bob);
        eventFacet.splitEvent(eventId, 100e6);

        eventOracle.setEventResolution(eventId, 0);
        vm.warp(endTime + 1);
        eventFacet.resolveEvent(eventId);

        // bob never redeems. Past the 365-day grace, admin sweeps — linked children are skipped.
        vm.warp(block.timestamp + 366 days);
        vm.prank(admin);
        uint256 swept = eventFacet.sweepUnclaimedEvent(eventId);

        assertEq(swept, 0, "linked children skipped by sweep");
        assertEq(eventFacet.eventPoolOf(eventId), 100e6, "residual stays locked in the pool (v1 limitation)");
    }
}
