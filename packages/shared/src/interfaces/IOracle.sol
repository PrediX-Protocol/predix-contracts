// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

/// @title IOracle
/// @notice Minimal oracle interface PrediX markets use to resolve their binary outcome.
/// @dev Implementations live in `packages/oracle/`. A market stores an immutable oracle
///      address chosen from the diamond's approved-oracles set at creation time.
///      The diamond pulls the resolution; the oracle never pushes into the diamond.
interface IOracle {
    /// @notice Whether this oracle has produced a final answer for `marketId`.
    function isResolved(uint256 marketId) external view returns (bool);

    /// @notice Final outcome for `marketId`. `true` = YES wins, `false` = NO wins.
    /// @dev MUST revert if `!isResolved(marketId)`.
    function outcome(uint256 marketId) external view returns (bool);
}
