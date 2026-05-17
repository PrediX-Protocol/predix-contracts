// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import {IMarketFacet} from "@predix/shared/interfaces/IMarketFacet.sol";
import {Roles} from "@predix/shared/constants/Roles.sol";

import {MarketFixture} from "../utils/MarketFixture.sol";

/// @title Audit_D02_EmergencyOracleRevokeDeadlock
/// @notice Audit D-NEW-02 (pass-2): when admin revokes a compromised oracle
///         AFTER it has produced an answer, both `resolveMarket` (gated on
///         `approvedOracles`) and the previous version of `emergencyResolve`
///         (deferred unconditionally to `oracle.isResolved`) rejected — the
///         operator had no recovery path without admin intervention via
///         `enableRefundMode`.
///
///         The fix wraps the `try` in `if (approvedOracles[m.oracle])` so a
///         revoked oracle is treated as unreachable, letting the operator
///         force-resolve. This test pins the new behavior on both paths and
///         keeps the original "approved-and-ready → defer" guarantee intact.
contract Audit_D02_EmergencyOracleRevokeDeadlock is MarketFixture {
    uint256 internal constant EMERGENCY_DELAY = 7 days;

    /// @notice Revoked oracle that still answers `isResolved=true` no longer
    ///         deadlocks `emergencyResolve`. Operator can force-resolve.
    function test_D02_EmergencyResolve_RevokedOracle_NoLongerDeadlocks() public {
        uint256 endTime = block.timestamp + 1 days;
        uint256 marketId = _createMarket(endTime);

        // Oracle reports — without the fix this would block emergency.
        oracle.setResolution(marketId, true);

        // Admin revokes the oracle (post-compromise playbook).
        vm.prank(admin);
        market.revokeOracle(address(oracle));
        assertFalse(market.isOracleApproved(address(oracle)));

        // Past endTime + emergency delay.
        vm.warp(endTime + EMERGENCY_DELAY);

        // Operator force-resolves with their own outcome (operator's job is
        // exactly to override a compromised oracle's answer).
        vm.startPrank(admin);
        accessControl.grantRole(Roles.OPERATOR_ROLE, alice);
        vm.stopPrank();

        vm.prank(alice);
        market.emergencyResolve(marketId, false);

        IMarketFacet.MarketView memory m = market.getMarket(marketId);
        assertTrue(m.isResolved, "isResolved set");
        assertEq(m.outcome, false, "operator's outcome applied");
    }

    /// @notice Approved-and-ready oracle STILL forces operator down the
    ///         `resolveMarket` path. The fix must not let the operator
    ///         silently override a healthy answer.
    function test_Revert_D02_EmergencyResolve_ApprovedReadyOracle_StillDefers() public {
        uint256 endTime = block.timestamp + 1 days;
        uint256 marketId = _createMarket(endTime);

        // Oracle approved AND ready.
        oracle.setResolution(marketId, true);
        assertTrue(market.isOracleApproved(address(oracle)));

        vm.warp(endTime + EMERGENCY_DELAY);

        vm.startPrank(admin);
        accessControl.grantRole(Roles.OPERATOR_ROLE, alice);
        vm.stopPrank();

        vm.expectRevert(IMarketFacet.Market_OracleResolvedUseResolve.selector);
        vm.prank(alice);
        market.emergencyResolve(marketId, false);
    }

    /// @notice Approved-but-unreachable oracle still permits emergency resolve
    ///         (the original stall-recovery use case). The try/catch in the
    ///         fix branch must still swallow oracle reverts.
    function test_D02_EmergencyResolve_ApprovedUnreachableOracle_StillRecovers() public {
        uint256 endTime = block.timestamp + 1 days;
        uint256 marketId = _createMarket(endTime);

        // Oracle is approved but has NEVER reported — its `isResolved`
        // returns false (in MockOracle's case it's just a mapping read).
        // We model an unreachable oracle by NOT calling setResolution.
        assertTrue(market.isOracleApproved(address(oracle)));

        vm.warp(endTime + EMERGENCY_DELAY);

        vm.startPrank(admin);
        accessControl.grantRole(Roles.OPERATOR_ROLE, alice);
        vm.stopPrank();

        vm.prank(alice);
        market.emergencyResolve(marketId, true);

        IMarketFacet.MarketView memory m = market.getMarket(marketId);
        assertTrue(m.isResolved, "isResolved set on unreachable oracle");
    }
}
