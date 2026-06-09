// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import {IDiamondCut} from "@predix/shared/interfaces/IDiamondCut.sol";
import {IDiamondLoupe} from "@predix/shared/interfaces/IDiamondLoupe.sol";
import {IMarketFacet} from "@predix/shared/interfaces/IMarketFacet.sol";
import {IEventFacet} from "@predix/shared/interfaces/IEventFacet.sol";

import {MarketFacet} from "@predix/diamond/facets/market/MarketFacet.sol";
import {EventFacet} from "@predix/diamond/facets/event/EventFacet.sol";

/// @title RedemptionFeeCut
/// @notice Single source of truth for the keyti-fqn8 redemption-fee diamond cut. The change is
///         implementation-only on the existing MarketFacet + EventFacet selectors (per-child redemption
///         fee, read-time cap clamp, lower-after-end remediation) plus TWO new selectors
///         (`createMarketWithFee`, `createEventWithFee`). The cut therefore REPLACEs every live
///         MarketFacet/EventFacet selector with this tree's impls and ADDs the two new ones — no Remove.
/// @dev Used by `RedemptionFeeCutForkSim` (fork dry-run, applied as the Timelock) and, once the owner
///      approves the mainnet cut, by the broadcast orchestration that deploys the impls + schedules the
///      Timelock operation. This helper never broadcasts on its own.
contract RedemptionFeeCut {
    /// @notice Deploy both new facet impls. In a fork/test EVM this is a plain deploy; the mainnet
    ///         broadcast wraps the call in `vm.broadcast`.
    function deployFacets() external returns (address newMarketFacet, address newEventFacet) {
        newMarketFacet = address(new MarketFacet());
        newEventFacet = address(new EventFacet());
    }

    /// @notice Build the Replace+Add cut against the diamond's CURRENT routing.
    /// @dev Reads the live MarketFacet/EventFacet selector sets via the loupe and REPLACEs exactly those
    ///      (this tree's impls are supersets), then ADDs the two create-with-fee selectors. Reading live
    ///      routing makes the cut self-correct against whatever set is deployed — a Replace of a selector
    ///      absent from the new impl, or an Add of an already-routed selector, makes `diamondCut` revert,
    ///      so the fork sim provably fails loud if the impls and the live set ever disagree.
    /// @param diamond         The live diamond proxy.
    /// @param newMarketFacet  Freshly deployed MarketFacet impl (this source tree).
    /// @param newEventFacet   Freshly deployed EventFacet impl (this source tree).
    function buildCuts(address diamond, address newMarketFacet, address newEventFacet)
        external
        view
        returns (IDiamondCut.FacetCut[] memory cuts)
    {
        IDiamondLoupe loupe = IDiamondLoupe(diamond);
        address liveMarket = loupe.facetAddress(IMarketFacet.createMarket.selector);
        address liveEvent = loupe.facetAddress(IEventFacet.createEvent.selector);
        require(liveMarket != address(0), "live MarketFacet not found");
        require(liveEvent != address(0), "live EventFacet not found");

        bytes4[] memory marketSel = loupe.facetFunctionSelectors(liveMarket);
        bytes4[] memory eventSel = loupe.facetFunctionSelectors(liveEvent);

        bytes4[] memory addMarket = new bytes4[](1);
        addMarket[0] = IMarketFacet.createMarketWithFee.selector;
        bytes4[] memory addEvent = new bytes4[](1);
        addEvent[0] = IEventFacet.createEventWithFee.selector;

        cuts = new IDiamondCut.FacetCut[](4);
        cuts[0] = IDiamondCut.FacetCut(newMarketFacet, IDiamondCut.FacetCutAction.Replace, marketSel);
        cuts[1] = IDiamondCut.FacetCut(newMarketFacet, IDiamondCut.FacetCutAction.Add, addMarket);
        cuts[2] = IDiamondCut.FacetCut(newEventFacet, IDiamondCut.FacetCutAction.Replace, eventSel);
        cuts[3] = IDiamondCut.FacetCut(newEventFacet, IDiamondCut.FacetCutAction.Add, addEvent);
    }
}
