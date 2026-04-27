// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {IMarketFacet} from "@predix/shared/interfaces/IMarketFacet.sol";

import {MarketFixture} from "../utils/MarketFixture.sol";

/// @notice Repro for AUDIT-L-05 (Professional audit 2026-04-25):
///         `enableRefundMode` is admin-gated but does NOT check whether the
///         oracle has already produced an answer. After endTime passes, an
///         admin observing an oracle outcome they dislike can call
///         `enableRefundMode` to override a deterministic resolution.
///
///         `emergencyResolve` already checks this asymmetrically (lines
///         155-159 of MarketFacet — `Market_OracleResolvedUseResolve`).
///         `enableRefundMode` does not. The audit recommends mirroring
///         `emergencyResolve`'s try/catch oracle-resolved guard.
///
///         These tests demonstrate the bug at HEAD `ce524ba`. After the fix,
///         test_BUG_AdminOverridesResolvedOracle should revert with
///         `Market_OracleResolvedUseResolve`.
contract Audit_L05_RefundModeOracleRace is MarketFixture {
    uint256 internal id;
    uint256 internal endTime;
    uint256 internal constant SPLIT_AMT = 100e6;

    function setUp() public override {
        super.setUp();
        endTime = block.timestamp + 7 days;
        id = _createMarket(endTime);
    }

    /// @dev DEMONSTRATES BUG: oracle has resolved YES at endTime+1. Admin
    ///      front-runs the permissionless `resolveMarket` call by enabling
    ///      refund mode. Subsequent `resolveMarket` reverts; the deterministic
    ///      oracle outcome is lost.
    function test_BUG_AdminFrontRunsResolvedOracle() public {
        _split(alice, id, SPLIT_AMT);
        oracle.setResolution(id, true);
        vm.warp(endTime + 1);

        // Oracle is resolved on-chain — anyone could call resolveMarket.
        assertTrue(oracle.isResolved(id), "oracle ready");

        // Admin races ahead and enables refund mode. NO oracle-resolved
        // check exists in enableRefundMode.
        vm.prank(admin);
        market.enableRefundMode(id);

        // Subsequent resolveMarket fails — admin override succeeded.
        vm.expectRevert(IMarketFacet.Market_RefundModeActive.selector);
        market.resolveMarket(id);

        // Sanity — alice can refund (50/50 burn) but the YES outcome is gone.
        IMarketFacet.MarketView memory m = market.getMarket(id);
        assertTrue(m.refundModeActive);
        assertFalse(m.isResolved);
    }

    /// @dev Sanity: emergencyResolve has the symmetric guard. Same scenario,
    ///      but emergencyResolve must revert with `Market_OracleResolvedUseResolve`.
    function test_Sanity_EmergencyResolveHasOracleGuard() public {
        _split(alice, id, SPLIT_AMT);
        oracle.setResolution(id, true);

        // After the EMERGENCY_DELAY (7 days post-endTime).
        vm.warp(endTime + 7 days + 1);

        vm.prank(admin);
        vm.expectRevert(IMarketFacet.Market_OracleResolvedUseResolve.selector);
        market.emergencyResolve(id, false);
    }

    /// @dev Sanity: enableRefundMode IS admin-gated (correct). The bug is the
    ///      missing oracle-resolved guard, not the access control.
    function test_EnableRefundMode_RequiresAdmin() public {
        vm.warp(endTime + 1);
        // Some non-admin caller tries.
        vm.prank(alice);
        vm.expectRevert(); // AccessControl_MissingRole
        market.enableRefundMode(id);
    }

    /// @dev EXPECTED-AFTER-FIX: pre-resolution refund-mode entry must work
    ///      (oracle hasn't answered yet). Locks the legitimate path.
    function test_EnableRefundMode_BeforeOracleResolved_OK() public {
        vm.warp(endTime + 1);
        // Oracle deliberately NOT resolved.
        assertFalse(oracle.isResolved(id));

        vm.prank(admin);
        market.enableRefundMode(id); // legitimate stall recovery
    }
}
