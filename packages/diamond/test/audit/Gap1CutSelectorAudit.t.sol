// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import {IDiamondLoupe} from "@predix/shared/interfaces/IDiamondLoupe.sol";
import {IEventFacet} from "@predix/shared/interfaces/IEventFacet.sol";
import {IMarketFacet} from "@predix/shared/interfaces/IMarketFacet.sol";

import {EventFixture} from "../utils/EventFixture.sol";

/// @title Gap1CutSelectorAudit
/// @notice AUDIT (diamond-cut lens). Selector-wiring regression lock for the CONSOLIDATED event
///         facet: every event selector (lifecycle + views + shared-pool ops) routes to the single
///         EventFacet impl, the set is pairwise distinct, never aliases a market selector, and the
///         diamond has no duplicate route. Mirrors the static `forge inspect methodIdentifiers`
///         set-equality check and guards the Phase-3 consolidation cut's selector list.
/// @dev Audit-only; no engine src touched. The fixture wires Market+Event, so loupe routing here is
///      equivalent to the post-cut diamond state the consolidation script must produce.
contract Gap1CutSelectorAudit is EventFixture {
    function _consolidatedEventSelectors() private pure returns (bytes4[] memory s) {
        s = new bytes4[](13);
        s[0] = IEventFacet.createEvent.selector;
        s[1] = IEventFacet.resolveEvent.selector;
        s[2] = IEventFacet.emergencyResolveEvent.selector;
        s[3] = IEventFacet.enableEventRefundMode.selector;
        s[4] = IEventFacet.getEvent.selector;
        s[5] = IEventFacet.getEventStatus.selector;
        s[6] = IEventFacet.eventOfMarket.selector;
        s[7] = IEventFacet.eventCount.selector;
        s[8] = IEventFacet.sweepUnclaimedEvent.selector;
        s[9] = IEventFacet.splitEvent.selector;
        s[10] = IEventFacet.mergeEvent.selector;
        s[11] = IEventFacet.redeemEvent.selector;
        s[12] = IEventFacet.eventPoolOf.selector;
    }

    /// @dev Every consolidated event selector must route to the single EventFacet impl.
    function test_EventSelectors_RouteToConsolidatedFacet() public view {
        IDiamondLoupe loupe = IDiamondLoupe(address(diamond));
        bytes4[] memory sels = _consolidatedEventSelectors();
        for (uint256 i; i < sels.length; ++i) {
            assertEq(loupe.facetAddress(sels[i]), address(eventFacetImpl), "event selector mis-routed");
        }
        assertEq(
            loupe.facetFunctionSelectors(address(eventFacetImpl)).length,
            sels.length,
            "consolidated facet carries a stowaway selector"
        );
    }

    /// @dev The consolidated set must be pairwise distinct — the precondition for the Phase-3
    ///      `diamondCut` Add/Replace list not to revert with a selector clash.
    function test_EventSelectors_PairwiseDistinct() public pure {
        bytes4[] memory sels = _consolidatedEventSelectors();
        for (uint256 i; i < sels.length; ++i) {
            for (uint256 j = i + 1; j < sels.length; ++j) {
                assertTrue(sels[i] != sels[j], "duplicate selector within event set");
            }
        }
    }

    /// @dev Cross-facet integrity: market selectors route to the MarketFacet and never alias an
    ///      event selector — proving the consolidation Replace/Add set cannot orphan a market route.
    function test_MarketRoutesDistinctFromEvent() public view {
        IDiamondLoupe loupe = IDiamondLoupe(address(diamond));
        bytes4[] memory eventSels = _consolidatedEventSelectors();

        bytes4[3] memory marketProbe =
            [IMarketFacet.splitPosition.selector, IMarketFacet.redeem.selector, IMarketFacet.rescueSurplus.selector];
        for (uint256 i; i < marketProbe.length; ++i) {
            assertEq(loupe.facetAddress(marketProbe[i]), address(marketFacet), "market selector mis-routed");
            for (uint256 j; j < eventSels.length; ++j) {
                assertTrue(marketProbe[i] != eventSels[j], "market selector aliases an event selector");
            }
        }
    }

    /// @dev Retired legacy selectors must be UNROUTED on a fresh consolidated deploy: the old
    ///      LinkedEventFacet ops and addEventOutcome (raw 4-byte ids — the functions no longer
    ///      exist in source). The Phase-3 cut must Remove them on the live diamond too.
    function test_LegacySelectors_Unrouted() public view {
        IDiamondLoupe loupe = IDiamondLoupe(address(diamond));
        bytes4[6] memory legacy = [
            bytes4(0xa4128ef7), // createLinkedEvent(string,string[],uint256,address)
            bytes4(0x8578313a), // mintCompleteSet(uint256,uint256)
            bytes4(0x754c7ec3), // redeemCompleteSet(uint256,uint256)
            bytes4(0xf1f30c1a), // redeemLinked(uint256)
            bytes4(0xc3bacd82), // isLinkedEvent(uint256)
            bytes4(0x1a0dcf36) // addEventOutcome(uint256,string)
        ];
        for (uint256 i; i < legacy.length; ++i) {
            assertEq(loupe.facetAddress(legacy[i]), address(0), "legacy selector still routed");
        }
    }

    /// @dev Whole-diamond integrity: no selector is served by two facets (a Replace/Add that double-registers
    ///      would surface here). Iterates the full loupe facet list.
    function test_NoDuplicateSelectorAcrossDiamond() public view {
        IDiamondLoupe loupe = IDiamondLoupe(address(diamond));
        IDiamondLoupe.Facet[] memory facets = loupe.facets();
        bytes4[] memory seen = new bytes4[](256);
        uint256 count;
        for (uint256 f; f < facets.length; ++f) {
            bytes4[] memory sels = facets[f].functionSelectors;
            for (uint256 s; s < sels.length; ++s) {
                for (uint256 k; k < count; ++k) {
                    assertTrue(seen[k] != sels[s], "duplicate selector across diamond facets");
                }
                seen[count++] = sels[s];
            }
        }
        assertGt(count, 40, "sanity: diamond should expose >40 selectors");
    }
}
