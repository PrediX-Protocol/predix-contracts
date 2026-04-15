// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

/// @title Modules
/// @notice Identifiers for pausable modules inside the PrediX diamond.
/// @dev PausableFacet supports both a global pause flag and per-module pause flags
///      so an incident in one subsystem does not freeze the entire protocol.
library Modules {
    /// @notice Market lifecycle module: createMarket, split, merge, resolve, redeem, refund.
    bytes32 internal constant MARKET = keccak256("predix.module.market");

    /// @notice Diamond infrastructure module. Gates `diamondCut` so incident
    ///         response can freeze facet mutation without also freezing the
    ///         market lifecycle module (or vice versa).
    bytes32 internal constant DIAMOND = keccak256("predix.module.diamond");
}
