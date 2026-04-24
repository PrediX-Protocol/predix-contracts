// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {IEventFacet} from "@predix/shared/interfaces/IEventFacet.sol";
import {IMarketFacet} from "@predix/shared/interfaces/IMarketFacet.sol";
import {IOutcomeToken} from "@predix/shared/interfaces/IOutcomeToken.sol";
import {Roles} from "@predix/shared/constants/Roles.sol";

import {EventFixture} from "../utils/EventFixture.sol";
import {EventHandler} from "./EventHandler.sol";

/// @notice Invariants for EventFacet. Bootstraps a handful of events before fuzzing
///         so every run has non-empty state for the binary invariants to check.
contract EventInvariantTest is EventFixture {
    EventHandler internal handler;
    uint256 internal eventEndTime;

    function setUp() public override {
        super.setUp();
        eventEndTime = block.timestamp + 365 days;
        handler = new EventHandler(address(diamond), address(usdc), admin, eventEndTime);

        // SPEC-03: handler drives `createEvent` from its `users[0]` identity, so
        // that address needs CREATOR_ROLE for the fuzzer to make progress.
        // Read the address first so `vm.prank` is consumed by `grantRole`, not the view.
        address handlerCreator = handler.users(0);
        vm.prank(admin);
        accessControl.grantRole(Roles.CREATOR_ROLE, handlerCreator);

        // Seed two events so the invariants have state to walk even if `createEvent`
        // is never selected by the fuzzer.
        _createNCandidateEvent(3, eventEndTime);
        _createNCandidateEvent(4, eventEndTime);

        bytes4[] memory selectors = new bytes4[](4);
        selectors[0] = EventHandler.createEvent.selector;
        selectors[1] = EventHandler.split.selector;
        selectors[2] = EventHandler.merge.selector;
        selectors[3] = EventHandler.resolve.selector;
        targetSelector(FuzzSelector({addr: address(handler), selectors: selectors}));
        targetContract(address(handler));
    }

    function _allEventIds() internal view returns (uint256[] memory ids) {
        uint256 total = eventFacet.eventCount();
        ids = new uint256[](total);
        for (uint256 i; i < total; ++i) {
            ids[i] = i + 1;
        }
    }

    function invariant_EventChildAlwaysPointsBack() public view {
        uint256[] memory ids = _allEventIds();
        for (uint256 i; i < ids.length; ++i) {
            IEventFacet.EventView memory e = eventFacet.getEvent(ids[i]);
            for (uint256 j; j < e.marketIds.length; ++j) {
                assertEq(eventFacet.eventOfMarket(e.marketIds[j]), ids[i], "child mismatch");
                assertEq(market.getMarket(e.marketIds[j]).eventId, ids[i], "market.eventId mismatch");
            }
        }
    }

    function invariant_EventChildrenShareEndTime() public view {
        uint256[] memory ids = _allEventIds();
        for (uint256 i; i < ids.length; ++i) {
            IEventFacet.EventView memory e = eventFacet.getEvent(ids[i]);
            for (uint256 j; j < e.marketIds.length; ++j) {
                assertEq(market.getMarket(e.marketIds[j]).endTime, e.endTime, "endTime mismatch");
            }
        }
    }

    function invariant_EventChildrenHaveZeroOracle() public view {
        uint256[] memory ids = _allEventIds();
        for (uint256 i; i < ids.length; ++i) {
            IEventFacet.EventView memory e = eventFacet.getEvent(ids[i]);
            for (uint256 j; j < e.marketIds.length; ++j) {
                assertEq(market.getMarket(e.marketIds[j]).oracle, address(0), "oracle != 0");
            }
        }
    }

    function invariant_ResolvedEventExactlyOneWinner() public view {
        uint256[] memory ids = _allEventIds();
        for (uint256 i; i < ids.length; ++i) {
            IEventFacet.EventView memory e = eventFacet.getEvent(ids[i]);
            if (!e.isResolved) continue;
            uint256 winners;
            uint256 losers;
            for (uint256 j; j < e.marketIds.length; ++j) {
                IMarketFacet.MarketView memory m = market.getMarket(e.marketIds[j]);
                assertTrue(m.isResolved, "child not resolved");
                if (m.outcome) winners++;
                else losers++;
            }
            assertEq(winners, 1, "winners != 1");
            assertEq(losers, e.marketIds.length - 1, "losers != N-1");
        }
    }

    function invariant_BinaryInvariantHoldsPerChild() public view {
        uint256[] memory ids = _allEventIds();
        for (uint256 i; i < ids.length; ++i) {
            IEventFacet.EventView memory e = eventFacet.getEvent(ids[i]);
            for (uint256 j; j < e.marketIds.length; ++j) {
                IMarketFacet.MarketView memory m = market.getMarket(e.marketIds[j]);
                if (m.isResolved || m.refundModeActive) continue;
                assertEq(IOutcomeToken(m.yesToken).totalSupply(), m.totalCollateral, "yes != coll");
                assertEq(IOutcomeToken(m.noToken).totalSupply(), m.totalCollateral, "no != coll");
            }
        }
    }
}
