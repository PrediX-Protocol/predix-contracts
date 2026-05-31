// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import {IDiamondCut} from "@predix/shared/interfaces/IDiamondCut.sol";
import {ILinkedEventFacet} from "@predix/shared/interfaces/ILinkedEventFacet.sol";

import {LinkedEventFacet} from "@predix/diamond/facets/event/LinkedEventFacet.sol";

import {EventFixture} from "./EventFixture.sol";

/// @notice Test harness for the Gap#1 shared-collateral engine. Builds on `EventFixture` (which already
///         wires MarketFacet + EventFacet + a MockEventOracle and grants `alice` CREATOR_ROLE), then
///         ADDs `LinkedEventFacet`. The MarketFacet/EventFacet instances compiled here already carry the
///         linked-aware split/merge + linked guards, so no REPLACE is needed in tests.
abstract contract LinkedEventFixture is EventFixture {
    LinkedEventFacet internal linkedFacetImpl;
    ILinkedEventFacet internal linked;

    function setUp() public virtual override {
        super.setUp();

        linkedFacetImpl = new LinkedEventFacet();

        IDiamondCut.FacetCut[] memory cuts = new IDiamondCut.FacetCut[](1);
        cuts[0] = _add(address(linkedFacetImpl), _linkedSelectors());

        vm.prank(timelock);
        diamondCut.diamondCut(cuts, address(0), "");

        linked = ILinkedEventFacet(address(diamond));
    }

    function _linkedSelectors() internal pure returns (bytes4[] memory s) {
        s = new bytes4[](6);
        s[0] = ILinkedEventFacet.createLinkedEvent.selector;
        s[1] = ILinkedEventFacet.mintCompleteSet.selector;
        s[2] = ILinkedEventFacet.redeemCompleteSet.selector;
        s[3] = ILinkedEventFacet.redeemLinked.selector;
        s[4] = ILinkedEventFacet.eventPoolOf.selector;
        s[5] = ILinkedEventFacet.isLinkedEvent.selector;
    }

    /// @notice Create a linked event with `n` candidates ending at `endTime`, driven by `alice`.
    function _createLinkedN(uint256 n, uint256 endTime) internal returns (uint256 eventId, uint256[] memory marketIds) {
        string[] memory qs = _defaultQuestions(n);
        vm.prank(alice);
        (eventId, marketIds) = linked.createLinkedEvent("Linked event", qs, endTime, address(eventOracle));
    }

    /// @notice Convenience: 3-candidate linked event.
    function _createLinked3(uint256 endTime) internal returns (uint256 eventId, uint256[] memory marketIds) {
        return _createLinkedN(3, endTime);
    }
}
