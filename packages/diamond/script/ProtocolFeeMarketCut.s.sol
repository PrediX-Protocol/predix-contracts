// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import {IDiamondCut} from "@predix/shared/interfaces/IDiamondCut.sol";
import {IDiamondLoupe} from "@predix/shared/interfaces/IDiamondLoupe.sol";
import {IMarketFacet} from "@predix/shared/interfaces/IMarketFacet.sol";
import {MarketFacet} from "@predix/diamond/facets/market/MarketFacet.sol";

/// @title ProtocolFeeMarketCut
/// @notice Single source of truth for the protocol-fee MarketFacet cut (Sub-plan 02). REPLACEs every live
///         MarketFacet selector with this tree's widened impl (MarketView +2 fields) and ADDs the new
///         protocol-fee config setters + getFeeConfig. MarketFacet ONLY (no EventFacet, no create-with-fee).
/// @dev Sub-plan 05 Task 1 Step 3. Mirrors RedemptionFeeCut.s.sol. Reads live routing so the cut self-corrects
///      + fails loud if the live set disagrees with the new impl. Pure builder — NEVER broadcasts.
contract ProtocolFeeMarketCut {
    function deployMarketFacet() external returns (address newMarketFacet) {
        newMarketFacet = address(new MarketFacet());
    }

    /// @dev Replace the live MarketFacet selector set + Add the 6 new selectors (5 protocol-fee config +
    ///      getFeeConfig, Sub-plan 02 Task 6). setMarketCreationFee gains a cap but its selector is unchanged
    ///      → it stays in the Replace set. The Add list must NOT contain any selector already routed live, or
    ///      the diamondCut reverts (the Task 3 fork-sim catches this loud).
    function buildCuts(address diamond, address newMarketFacet)
        external
        view
        returns (IDiamondCut.FacetCut[] memory cuts)
    {
        IDiamondLoupe loupe = IDiamondLoupe(diamond);
        address liveMarket = loupe.facetAddress(IMarketFacet.createMarket.selector);
        require(liveMarket != address(0), "live MarketFacet not found");
        bytes4[] memory marketSel = loupe.facetFunctionSelectors(liveMarket);

        bytes4[] memory addSel = new bytes4[](6);
        addSel[0] = IMarketFacet.setDefaultProtocolFeeRateBps.selector;
        addSel[1] = IMarketFacet.setPerMarketProtocolFeeRateBps.selector;
        addSel[2] = IMarketFacet.clearPerMarketProtocolFee.selector;
        addSel[3] = IMarketFacet.setProtocolMakerRebateBps.selector;
        addSel[4] = IMarketFacet.effectiveProtocolFee.selector;
        addSel[5] = IMarketFacet.getFeeConfig.selector; // Mức-1 fee module (Sub-plan 02 Task 6)

        cuts = new IDiamondCut.FacetCut[](2);
        cuts[0] = IDiamondCut.FacetCut(newMarketFacet, IDiamondCut.FacetCutAction.Replace, marketSel);
        cuts[1] = IDiamondCut.FacetCut(newMarketFacet, IDiamondCut.FacetCutAction.Add, addSel);
    }
}
