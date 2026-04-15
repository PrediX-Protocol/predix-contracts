// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

/// @title Roles
/// @notice Canonical role identifiers used by AccessControlFacet across the PrediX diamond.
/// @dev Cross-package consumers (hook, exchange, router, off-chain tooling) reference these
///      constants when querying or asserting role membership on the diamond.
library Roles {
    /// @notice Root admin role. Holder may grant or revoke any other role, including itself.
    /// @dev Mirrors OpenZeppelin's `DEFAULT_ADMIN_ROLE` value (`bytes32(0)`) so external
    ///      tooling that assumes the OZ convention keeps working.
    bytes32 internal constant DEFAULT_ADMIN_ROLE = 0x00;

    /// @notice System configuration role: fees, oracle whitelist, per-market caps, fee recipient.
    bytes32 internal constant ADMIN_ROLE = keccak256("predix.role.admin");

    /// @notice Operational role: emergency resolve and refund-mode activation.
    bytes32 internal constant OPERATOR_ROLE = keccak256("predix.role.operator");

    /// @notice Pause role: may pause/unpause modules or the entire diamond.
    bytes32 internal constant PAUSER_ROLE = keccak256("predix.role.pauser");

    /// @notice Execute-only role for `DiamondCutFacet.diamondCut`. Meant to be held
    ///         exclusively by an external `TimelockController` so all facet mutations
    ///         pass through a mandatory delay window. `DEFAULT_ADMIN_ROLE` alone is
    ///         insufficient to cut, closing the single-tx rug path.
    bytes32 internal constant CUT_EXECUTOR_ROLE = keccak256("predix.role.cut_executor");
}
