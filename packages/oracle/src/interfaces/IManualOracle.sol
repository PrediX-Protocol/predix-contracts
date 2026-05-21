// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import {IOracle} from "@predix/shared/interfaces/IOracle.sol";
import {IEventOracle} from "@predix/shared/interfaces/IEventOracle.sol";

/// @title IManualOracle
/// @notice Human-curated oracle for both binary markets and multi-outcome events.
///         A trusted reporter submits outcomes by hand; within an optional
///         challenge window an admin can revoke (abandon) or reopen (correct)
///         before the diamond consumes the answer.
/// @dev Implements `IOracle` (binary) AND `IEventOracle` (events). Each deployment
///      is bound to a single diamond at construction so `report`/`reportEvent` can
///      enforce timing gates via diamond status views.
interface IManualOracle is IOracle, IEventOracle {
    // -- Binary market events/errors --

    event OutcomeReported(uint256 indexed marketId, bool outcome, address indexed reporter);
    event OutcomeRevoked(uint256 indexed marketId, address indexed admin);
    /// @notice Emitted when the admin changes the global challenge delay.
    event ChallengeDelayUpdated(uint256 previous, uint256 current);
    /// @notice Emitted when the admin reopens a binary report within its challenge
    ///         window so the reporter can publish a corrected outcome.
    event ReportReopened(uint256 indexed marketId, address indexed admin);

    error ManualOracle_ZeroAdmin();
    error ManualOracle_ZeroDiamond();
    error ManualOracle_AlreadyReported();
    error ManualOracle_NotReported();
    error ManualOracle_Frozen();
    error ManualOracle_BeforeMarketEnd();
    /// @notice Reverts when `outcome`/`eventOutcome` is read before the challenge
    ///         window closes (`block.timestamp < finalizesAt`); `isResolved` /
    ///         `isEventResolved` is false in that window.
    error ManualOracle_NotFinalized();
    /// @notice Reverts when `setChallengeDelay` exceeds `MAX_CHALLENGE_DELAY`.
    error ManualOracle_DelayTooLong();
    /// @notice Reverts when `reopenReport`/`reopenEventReport` is called outside an
    ///         active report's challenge window (not reported, or already finalized).
    error ManualOracle_ChallengeWindowClosed();
    /// @notice Reverts when a revoke/renounce would remove the final
    ///         `DEFAULT_ADMIN_ROLE` holder. An empty admin set is irrecoverable:
    ///         no `REPORTER_ROLE` could ever be rotated and `setChallengeDelay`
    ///         would freeze permanently.
    error ManualOracle_LastAdmin();

    // -- Event events/errors --

    event EventOutcomeReported(uint256 indexed eventId, uint256 winningIndex, address indexed reporter);
    event EventOutcomeRevoked(uint256 indexed eventId, address indexed admin);
    /// @notice Emitted when the admin reopens an event report within its challenge
    ///         window so the reporter can publish a corrected winning index.
    event EventReportReopened(uint256 indexed eventId, address indexed admin);

    error ManualOracle_EventAlreadyReported();
    error ManualOracle_EventNotReported();
    error ManualOracle_EventFrozen();
    error ManualOracle_BeforeEventEnd();
    error ManualOracle_InvalidWinningIndex();

    // -- Admin config --

    /// @notice Set the global challenge delay (seconds) applied to subsequent reports.
    ///         `0` = immediate finalization (legacy). Capped at `MAX_CHALLENGE_DELAY`.
    /// @dev Snapshotted into each report's `finalizesAt` at report time, so changing
    ///      it never alters an already-reported market's window.
    function setChallengeDelay(uint256 newDelay) external;

    // -- Binary market functions --

    /// @notice Publish the final outcome for a binary market.
    /// @param marketId The diamond market identifier to resolve.
    /// @param outcome  `true` if YES wins, `false` if NO wins.
    function report(uint256 marketId, bool outcome) external;

    /// @notice Tombstone (abandon) a binary outcome. Slot is frozen — admin playbook
    ///         is revoke then `IMarketFacet.enableRefundMode`. To correct instead of
    ///         abandon, use `reopenReport` within the challenge window.
    /// @param marketId The diamond market identifier to clear.
    function revoke(uint256 marketId) external;

    /// @notice Reopen a binary report within its challenge window so the reporter can
    ///         publish a corrected outcome. Reverts once the window has closed; does
    ///         not freeze the slot.
    /// @param marketId The diamond market identifier to reopen.
    function reopenReport(uint256 marketId) external;

    // -- Event functions --

    /// @notice Publish the winning candidate index for a multi-outcome event.
    /// @param eventId      The diamond event identifier.
    /// @param winningIndex Index into the event's candidates array.
    function reportEvent(uint256 eventId, uint256 winningIndex) external;

    /// @notice Tombstone (abandon) a previously reported event outcome. Slot frozen.
    /// @param eventId The diamond event identifier to clear.
    function revokeEvent(uint256 eventId) external;

    /// @notice Reopen an event report within its challenge window for a corrected
    ///         re-report. Reverts once the window has closed; does not freeze.
    /// @param eventId The diamond event identifier to reopen.
    function reopenEventReport(uint256 eventId) external;
}
