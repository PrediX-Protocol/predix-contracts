// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import {IEventFacet} from "@predix/shared/interfaces/IEventFacet.sol";
import {IMarketFacet} from "@predix/shared/interfaces/IMarketFacet.sol";

import {EventFixture} from "../utils/EventFixture.sol";

/// @title EventFacet_AddOutcome
/// @notice Coverage for `addEventOutcome` — appending a candidate to a live event.
///         Asserts the new child inherits the event's deadline + collective oracle,
///         matches its siblings' redemption-fee snapshot, settles correctly when it
///         wins, and that every live-state guard reverts.
contract EventFacet_AddOutcome is EventFixture {
    function _futureEnd() internal view returns (uint256) {
        return block.timestamp + 7 days;
    }

    function test_AddOutcome_HappyPath() public {
        uint256 endTime = _futureEnd();
        (uint256 eventId,) = _createThreeCandidateEvent(endTime);

        uint256 expectedId = market.marketCount() + 1;
        vm.expectEmit(true, true, false, true, address(diamond));
        emit IEventFacet.EventOutcomeAdded(eventId, expectedId, "New candidate");

        vm.prank(alice);
        uint256 marketId = eventFacet.addEventOutcome(eventId, "New candidate");

        assertEq(marketId, expectedId, "marketId");

        IEventFacet.EventView memory ev = eventFacet.getEvent(eventId);
        assertEq(ev.marketIds.length, 4, "candidate count grew to 4");
        assertEq(ev.marketIds[3], marketId, "appended at tail");
        assertEq(eventFacet.eventOfMarket(marketId), eventId, "marketToEvent wired");
        assertEq(eventFacet.eventCount(), 1, "eventCount unchanged");
    }

    function test_AddOutcome_InheritsEndTimeAndCollectiveOracle() public {
        uint256 endTime = _futureEnd();
        (uint256 eventId, uint256[] memory ids) = _createThreeCandidateEvent(endTime);

        vm.prank(alice);
        uint256 marketId = eventFacet.addEventOutcome(eventId, "New candidate");

        IMarketFacet.MarketView memory m = market.getMarket(marketId);
        assertEq(m.endTime, endTime, "endTime inherited from event");
        assertEq(m.oracle, address(0), "collective oracle (address(0))");
        assertEq(m.eventId, eventId, "eventId set");
        assertEq(m.endTime, market.getMarket(ids[0]).endTime, "endTime identical to sibling");
    }

    function test_AddOutcome_FeeSnapshotMatchesSiblings() public {
        // Children snapshot the default redemption fee at event-create time.
        vm.prank(admin);
        market.setDefaultRedemptionFeeBps(100);

        uint256 endTime = _futureEnd();
        (uint256 eventId, uint256[] memory ids) = _createThreeCandidateEvent(endTime);

        // Global default changes AFTER the event was created.
        vm.prank(admin);
        market.setDefaultRedemptionFeeBps(200);

        vm.prank(alice);
        uint256 marketId = eventFacet.addEventOutcome(eventId, "Late candidate");

        // The late-added outcome must keep the event-time fee, not the new default.
        assertEq(market.effectiveRedemptionFeeBps(marketId), 100, "new keeps event-time snapshot");
        assertEq(
            market.effectiveRedemptionFeeBps(marketId),
            market.effectiveRedemptionFeeBps(ids[0]),
            "new == sibling fee"
        );
    }

    function test_AddOutcome_NewOutcomeCanWin() public {
        uint256 endTime = _futureEnd();
        (uint256 eventId,) = _createThreeCandidateEvent(endTime);

        vm.prank(alice);
        uint256 newId = eventFacet.addEventOutcome(eventId, "Late winner"); // index 3 (4th)

        vm.warp(endTime + 1);
        eventOracle.setEventResolution(eventId, 3);
        eventFacet.resolveEvent(eventId);

        IMarketFacet.MarketView memory m = market.getMarket(newId);
        assertTrue(m.isResolved, "child resolved");
        assertTrue(m.outcome, "late outcome won");
    }

    function test_Revert_AddOutcome_NotCreator() public {
        (uint256 eventId,) = _createThreeCandidateEvent(_futureEnd());
        vm.prank(bob);
        vm.expectRevert(IEventFacet.Event_NotCreator.selector);
        eventFacet.addEventOutcome(eventId, "x");
    }

    function test_Revert_AddOutcome_EmptyQuestion() public {
        (uint256 eventId,) = _createThreeCandidateEvent(_futureEnd());
        vm.prank(alice);
        vm.expectRevert(IMarketFacet.Market_EmptyQuestion.selector);
        eventFacet.addEventOutcome(eventId, "");
    }

    function test_Revert_AddOutcome_EventNotFound() public {
        vm.prank(alice);
        vm.expectRevert(IEventFacet.Event_NotFound.selector);
        eventFacet.addEventOutcome(999, "x");
    }

    function test_Revert_AddOutcome_Ended() public {
        uint256 endTime = _futureEnd();
        (uint256 eventId,) = _createThreeCandidateEvent(endTime);
        vm.warp(endTime); // block.timestamp >= endTime
        vm.prank(alice);
        vm.expectRevert(IEventFacet.Event_Ended.selector);
        eventFacet.addEventOutcome(eventId, "x");
    }

    function test_Revert_AddOutcome_AlreadyResolved() public {
        uint256 endTime = _futureEnd();
        (uint256 eventId,) = _createThreeCandidateEvent(endTime);
        vm.warp(endTime + 1);
        eventOracle.setEventResolution(eventId, 0);
        eventFacet.resolveEvent(eventId);
        // isResolved is checked before the ended guard.
        vm.prank(alice);
        vm.expectRevert(IEventFacet.Event_AlreadyResolved.selector);
        eventFacet.addEventOutcome(eventId, "x");
    }
}
