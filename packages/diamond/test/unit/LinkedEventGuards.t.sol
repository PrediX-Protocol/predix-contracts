// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import {LinkedEventFixture} from "../utils/LinkedEventFixture.sol";
import {IMarketFacet} from "@predix/shared/interfaces/IMarketFacet.sol";
import {IEventFacet} from "@predix/shared/interfaces/IEventFacet.sol";
import {IOutcomeToken} from "@predix/shared/interfaces/IOutcomeToken.sol";

/// @notice Task 3 guards: linked children route split/merge to the event pool (NOT revert), but reject
///         per-child redeem/refund/sweep; the event rejects addEventOutcome + enableEventRefundMode.
contract LinkedEventGuardsTest is LinkedEventFixture {
    uint256 internal eventId;
    uint256[] internal childIds;
    uint256 internal endTime;

    function setUp() public override {
        super.setUp();
        endTime = block.timestamp + 30 days;
        (eventId, childIds) = _createLinked3(endTime);
    }

    // --- split/merge MUST work on linked children (Q6=A) ---

    function test_Split_OnLinkedChild_RoutesToPool() public {
        IMarketFacet.MarketView memory m = market.getMarket(childIds[0]);
        _fundAndApprove(alice, 1e6);
        vm.prank(alice);
        market.splitPosition(childIds[0], 1e6);

        assertEq(linked.eventPoolOf(eventId), 1e6, "pool not credited");
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

        assertEq(linked.eventPoolOf(eventId), 6e5, "pool not debited");
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

    function test_Revert_AddEventOutcome_OnLinkedEvent() public {
        vm.prank(alice);
        vm.expectRevert(IEventFacet.Event_LinkedNoAddOutcome.selector);
        eventFacet.addEventOutcome(eventId, "late outcome");
    }

    function test_Revert_EnableEventRefundMode_OnLinkedEvent() public {
        vm.warp(endTime + 1);
        vm.prank(admin);
        vm.expectRevert(IEventFacet.Event_LinkedNoRefund.selector);
        eventFacet.enableEventRefundMode(eventId);
    }

    // --- legacy (non-linked) event must STILL allow addEventOutcome (no regression) ---

    function test_LegacyEvent_AddEventOutcome_StillWorks() public {
        uint256 legacyEnd = block.timestamp + 30 days;
        string[] memory qs = _defaultQuestions(2);
        vm.prank(alice);
        (uint256 legacyId,) = eventFacet.createEvent("Legacy", qs, legacyEnd, address(eventOracle));
        assertFalse(linked.isLinkedEvent(legacyId), "legacy must not be linked");

        vm.prank(alice);
        uint256 newChild = eventFacet.addEventOutcome(legacyId, "extra");
        assertEq(eventFacet.eventOfMarket(newChild), legacyId, "addEventOutcome regressed on legacy event");
    }
}
