// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

/// @title IDiamondLoupe
/// @notice EIP-2535 diamond loupe interface for facet introspection.
interface IDiamondLoupe {
    struct Facet {
        address facetAddress;
        bytes4[] functionSelectors;
    }

    /// @notice Returns every facet and its selectors.
    function facets() external view returns (Facet[] memory);

    /// @notice Returns the selectors managed by `facet`.
    function facetFunctionSelectors(address facet) external view returns (bytes4[] memory);

    /// @notice Returns every facet address registered with the diamond.
    function facetAddresses() external view returns (address[] memory);

    /// @notice Returns the facet that implements `selector`, or `address(0)` if unimplemented.
    function facetAddress(bytes4 selector) external view returns (address);
}
