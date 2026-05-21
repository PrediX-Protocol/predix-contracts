// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import {IEventFacet} from "@predix/shared/interfaces/IEventFacet.sol";

import {EventFixture} from "../utils/EventFixture.sol";

/// @notice Pins the `createEvent` IEventOracle capability gate. An oracle that is
///         approved but does not advertise IEventOracle via ERC-165 must be
///         rejected — binding an event to a binary-only oracle would leave it
///         unresolvable through `resolveEvent`.
contract EventOracleCapabilityTest is EventFixture {
    uint256 internal endTime;

    function setUp() public override {
        super.setUp();
        endTime = block.timestamp + 7 days;
    }

    function test_Revert_CreateEvent_OracleNotEventCapable() public {
        // `oracle` is the binary MockOracle (IOracle only, no IEventOracle ERC-165
        // advertisement) yet IS in the approved set — exercises the capability gate
        // beyond the approval gate.
        string[] memory qs = _defaultQuestions(2);
        vm.prank(alice);
        vm.expectRevert(IEventFacet.Event_OracleNotEventCapable.selector);
        eventFacet.createEvent("E", qs, endTime, address(oracle));
    }

    function test_CreateEvent_EventCapableOracle_Succeeds() public {
        // eventOracle (MockEventOracle) advertises IEventOracle via ERC-165.
        string[] memory qs = _defaultQuestions(2);
        vm.prank(alice);
        (uint256 eventId,) = eventFacet.createEvent("E", qs, endTime, address(eventOracle));
        assertEq(eventId, 1);
    }
}
