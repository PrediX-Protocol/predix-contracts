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
///         outcomes by hand; an admin can revoke before the diamond consumes.
/// @dev Standalone contract bound to one diamond proxy at construction. NOT a
///      diamond facet — has its own AccessControl and storage.
contract ManualOracle is IManualOracle, AccessControl {
    /// @notice Role granted to addresses permitted to call `report`.
    bytes32 public constant REPORTER_ROLE = keccak256("predix.oracle.reporter");

    /// @notice Diamond this oracle is bound to. Queried for `endTime` at report
    ///         time so pre-publication races against `resolveMarket` are impossible.
    address public immutable diamond;

    struct Resolution {
        bool reported;
        bool outcome;
        uint64 reportedAt;
        address reporter;
        bool frozen;
    }

    mapping(uint256 marketId => Resolution) internal _resolutions;

    struct EventResolution {
        bool reported;
        uint256 winningIndex;
        uint64 reportedAt;
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
        r.reporter = msg.sender;

        emit OutcomeReported(marketId, outcome_, msg.sender);
    }

    /// @inheritdoc IManualOracle
    function revoke(uint256 marketId) external onlyRole(DEFAULT_ADMIN_ROLE) {
        Resolution storage r = _resolutions[marketId];
        if (!r.reported) revert ManualOracle_NotReported();

        // Tombstone: clear the answer so diamond cannot consume it, and set
        // `frozen` so the reporter cannot re-publish a (possibly opposite)
        // outcome. The diamond-side companion (auto-route to refund mode) is
        // NOT this adapter's responsibility — admin playbook is revoke then
        // `IMarketFacet.enableRefundMode`.
        r.reported = false;
        r.frozen = true;

        emit OutcomeRevoked(marketId, msg.sender);
    }

    /// @inheritdoc IOracle
    function isResolved(uint256 marketId) external view returns (bool) {
        return _resolutions[marketId].reported;
    }

    /// @inheritdoc IOracle
    function outcome(uint256 marketId) external view returns (bool) {
        Resolution storage r = _resolutions[marketId];
        if (!r.reported) revert ManualOracle_NotReported();
        return r.outcome;
    }

    /// @notice Timestamp at which `marketId` was reported. Returns zero if not reported.
    /// @param marketId The diamond market identifier.
    function reportedAt(uint256 marketId) external view returns (uint64) {
        return _resolutions[marketId].reportedAt;
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

    /// @inheritdoc IEventOracle
    function isEventResolved(uint256 eventId) external view returns (bool) {
        return _eventResolutions[eventId].reported;
    }

    /// @inheritdoc IEventOracle
    function eventOutcome(uint256 eventId) external view returns (uint256) {
        EventResolution storage r = _eventResolutions[eventId];
        if (!r.reported) revert ManualOracle_EventNotReported();
        return r.winningIndex;
    }

    /// @notice Timestamp at which `eventId` was reported. Returns zero if not reported.
    function eventReportedAt(uint256 eventId) external view returns (uint64) {
        return _eventResolutions[eventId].reportedAt;
    }

    /// @notice Address of the reporter that published the outcome for `eventId`.
    function eventReporterOf(uint256 eventId) external view returns (address) {
        return _eventResolutions[eventId].reporter;
    }
}
