// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

/// @title LibDiamondStorage
/// @notice Diamond storage layout for EIP-2535 cut + loupe state and ERC-165 registry.
/// @dev Slot is namespaced by `keccak256("predix.storage.diamond.v1")` so it never collides
///      with any facet's own diamond-storage slot.
library LibDiamondStorage {
    bytes32 internal constant SLOT = keccak256("predix.storage.diamond.v1");

    struct FacetAddressAndPosition {
        address facetAddress;
        uint96 functionSelectorPosition;
    }

    struct FacetFunctionSelectors {
        bytes4[] functionSelectors;
        uint256 facetAddressPosition;
    }

    struct Layout {
        mapping(bytes4 => FacetAddressAndPosition) selectorToFacetAndPosition;
        mapping(address => FacetFunctionSelectors) facetFunctionSelectors;
        address[] facetAddresses;
        mapping(bytes4 => bool) supportedInterfaces;
        mapping(bytes4 => bool) immutableSelectors;
    }

    function layout() internal pure returns (Layout storage l) {
        bytes32 slot = SLOT;
        assembly ("memory-safe") {
            l.slot := slot
        }
    }
}
