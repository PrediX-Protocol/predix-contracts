// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {IOracle} from "@predix/shared/interfaces/IOracle.sol";

/// @title IManualOracle
/// @notice Human-curated binary oracle. A trusted reporter submits the outcome
///         by hand; an admin can revoke a reported outcome before it has been
///         consumed by the diamond.
/// @dev The diamond snapshots `isResolved` / `outcome` the moment `resolveMarket`
///      is called, so `revoke` is a best-effort escape hatch: once a market has
///      pulled the answer, revoking here does not unwind the market. Each
///      deployment is bound to a single diamond at construction so `report`
///      can enforce the market's `endTime` gate via `IMarketFacet.getMarketStatus`.
interface IManualOracle is IOracle {
    /// @notice Emitted when a reporter publishes the final outcome for a market.
    /// @param marketId The diamond market identifier.
    /// @param outcome  `true` if YES wins, `false` if NO wins.
    /// @param reporter The address that reported the outcome.
    event OutcomeReported(uint256 indexed marketId, bool outcome, address indexed reporter);

    /// @notice Emitted when an admin revokes a previously reported outcome.
    /// @param marketId The diamond market identifier whose resolution was cleared.
    /// @param admin    The admin that performed the revocation.
    event OutcomeRevoked(uint256 indexed marketId, address indexed admin);

    /// @notice Reverts when constructing the oracle with a zero admin address.
    error ManualOracle_ZeroAdmin();

    /// @notice Reverts when constructing the oracle with a zero diamond address.
    error ManualOracle_ZeroDiamond();

    /// @notice Reverts when a reporter tries to report a market that already has an outcome.
    error ManualOracle_AlreadyReported();

    /// @notice Reverts when `outcome` or `revoke` is called for a market that was never reported.
    error ManualOracle_NotReported();

    /// @notice Reverts when a reporter tries to `report` a market whose slot has
    ///         been tombstoned by a prior `revoke`. The admin playbook after
    ///         revoke is to manually enable refund mode on the diamond.
    error ManualOracle_Frozen();

    /// @notice Reverts when a reporter tries to publish an outcome before the
    ///         diamond-side market `endTime` has elapsed.
    error ManualOracle_BeforeMarketEnd();

    /// @notice Publish the final outcome for `marketId`.
    /// @dev Callable only by an address with `REPORTER_ROLE`. Reverts if the
    ///      market has already been reported, has been tombstoned by `revoke`,
    ///      or has not yet reached its diamond-side `endTime`.
    /// @param marketId The diamond market identifier to resolve.
    /// @param outcome  `true` if YES wins, `false` if NO wins.
    function report(uint256 marketId, bool outcome) external;

    /// @notice Tombstone a previously reported outcome so the diamond can no
    ///         longer consume it. The slot is frozen — the reporter cannot
    ///         re-publish. Admin follow-up is to call
    ///         `IMarketFacet.enableRefundMode` on the diamond side.
    /// @dev Callable only by `DEFAULT_ADMIN_ROLE`. Has no effect on markets that
    ///      have already snapshotted the answer on the diamond side.
    /// @param marketId The diamond market identifier to clear.
    function revoke(uint256 marketId) external;
}
