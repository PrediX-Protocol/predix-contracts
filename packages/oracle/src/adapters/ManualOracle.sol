// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";

import {IEventFacet} from "@predix/shared/interfaces/IEventFacet.sol";
import {IMarketFacet} from "@predix/shared/interfaces/IMarketFacet.sol";
import {IOracle} from "@predix/shared/interfaces/IOracle.sol";
import {IEventOracle} from "@predix/shared/interfaces/IEventOracle.sol";

import {IManualOracle} from "../interfaces/IManualOracle.sol";

/// @title ManualOracle
/// @notice Reporter-driven oracle for both binary markets (`IOracle`) and
///         multi-outcome events (`IEventOracle`). A role-gated reporter publishes
///         outcomes by hand; within an optional challenge window an admin can
///         revoke (abandon) or reopen (correct) before the diamond consumes.
/// @dev Standalone contract bound to one diamond proxy at construction. NOT a
///      diamond facet — has its own AccessControl and storage.
///
///      Challenge window: when `challengeDelay > 0`, a reported outcome becomes
///      consumable (`isResolved == true`) only after `finalizesAt = reportedAt +
///      challengeDelay`. During the window the admin can `revoke` (abandon ->
///      refund) or `reopenReport` (clear so the reporter can re-publish a
///      corrected outcome). The reporter can never change a live report unilaterally
///      — only an admin reopen/revoke clears the slot. With `challengeDelay == 0`
///      (default) resolution is immediate (legacy behaviour). The delay is
///      capped at `MAX_CHALLENGE_DELAY`; the diamond operator-emergency path
///      remains the ultimate stall backstop.
contract ManualOracle is IManualOracle, AccessControl {
    /// @notice Role granted to addresses permitted to call `report`.
    bytes32 public constant REPORTER_ROLE = keccak256("predix.oracle.reporter");

    /// @notice Upper bound on `challengeDelay`. Caps a fat-finger that would
    ///         otherwise stall resolution; the diamond's operator emergency path
    ///         (endTime + 7d) remains the ultimate backstop.
    uint256 public constant MAX_CHALLENGE_DELAY = 7 days;

    /// @notice Diamond this oracle is bound to. Queried for `endTime` at report
    ///         time so pre-publication races against `resolveMarket` are impossible.
    address public immutable diamond;

    /// @notice Seconds a reported outcome must sit before it becomes consumable.
    ///         `0` (default) = immediate. Admin-controlled via `setChallengeDelay`;
    ///         snapshotted into each report's `finalizesAt` at report time.
    uint256 public challengeDelay;

    struct Resolution {
        bool reported;
        bool outcome;
        uint64 reportedAt;
        uint64 finalizesAt;
        address reporter;
        bool frozen;
    }

    mapping(uint256 marketId => Resolution) internal _resolutions;

    struct EventResolution {
        bool reported;
        uint256 winningIndex;
        uint64 reportedAt;
        uint64 finalizesAt;
        address reporter;
        bool frozen;
    }

    mapping(uint256 eventId => EventResolution) internal _eventResolutions;

    /// @notice Deploy the oracle, seat the initial admin, and bind to a diamond.
    /// @param admin    Address granted `DEFAULT_ADMIN_ROLE`; must be non-zero.
    /// @param diamond_ Address of the diamond proxy whose markets this oracle
    ///                 resolves; must be non-zero.
    constructor(address admin, address diamond_) {
        if (admin == address(0)) revert ManualOracle_ZeroAdmin();
        if (diamond_ == address(0)) revert ManualOracle_ZeroDiamond();
        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        diamond = diamond_;
    }

    /// @notice ERC-165 support. Advertises `IEventOracle` so the diamond's
    ///         `createEvent` capability check recognizes this oracle as
    ///         event-resolvable, alongside the AccessControl interfaces.
    function supportsInterface(bytes4 interfaceId) public view override returns (bool) {
        return interfaceId == type(IEventOracle).interfaceId || super.supportsInterface(interfaceId);
    }

    /// @inheritdoc IManualOracle
    function setChallengeDelay(uint256 newDelay) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (newDelay > MAX_CHALLENGE_DELAY) revert ManualOracle_DelayTooLong();
        emit ChallengeDelayUpdated(challengeDelay, newDelay);
        challengeDelay = newDelay;
    }

    /// @inheritdoc IManualOracle
    function report(uint256 marketId, bool outcome_) external onlyRole(REPORTER_ROLE) {
        Resolution storage r = _resolutions[marketId];
        if (r.reported) revert ManualOracle_AlreadyReported();
        if (r.frozen) revert ManualOracle_Frozen();

        (,, uint256 endTime,,) = IMarketFacet(diamond).getMarketStatus(marketId);
        if (block.timestamp < endTime) revert ManualOracle_BeforeMarketEnd();

        r.reported = true;
        r.outcome = outcome_;
        r.reportedAt = uint64(block.timestamp);
        r.finalizesAt = uint64(block.timestamp + challengeDelay);
        r.reporter = msg.sender;

        emit OutcomeReported(marketId, outcome_, msg.sender);
    }

    /// @inheritdoc IManualOracle
    function revoke(uint256 marketId) external onlyRole(DEFAULT_ADMIN_ROLE) {
        Resolution storage r = _resolutions[marketId];
        if (!r.reported) revert ManualOracle_NotReported();

        // Tombstone (abandon): clear the answer so the diamond cannot consume it,
        // and freeze the slot so the reporter cannot re-publish. Admin playbook is
        // revoke then `IMarketFacet.enableRefundMode`. To CORRECT a wrong report
        // (re-publish) instead of abandoning, use `reopenReport` within the window.
        r.reported = false;
        r.frozen = true;

        emit OutcomeRevoked(marketId, msg.sender);
    }

    /// @inheritdoc IManualOracle
    function reopenReport(uint256 marketId) external onlyRole(DEFAULT_ADMIN_ROLE) {
        Resolution storage r = _resolutions[marketId];
        if (!r.reported) revert ManualOracle_NotReported();
        // Only within the challenge window. Before finalization `isResolved` was
        // still false, so the diamond cannot have consumed the outcome — clearing
        // for a corrected re-report is race-free. Does NOT freeze, so the reporter
        // can publish the corrected outcome in a fresh window.
        if (block.timestamp >= r.finalizesAt) revert ManualOracle_ChallengeWindowClosed();
        r.reported = false;
        r.finalizesAt = 0;

        emit ReportReopened(marketId, msg.sender);
    }

    /// @inheritdoc IOracle
    function isResolved(uint256 marketId) external view returns (bool) {
        Resolution storage r = _resolutions[marketId];
        return r.reported && block.timestamp >= r.finalizesAt;
    }

    /// @inheritdoc IOracle
    function outcome(uint256 marketId) external view returns (bool) {
        Resolution storage r = _resolutions[marketId];
        if (!r.reported) revert ManualOracle_NotReported();
        if (block.timestamp < r.finalizesAt) revert ManualOracle_NotFinalized();
        return r.outcome;
    }

    /// @notice Timestamp at which `marketId` was reported. Returns zero if not reported.
    function reportedAt(uint256 marketId) external view returns (uint64) {
        return _resolutions[marketId].reportedAt;
    }

    /// @notice Timestamp at which `marketId`'s report becomes consumable. Zero if not reported.
    function finalizesAt(uint256 marketId) external view returns (uint64) {
        return _resolutions[marketId].finalizesAt;
    }

    /// @notice Address of the reporter that published the outcome for `marketId`.
    /// @dev Returns the zero address if the market has not been reported.
    /// @param marketId The diamond market identifier.
    function reporterOf(uint256 marketId) external view returns (address) {
        return _resolutions[marketId].reporter;
    }

    // -----------------------------------------------------------------------
    // Event resolution
    // -----------------------------------------------------------------------

    /// @inheritdoc IManualOracle
    function reportEvent(uint256 eventId, uint256 winningIndex) external onlyRole(REPORTER_ROLE) {
        EventResolution storage r = _eventResolutions[eventId];
        if (r.reported) revert ManualOracle_EventAlreadyReported();
        if (r.frozen) revert ManualOracle_EventFrozen();

        (uint256 endTime, uint256 candidateCount,,) = IEventFacet(diamond).getEventStatus(eventId);
        if (block.timestamp < endTime) revert ManualOracle_BeforeEventEnd();
        if (winningIndex >= candidateCount) revert ManualOracle_InvalidWinningIndex();

        r.reported = true;
        r.winningIndex = winningIndex;
        r.reportedAt = uint64(block.timestamp);
        r.finalizesAt = uint64(block.timestamp + challengeDelay);
        r.reporter = msg.sender;

        emit EventOutcomeReported(eventId, winningIndex, msg.sender);
    }

    /// @inheritdoc IManualOracle
    function revokeEvent(uint256 eventId) external onlyRole(DEFAULT_ADMIN_ROLE) {
        EventResolution storage r = _eventResolutions[eventId];
        if (!r.reported) revert ManualOracle_EventNotReported();

        r.reported = false;
        r.frozen = true;

        emit EventOutcomeRevoked(eventId, msg.sender);
    }

    /// @inheritdoc IManualOracle
    function reopenEventReport(uint256 eventId) external onlyRole(DEFAULT_ADMIN_ROLE) {
        EventResolution storage r = _eventResolutions[eventId];
        if (!r.reported) revert ManualOracle_EventNotReported();
        if (block.timestamp >= r.finalizesAt) revert ManualOracle_ChallengeWindowClosed();
        r.reported = false;
        r.finalizesAt = 0;

        emit EventReportReopened(eventId, msg.sender);
    }

    /// @inheritdoc IEventOracle
    function isEventResolved(uint256 eventId) external view returns (bool) {
        EventResolution storage r = _eventResolutions[eventId];
        return r.reported && block.timestamp >= r.finalizesAt;
    }

    /// @inheritdoc IEventOracle
    function eventOutcome(uint256 eventId) external view returns (uint256) {
        EventResolution storage r = _eventResolutions[eventId];
        if (!r.reported) revert ManualOracle_EventNotReported();
        if (block.timestamp < r.finalizesAt) revert ManualOracle_NotFinalized();
        return r.winningIndex;
    }

    /// @notice Timestamp at which `eventId` was reported. Returns zero if not reported.
    function eventReportedAt(uint256 eventId) external view returns (uint64) {
        return _eventResolutions[eventId].reportedAt;
    }

    /// @notice Timestamp at which `eventId`'s report becomes consumable. Zero if not reported.
    function eventFinalizesAt(uint256 eventId) external view returns (uint64) {
        return _eventResolutions[eventId].finalizesAt;
    }

    /// @notice Address of the reporter that published the outcome for `eventId`.
    function eventReporterOf(uint256 eventId) external view returns (address) {
        return _eventResolutions[eventId].reporter;
    }
}
