// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import {EventFixture} from "../utils/EventFixture.sol";
import {IEventFacet} from "@predix/shared/interfaces/IEventFacet.sol";
import {IMarketFacet} from "@predix/shared/interfaces/IMarketFacet.sol";
import {IPausableFacet} from "@predix/shared/interfaces/IPausableFacet.sol";
import {Modules} from "@predix/shared/constants/Modules.sol";

/// @notice F4 (audit Gap#1): revert-path + pause coverage for LinkedEventFacet. `createEvent`
///         re-implements (does not delegate) EventFacet's input validation, and the completeSet
///         revert paths + the MARKET pause guards were untested — a regression weakening one of
///         these inline checks would not be caught. (Defensive-only paths `Event_PoolInsolvent`
///         and `Event_RefundModeActive` are unreachable while the solvency invariant holds /
///         linked refund-mode is a v1.1 deferral, so they are intentionally not exercised here.)
contract LinkedEventRevertsTest is EventFixture {
    uint256 internal endTime;

    function setUp() public override {
        super.setUp();
        endTime = block.timestamp + 30 days;
    }

    function _pauseMarket() internal {
        vm.prank(admin);
        pausable.pauseModule(Modules.MARKET);
    }

    function _resolveLinked(uint256 eventId) internal {
        vm.warp(endTime + 1);
        eventOracle.setEventResolution(eventId, 0);
        eventFacet.resolveEvent(eventId);
    }

    // --- createEvent input validation (inline copies of EventFacet's) ---

    function test_Revert_CreateLinkedEvent_EmptyName() public {
        string[] memory qs = _defaultQuestions(3);
        vm.prank(alice);
        vm.expectRevert(IEventFacet.Event_EmptyName.selector);
        eventFacet.createEvent("", qs, endTime, address(eventOracle));
    }

    function test_Revert_CreateLinkedEvent_InvalidEndTime() public {
        string[] memory qs = _defaultQuestions(3);
        vm.prank(alice);
        vm.expectRevert(IEventFacet.Event_InvalidEndTime.selector);
        eventFacet.createEvent("E", qs, block.timestamp, address(eventOracle)); // not strictly > now
    }

    function test_Revert_CreateLinkedEvent_ZeroOracle() public {
        string[] memory qs = _defaultQuestions(3);
        vm.prank(alice);
        vm.expectRevert(IEventFacet.Event_ZeroOracle.selector);
        eventFacet.createEvent("E", qs, endTime, address(0));
    }

    function test_Revert_CreateLinkedEvent_OracleNotApproved() public {
        string[] memory qs = _defaultQuestions(3);
        vm.prank(alice);
        vm.expectRevert(IEventFacet.Event_OracleNotApproved.selector);
        eventFacet.createEvent("E", qs, endTime, makeAddr("unapprovedOracle"));
    }

    function test_Revert_CreateLinkedEvent_OracleNotEventCapable() public {
        // `oracle` is the binary MockOracle: approved (MarketFixture) but does NOT implement IEventOracle.
        string[] memory qs = _defaultQuestions(3);
        vm.prank(alice);
        vm.expectRevert(IEventFacet.Event_OracleNotEventCapable.selector);
        eventFacet.createEvent("E", qs, endTime, address(oracle));
    }

    function test_Revert_CreateLinkedEvent_TooManyCandidates() public {
        string[] memory qs = _defaultQuestions(51); // MAX_CANDIDATES = 50
        vm.prank(alice);
        vm.expectRevert(IEventFacet.Event_TooManyCandidates.selector);
        eventFacet.createEvent("E", qs, endTime, address(eventOracle));
    }

    function test_Revert_CreateLinkedEvent_EmptyQuestion() public {
        string[] memory qs = new string[](3);
        qs[0] = "A";
        qs[1] = ""; // empty candidate
        qs[2] = "C";
        vm.prank(alice);
        vm.expectRevert(IMarketFacet.Market_EmptyQuestion.selector);
        eventFacet.createEvent("E", qs, endTime, address(eventOracle));
    }

    function test_Revert_CreateLinkedEvent_WhenPaused() public {
        _pauseMarket();
        string[] memory qs = _defaultQuestions(3);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(IPausableFacet.Pausable_EnforcedPause.selector, Modules.MARKET));
        eventFacet.createEvent("E", qs, endTime, address(eventOracle));
    }

    // --- splitEvent uncovered reverts (NotFound / AlreadyResolved / paused) ---

    function test_Revert_MintCompleteSet_NotFound() public {
        vm.prank(alice);
        vm.expectRevert(IEventFacet.Event_NotFound.selector);
        eventFacet.splitEvent(999, 1e6);
    }

    function test_Revert_MintCompleteSet_AlreadyResolved() public {
        (uint256 eventId,) = _createThreeCandidateEvent(endTime);
        _resolveLinked(eventId);
        vm.prank(alice);
        vm.expectRevert(IEventFacet.Event_AlreadyResolved.selector);
        eventFacet.splitEvent(eventId, 1e6);
    }

    function test_Revert_MintCompleteSet_WhenPaused() public {
        (uint256 eventId,) = _createThreeCandidateEvent(endTime);
        _pauseMarket();
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(IPausableFacet.Pausable_EnforcedPause.selector, Modules.MARKET));
        eventFacet.splitEvent(eventId, 1e6);
    }

    // --- mergeEvent reverts (only the happy path was covered) ---

    function test_Revert_RedeemCompleteSet_ZeroAmount() public {
        (uint256 eventId,) = _createThreeCandidateEvent(endTime);
        vm.prank(alice);
        vm.expectRevert(IEventFacet.Event_ZeroAmount.selector);
        eventFacet.mergeEvent(eventId, 0);
    }

    function test_Revert_RedeemCompleteSet_NotFound() public {
        vm.prank(alice);
        vm.expectRevert(IEventFacet.Event_NotFound.selector);
        eventFacet.mergeEvent(999, 1e6);
    }

    function test_Revert_RedeemCompleteSet_AlreadyResolved() public {
        (uint256 eventId,) = _createThreeCandidateEvent(endTime);
        _resolveLinked(eventId);
        vm.prank(alice);
        vm.expectRevert(IEventFacet.Event_AlreadyResolved.selector);
        eventFacet.mergeEvent(eventId, 1e6);
    }

    function test_Revert_RedeemCompleteSet_WhenPaused() public {
        (uint256 eventId,) = _createThreeCandidateEvent(endTime);
        _pauseMarket();
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(IPausableFacet.Pausable_EnforcedPause.selector, Modules.MARKET));
        eventFacet.mergeEvent(eventId, 1e6);
    }
}
