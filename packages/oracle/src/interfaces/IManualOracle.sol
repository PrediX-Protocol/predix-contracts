// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import {IOracle} from "@predix/shared/interfaces/IOracle.sol";
import {IEventOracle} from "@predix/shared/interfaces/IEventOracle.sol";

/// @title IManualOracle
/// @notice Human-curated oracle for both binary markets and multi-outcome events.
///         A trusted reporter submits outcomes by hand; an admin can revoke before
///         the diamond consumes the answer.
/// @dev Implements `IOracle` (binary) AND `IEventOracle` (events). Each deployment
///      is bound to a single diamond at construction so `report`/`reportEvent` can
///      enforce timing gates via diamond status views.
interface IManualOracle is IOracle, IEventOracle {
    // -- Binary market events/errors --

    event OutcomeReported(uint256 indexed marketId, bool outcome, address indexed reporter);
    event OutcomeRevoked(uint256 indexed marketId, address indexed admin);

    error ManualOracle_ZeroAdmin();
    error ManualOracle_ZeroDiamond();
    error ManualOracle_AlreadyReported();
    error ManualOracle_NotReported();
    error ManualOracle_Frozen();
    error ManualOracle_BeforeMarketEnd();

    // -- Event events/errors --

    event EventOutcomeReported(uint256 indexed eventId, uint256 winningIndex, address indexed reporter);
    event EventOutcomeRevoked(uint256 indexed eventId, address indexed admin);

    error ManualOracle_EventAlreadyReported();
    error ManualOracle_EventNotReported();
    error ManualOracle_EventFrozen();
    error ManualOracle_BeforeEventEnd();
    error ManualOracle_InvalidWinningIndex();

    // -- Binary market functions --

    /// @notice Publish the final outcome for a binary market.
    /// @param marketId The diamond market identifier to resolve.
    /// @param outcome  `true` if YES wins, `false` if NO wins.
    function report(uint256 marketId, bool outcome) external;

    /// @notice Tombstone a binary market outcome. Slot is frozen after revoke.
    /// @param marketId The diamond market identifier to clear.
    function revoke(uint256 marketId) external;

    // -- Event functions --

    /// @notice Publish the winning candidate index for a multi-outcome event.
    /// @param eventId      The diamond event identifier.
    /// @param winningIndex Index into the event's candidates array.
    function reportEvent(uint256 eventId, uint256 winningIndex) external;

    /// @notice Tombstone a previously reported event outcome. Slot is frozen.
    /// @param eventId The diamond event identifier to clear.
    function revokeEvent(uint256 eventId) external;
}
