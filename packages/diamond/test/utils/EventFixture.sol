// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {IDiamondCut} from "@predix/shared/interfaces/IDiamondCut.sol";
import {IEventFacet} from "@predix/shared/interfaces/IEventFacet.sol";

import {EventFacet} from "@predix/diamond/facets/event/EventFacet.sol";

import {MarketFixture} from "./MarketFixture.sol";

abstract contract EventFixture is MarketFixture {
    EventFacet internal eventFacetImpl;
    IEventFacet internal eventFacet;

    function setUp() public virtual override {
        super.setUp();

        eventFacetImpl = new EventFacet();

        IDiamondCut.FacetCut[] memory cuts = new IDiamondCut.FacetCut[](1);
        cuts[0] = _add(address(eventFacetImpl), _eventSelectors());

        vm.prank(timelock);
        diamondCut.diamondCut(cuts, address(0), "");

        eventFacet = IEventFacet(address(diamond));
    }

    function _eventSelectors() internal pure returns (bytes4[] memory s) {
        s = new bytes4[](6);
        s[0] = IEventFacet.createEvent.selector;
        s[1] = IEventFacet.resolveEvent.selector;
        s[2] = IEventFacet.enableEventRefundMode.selector;
        s[3] = IEventFacet.getEvent.selector;
        s[4] = IEventFacet.eventOfMarket.selector;
        s[5] = IEventFacet.eventCount.selector;
    }

    function _defaultQuestions(uint256 n) internal pure returns (string[] memory qs) {
        qs = new string[](n);
        for (uint256 i; i < n; ++i) {
            qs[i] = string.concat("Candidate #", _toString(i + 1));
        }
    }

    function _createThreeCandidateEvent(uint256 endTime)
        internal
        returns (uint256 eventId, uint256[] memory marketIds)
    {
        string[] memory qs = _defaultQuestions(3);
        vm.prank(alice);
        (eventId, marketIds) = eventFacet.createEvent("Who wins?", qs, endTime);
    }

    function _createNCandidateEvent(uint256 n, uint256 endTime)
        internal
        returns (uint256 eventId, uint256[] memory marketIds)
    {
        string[] memory qs = _defaultQuestions(n);
        vm.prank(alice);
        (eventId, marketIds) = eventFacet.createEvent("Event", qs, endTime);
    }

    function _toString(uint256 v) private pure returns (string memory) {
        if (v == 0) return "0";
        uint256 tmp = v;
        uint256 digits;
        while (tmp != 0) {
            digits++;
            tmp /= 10;
        }
        bytes memory buf = new bytes(digits);
        while (v != 0) {
            digits -= 1;
            buf[digits] = bytes1(uint8(48 + v % 10));
            v /= 10;
        }
        return string(buf);
    }
}
