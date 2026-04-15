// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";

import {IDiamondLoupe} from "@predix/shared/interfaces/IDiamondLoupe.sol";

import {LibDiamondStorage} from "@predix/diamond/libraries/LibDiamondStorage.sol";

/// @title DiamondLoupeFacet
/// @notice EIP-2535 loupe + ERC-165 introspection facet.
contract DiamondLoupeFacet is IDiamondLoupe, IERC165 {
    /// @inheritdoc IDiamondLoupe
    function facets() external view override returns (Facet[] memory result) {
        LibDiamondStorage.Layout storage ds = LibDiamondStorage.layout();
        uint256 numFacets = ds.facetAddresses.length;
        result = new Facet[](numFacets);
        for (uint256 i; i < numFacets; ++i) {
            address facet = ds.facetAddresses[i];
            result[i] =
                Facet({facetAddress: facet, functionSelectors: ds.facetFunctionSelectors[facet].functionSelectors});
        }
    }

    /// @inheritdoc IDiamondLoupe
    function facetFunctionSelectors(address facet) external view override returns (bytes4[] memory) {
        return LibDiamondStorage.layout().facetFunctionSelectors[facet].functionSelectors;
    }

    /// @inheritdoc IDiamondLoupe
    function facetAddresses() external view override returns (address[] memory) {
        return LibDiamondStorage.layout().facetAddresses;
    }

    /// @inheritdoc IDiamondLoupe
    function facetAddress(bytes4 selector) external view override returns (address) {
        return LibDiamondStorage.layout().selectorToFacetAndPosition[selector].facetAddress;
    }

    /// @inheritdoc IERC165
    function supportsInterface(bytes4 interfaceId) external view override returns (bool) {
        return LibDiamondStorage.layout().supportedInterfaces[interfaceId];
    }
}
