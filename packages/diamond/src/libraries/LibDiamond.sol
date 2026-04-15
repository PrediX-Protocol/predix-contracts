// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {IDiamondCut} from "@predix/shared/interfaces/IDiamondCut.sol";

import {LibDiamondStorage} from "@predix/diamond/libraries/LibDiamondStorage.sol";

/// @title LibDiamond
/// @notice Internal helpers that mutate the EIP-2535 facet registry. Auth is the caller's
///         responsibility — the facet that exposes `diamondCut` must check the role first.
library LibDiamond {
    function diamondCut(IDiamondCut.FacetCut[] memory cuts, address init, bytes memory initData) internal {
        for (uint256 i; i < cuts.length; ++i) {
            IDiamondCut.FacetCutAction action = cuts[i].action;
            if (action == IDiamondCut.FacetCutAction.Add) {
                _addFunctions(cuts[i].facetAddress, cuts[i].functionSelectors);
            } else if (action == IDiamondCut.FacetCutAction.Replace) {
                _replaceFunctions(cuts[i].facetAddress, cuts[i].functionSelectors);
            } else {
                _removeFunctions(cuts[i].facetAddress, cuts[i].functionSelectors);
            }
        }
        emit IDiamondCut.DiamondCut(cuts, init, initData);
        _initialize(init, initData);
    }

    function _addFunctions(address facet, bytes4[] memory selectors) private {
        if (selectors.length == 0) revert IDiamondCut.DiamondCut_NoSelectors();
        if (facet == address(0)) revert IDiamondCut.DiamondCut_AddZeroAddress();
        _enforceHasContractCode(facet, true);

        LibDiamondStorage.Layout storage ds = LibDiamondStorage.layout();
        uint96 selectorPosition = uint96(ds.facetFunctionSelectors[facet].functionSelectors.length);

        if (selectorPosition == 0) {
            ds.facetFunctionSelectors[facet].facetAddressPosition = ds.facetAddresses.length;
            ds.facetAddresses.push(facet);
        }

        for (uint256 i; i < selectors.length; ++i) {
            bytes4 selector = selectors[i];
            if (ds.selectorToFacetAndPosition[selector].facetAddress != address(0)) {
                revert IDiamondCut.DiamondCut_AddExistingSelector(selector);
            }
            ds.facetFunctionSelectors[facet].functionSelectors.push(selector);
            ds.selectorToFacetAndPosition[selector] = LibDiamondStorage.FacetAddressAndPosition({
                facetAddress: facet, functionSelectorPosition: selectorPosition
            });
            selectorPosition++;
        }
    }

    function _replaceFunctions(address facet, bytes4[] memory selectors) private {
        if (selectors.length == 0) revert IDiamondCut.DiamondCut_NoSelectors();
        if (facet == address(0)) revert IDiamondCut.DiamondCut_ReplaceZeroAddress();
        _enforceHasContractCode(facet, true);

        LibDiamondStorage.Layout storage ds = LibDiamondStorage.layout();
        uint96 selectorPosition = uint96(ds.facetFunctionSelectors[facet].functionSelectors.length);

        if (selectorPosition == 0) {
            ds.facetFunctionSelectors[facet].facetAddressPosition = ds.facetAddresses.length;
            ds.facetAddresses.push(facet);
        }

        for (uint256 i; i < selectors.length; ++i) {
            bytes4 selector = selectors[i];
            address oldFacet = ds.selectorToFacetAndPosition[selector].facetAddress;
            if (oldFacet == address(0)) revert IDiamondCut.DiamondCut_ReplaceMissingSelector(selector);
            if (oldFacet == facet) revert IDiamondCut.DiamondCut_ReplaceSameFacet(selector);
            if (ds.immutableSelectors[selector]) revert IDiamondCut.DiamondCut_RemoveImmutableSelector(selector);

            _removeSelectorFromFacet(ds, oldFacet, selector);

            ds.facetFunctionSelectors[facet].functionSelectors.push(selector);
            ds.selectorToFacetAndPosition[selector] = LibDiamondStorage.FacetAddressAndPosition({
                facetAddress: facet, functionSelectorPosition: selectorPosition
            });
            selectorPosition++;
        }
    }

    function _removeFunctions(address facet, bytes4[] memory selectors) private {
        if (selectors.length == 0) revert IDiamondCut.DiamondCut_NoSelectors();
        if (facet != address(0)) revert IDiamondCut.DiamondCut_RemoveNonZeroAddress();

        LibDiamondStorage.Layout storage ds = LibDiamondStorage.layout();

        for (uint256 i; i < selectors.length; ++i) {
            bytes4 selector = selectors[i];
            address oldFacet = ds.selectorToFacetAndPosition[selector].facetAddress;
            if (oldFacet == address(0)) revert IDiamondCut.DiamondCut_RemoveMissingSelector(selector);
            if (ds.immutableSelectors[selector]) revert IDiamondCut.DiamondCut_RemoveImmutableSelector(selector);
            _removeSelectorFromFacet(ds, oldFacet, selector);
        }
    }

    function _removeSelectorFromFacet(LibDiamondStorage.Layout storage ds, address facet, bytes4 selector) private {
        uint256 selectorPosition = ds.selectorToFacetAndPosition[selector].functionSelectorPosition;
        uint256 lastSelectorPosition = ds.facetFunctionSelectors[facet].functionSelectors.length - 1;

        if (selectorPosition != lastSelectorPosition) {
            bytes4 lastSelector = ds.facetFunctionSelectors[facet].functionSelectors[lastSelectorPosition];
            ds.facetFunctionSelectors[facet].functionSelectors[selectorPosition] = lastSelector;
            ds.selectorToFacetAndPosition[lastSelector].functionSelectorPosition = uint96(selectorPosition);
        }
        ds.facetFunctionSelectors[facet].functionSelectors.pop();
        delete ds.selectorToFacetAndPosition[selector];

        if (lastSelectorPosition == 0) {
            uint256 facetAddressPosition = ds.facetFunctionSelectors[facet].facetAddressPosition;
            uint256 lastFacetAddressPosition = ds.facetAddresses.length - 1;
            if (facetAddressPosition != lastFacetAddressPosition) {
                address lastFacet = ds.facetAddresses[lastFacetAddressPosition];
                ds.facetAddresses[facetAddressPosition] = lastFacet;
                ds.facetFunctionSelectors[lastFacet].facetAddressPosition = facetAddressPosition;
            }
            ds.facetAddresses.pop();
            delete ds.facetFunctionSelectors[facet].facetAddressPosition;
        }
    }

    function _initialize(address init, bytes memory initData) private {
        if (init == address(0)) {
            if (initData.length != 0) revert IDiamondCut.DiamondCut_DataWithoutInit();
            return;
        }
        if (initData.length == 0) revert IDiamondCut.DiamondCut_InitWithoutData();
        _enforceHasContractCode(init, false);

        (bool success, bytes memory result) = init.delegatecall(initData);
        if (!success) {
            if (result.length == 0) revert IDiamondCut.DiamondCut_InitReverted(result);
            assembly ("memory-safe") {
                revert(add(result, 0x20), mload(result))
            }
        }
    }

    function _enforceHasContractCode(address target, bool isFacet) private view {
        uint256 size;
        assembly ("memory-safe") {
            size := extcodesize(target)
        }
        if (size == 0) {
            if (isFacet) revert IDiamondCut.DiamondCut_FacetHasNoCode(target);
            revert IDiamondCut.DiamondCut_InitHasNoCode(target);
        }
    }
}
