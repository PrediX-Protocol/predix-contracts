// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";

/// @title IPrediXHookCommit
/// @notice Minimal local copy of the `commitSwapIdentity` surface of `IPrediXHook`.
/// @dev Canonical interface lives at `packages/hook/src/interfaces/IPrediXHook.sol`. Copying
///      is required by `SC/CLAUDE.md §2`. The hook stores the commitment in EIP-1153 transient
///      storage scoped to the caller (the router) and poolId; it MUST be paired with an
///      immediately-following `poolManager.swap` in the same call frame. The router itself
///      must be in the hook's trusted-router set or the call reverts with `Hook_OnlyTrustedRouter`.
interface IPrediXHookCommit {
    /// @notice Record `user` as the real trader identity for any swap on `poolId` that the
    ///         router executes within the current transaction. Used by the hook's
    ///         anti-sandwich detector so back-to-back trades from different end users routed
    ///         through the same router address do not collide.
    function commitSwapIdentity(address user, PoolId poolId) external;

    /// @notice Pre-commit identity under another trusted caller's transient slot. The router
    ///         calls this before `V4Quoter.quoteExactInputSingle` to write `user` under
    ///         `_commitSlot(quoter, poolId)` so the quoter's simulate-and-revert path finds it.
    /// @param caller The address whose commit slot will be written (e.g., V4Quoter).
    /// @param user   The real end-user identity.
    /// @param poolId The pool the swap targets.
    function commitSwapIdentityFor(address caller, address user, PoolId poolId) external;
}
