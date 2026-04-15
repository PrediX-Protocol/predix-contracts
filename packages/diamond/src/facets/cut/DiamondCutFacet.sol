// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {IDiamondCut} from "@predix/shared/interfaces/IDiamondCut.sol";
import {Modules} from "@predix/shared/constants/Modules.sol";
import {Roles} from "@predix/shared/constants/Roles.sol";

import {LibAccessControl} from "@predix/diamond/libraries/LibAccessControl.sol";
import {LibDiamond} from "@predix/diamond/libraries/LibDiamond.sol";
import {LibPausable} from "@predix/diamond/libraries/LibPausable.sol";

/// @title DiamondCutFacet
/// @notice EIP-2535 cut facet. Restricted to `CUT_EXECUTOR_ROLE` — intended to be
///         held only by an external TimelockController so every facet mutation
///         clears a mandatory delay. Also honours the diamond-scoped pause so
///         incident response can freeze cuts mid-flight.
contract DiamondCutFacet is IDiamondCut {
    /// @inheritdoc IDiamondCut
    function diamondCut(FacetCut[] calldata cut, address init, bytes calldata initData) external override {
        LibAccessControl.checkRole(Roles.CUT_EXECUTOR_ROLE);
        LibPausable.enforceNotPaused(Modules.DIAMOND);
        LibDiamond.diamondCut(cut, init, initData);
    }
}
