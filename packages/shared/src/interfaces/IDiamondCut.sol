// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

/// @title IDiamondCut
/// @notice EIP-2535 diamond cut interface.
/// @dev See https://eips.ethereum.org/EIPS/eip-2535
interface IDiamondCut {
    enum FacetCutAction {
        Add,
        Replace,
        Remove
    }

    struct FacetCut {
        address facetAddress;
        FacetCutAction action;
        bytes4[] functionSelectors;
    }

    /// @notice Emitted on every successful `diamondCut`.
    event DiamondCut(FacetCut[] cut, address init, bytes initData);

    error DiamondCut_NoSelectors();
    error DiamondCut_AddZeroAddress();
    error DiamondCut_AddExistingSelector(bytes4 selector);
    error DiamondCut_ReplaceZeroAddress();
    error DiamondCut_ReplaceMissingSelector(bytes4 selector);
    error DiamondCut_ReplaceSameFacet(bytes4 selector);
    error DiamondCut_RemoveNonZeroAddress();
    error DiamondCut_RemoveMissingSelector(bytes4 selector);
    error DiamondCut_RemoveImmutableSelector(bytes4 selector);
    error DiamondCut_FacetHasNoCode(address facet);
    error DiamondCut_InitHasNoCode(address init);
    error DiamondCut_InitReverted(bytes data);
    error DiamondCut_InitWithoutData();
    error DiamondCut_DataWithoutInit();

    /// @notice Add, replace or remove facet selectors and optionally execute an init contract.
    /// @param cut       List of facet operations to apply atomically.
    /// @param init      Address of the init contract to delegatecall, or `address(0)` for no init.
    /// @param initData  ABI-encoded calldata passed to the init contract.
    function diamondCut(FacetCut[] calldata cut, address init, bytes calldata initData) external;
}
