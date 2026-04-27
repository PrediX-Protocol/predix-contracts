// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {IMarketFacet} from "@predix/shared/interfaces/IMarketFacet.sol";

import {MarketFixture} from "../utils/MarketFixture.sol";

/// @notice Fix-lock for AUDIT-L-04 (Pass 2.1, was L-05 in Pass 1):
///         `enableRefundMode` now mirrors `emergencyResolve`'s try/catch
///         guard against oracle-resolved markets. Admin can no longer
///         override a deterministic resolution by racing the permissionless
///         `resolveMarket`. Oracle-unreachable case still permits legitimate
///         stall recovery via the catch arm.
contract Audit_L05_RefundModeOracleRace is MarketFixture {
    uint256 internal id;
    uint256 internal endTime;
    uint256 internal constant SPLIT_AMT = 100e6;

    function setUp() public override {
        super.setUp();
        endTime = block.timestamp + 7 days;
        id = _createMarket(endTime);
    }

    /// @dev FIX-LOCK: oracle has resolved YES at endTime+1. Admin attempt to
    ///      enable refund mode MUST revert with
    ///      `Market_OracleResolvedUseResolve` — the deterministic oracle
    ///      outcome is preserved.
    function test_Revert_EnableRefundMode_OracleAlreadyResolved() public {
        _split(alice, id, SPLIT_AMT);
        oracle.setResolution(id, true);
        vm.warp(endTime + 1);

        assertTrue(oracle.isResolved(id), "oracle ready");

        vm.prank(admin);
        vm.expectRevert(IMarketFacet.Market_OracleResolvedUseResolve.selector);
        market.enableRefundMode(id);

        // Sanity — resolveMarket still works; outcome preserved.
        market.resolveMarket(id);
        IMarketFacet.MarketView memory m = market.getMarket(id);
        assertTrue(m.isResolved);
        assertTrue(m.outcome);
        assertFalse(m.refundModeActive);
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
