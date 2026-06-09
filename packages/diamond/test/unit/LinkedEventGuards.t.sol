// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import {EventFixture} from "../utils/EventFixture.sol";
import {IMarketFacet} from "@predix/shared/interfaces/IMarketFacet.sol";
import {IEventFacet} from "@predix/shared/interfaces/IEventFacet.sol";
import {IOutcomeToken} from "@predix/shared/interfaces/IOutcomeToken.sol";

/// @notice Task 3 guards: linked children route split/merge to the event pool (NOT revert), but reject
///         per-child redeem/refund/sweep; the event rejects enableEventRefundMode (no v1 refund path).
contract LinkedEventGuardsTest is EventFixture {
    uint256 internal eventId;
    uint256[] internal childIds;
    uint256 internal endTime;

    function setUp() public override {
        super.setUp();
        endTime = block.timestamp + 30 days;
        (eventId, childIds) = _createThreeCandidateEvent(endTime);
    }

    // --- split/merge MUST work on linked children (Q6=A) ---

    function test_Split_OnLinkedChild_RoutesToPool() public {
        IMarketFacet.MarketView memory m = market.getMarket(childIds[0]);
        _fundAndApprove(alice, 1e6);
        vm.prank(alice);
        market.splitPosition(childIds[0], 1e6);

        assertEq(eventFacet.eventPoolOf(eventId), 1e6, "pool not credited");
        assertEq(market.getMarket(childIds[0]).totalCollateral, 0, "linked child per-market collateral must stay 0");
        assertEq(IOutcomeToken(m.yesToken).balanceOf(alice), 1e6, "YES not minted");
        assertEq(IOutcomeToken(m.noToken).balanceOf(alice), 1e6, "NO not minted");
        assertEq(market.totalCollateralLocked(), 1e6, "lockstep broken");
    }

    function test_Merge_OnLinkedChild_DebitsPool() public {
        _fundAndApprove(alice, 1e6);
        vm.startPrank(alice);
        market.splitPosition(childIds[0], 1e6);
        market.mergePositions(childIds[0], 4e5);
        vm.stopPrank();

        assertEq(eventFacet.eventPoolOf(eventId), 6e5, "pool not debited");
        assertEq(market.totalCollateralLocked(), 6e5, "lockstep broken");
    }

    // --- per-child-only flows MUST revert on linked children ---

    function test_Revert_Refund_OnLinkedChild() public {
        vm.prank(alice);
        vm.expectRevert(IMarketFacet.Market_LinkedEvent.selector);
        market.refund(childIds[0], 1e6, 1e6);
    }

    function test_Revert_Redeem_OnLinkedChild() public {
        // resolve the event first so redeem's other gates aren't what reverts
        vm.warp(endTime + 1);
        eventOracle.setEventResolution(eventId, 0);
        eventFacet.resolveEvent(eventId);

        vm.prank(alice);
        vm.expectRevert(IMarketFacet.Market_LinkedEvent.selector);
        market.redeem(childIds[0]);
    }

    function test_Revert_SweepUnclaimed_OnLinkedChild() public {
        vm.prank(admin);
        vm.expectRevert(IMarketFacet.Market_LinkedEvent.selector);
        market.sweepUnclaimed(childIds[0]);
    }

    // --- event-level guards ---

    function test_Revert_EnableEventRefundMode_OnLinkedEvent() public {
        vm.warp(endTime + 1);
        vm.prank(admin);
        vm.expectRevert(IEventFacet.Event_LinkedNoRefund.selector);
        eventFacet.enableEventRefundMode(eventId);
    }

    // --- per-market CAP setter still rejects linked children (F1, audit Gap#1) — their collateral is
    //     pooled at the event level so a per-child cap is meaningless. keyti-fqn8: the per-market FEE
    //     setters NO LONGER reject linked children (fee is a unified per-market property; redeemEvent
    //     charges each child's own effective fee). ---

    function test_Revert_SetPerMarketCap_OnLinkedChild() public {
        vm.prank(admin);
        vm.expectRevert(IMarketFacet.Market_LinkedEvent.selector);
        market.setPerMarketCap(childIds[0], 1e6);
    }

    function test_SetPerMarketRedemptionFeeBps_OnLinkedChild_NowAllowed() public {
        vm.prank(admin);
        market.setPerMarketRedemptionFeeBps(childIds[0], 100);
        assertEq(market.effectiveRedemptionFeeBps(childIds[0]), 100);
        assertTrue(market.getMarket(childIds[0]).redemptionFeeOverridden);
    }

    function test_ClearPerMarketRedemptionFee_OnLinkedChild_NowAllowed() public {
        vm.prank(admin);
        market.setPerMarketRedemptionFeeBps(childIds[0], 100);
        vm.prank(admin);
        market.clearPerMarketRedemptionFee(childIds[0]);
        assertFalse(market.getMarket(childIds[0]).redemptionFeeOverridden);
    }
}
