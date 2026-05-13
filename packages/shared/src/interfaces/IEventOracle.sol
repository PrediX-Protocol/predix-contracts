// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

/// @title IEventOracle
/// @notice Oracle interface for multi-outcome event resolution. Parallel to `IOracle`
///         (binary markets) but returns a `uint256 winningIndex` instead of `bool`.
/// @dev Implementations that support both binary and event resolution (e.g. ManualOracle)
///      implement `IOracle` AND `IEventOracle`. The diamond pulls the resolution via
///      `EventFacet.resolveEvent`; the oracle never pushes into the diamond.
interface IEventOracle {
    /// @notice Whether this oracle has produced a final answer for `eventId`.
    function isEventResolved(uint256 eventId) external view returns (bool);

    /// @notice Winning candidate index for `eventId`. Index into the event's
    ///         `marketIds` array — the child at this position wins (outcome=true),
    ///         all others lose (outcome=false).
    /// @dev MUST revert if `!isEventResolved(eventId)`.
    function eventOutcome(uint256 eventId) external view returns (uint256);
}
