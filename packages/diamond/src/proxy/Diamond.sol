// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {IDiamondCut} from "@predix/shared/interfaces/IDiamondCut.sol";
import {Roles} from "@predix/shared/constants/Roles.sol";

import {LibAccessControl} from "@predix/diamond/libraries/LibAccessControl.sol";
import {LibDiamond} from "@predix/diamond/libraries/LibDiamond.sol";
import {LibDiamondStorage} from "@predix/diamond/libraries/LibDiamondStorage.sol";

/// @title Diamond
/// @notice EIP-2535 proxy. The constructor grants `DEFAULT_ADMIN_ROLE` to `admin`, applies an
///         initial set of facet cuts, and optionally delegatecalls an init contract — all in
///         one atomic step so the diamond is fully usable after deployment.
/// @dev `receive()` is intentionally absent; bare ETH transfers fall through to `fallback()`
///      with an empty selector and revert via `Diamond_FunctionNotFound(0)`. This prevents
///      accidental ETH lockup since PrediX is USDC-only.
contract Diamond {
    error Diamond_ZeroAdmin();
    error Diamond_FunctionNotFound(bytes4 selector);

    constructor(address admin, IDiamondCut.FacetCut[] memory cuts, address init, bytes memory initData) {
        if (admin == address(0)) revert Diamond_ZeroAdmin();
        LibAccessControl.grantRole(Roles.DEFAULT_ADMIN_ROLE, admin);
        LibDiamond.diamondCut(cuts, init, initData);
    }

    fallback() external payable {
        LibDiamondStorage.Layout storage ds = LibDiamondStorage.layout();
        address facet = ds.selectorToFacetAndPosition[msg.sig].facetAddress;
        if (facet == address(0)) revert Diamond_FunctionNotFound(msg.sig);
        assembly {
            calldatacopy(0, 0, calldatasize())
            let result := delegatecall(gas(), facet, 0, calldatasize(), 0, 0)
            returndatacopy(0, 0, returndatasize())
            switch result
            case 0 { revert(0, returndatasize()) }
            default { return(0, returndatasize()) }
        }
    }
}
