// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {IMarketFacet} from "@predix/shared/interfaces/IMarketFacet.sol";

import {MarketFixture} from "../utils/MarketFixture.sol";

/// @notice Repro for F-D-03: `resolveMarket` must re-check
///         `approvedOracles[m.oracle]` so that admin `revokeOracle` can unplug
///         an oracle from in-flight markets. Without this check, a revoked
///         oracle could still return outcomes and be consumed by permissionless
///         resolveMarket calls.
contract F_D_03_ResolveOracleRevoked is MarketFixture {
    uint256 internal id;
    uint256 internal endTime;

    function setUp() public override {
        super.setUp();
        endTime = block.timestamp + 7 days;
        id = _createMarket(endTime);
    }

    function test_Revert_F_D_03_revokedOracleBlocksResolve() public {
        oracle.setResolution(id, true);
        vm.warp(endTime + 1);

        vm.prank(admin);
        market.revokeOracle(address(oracle));

        vm.prank(bob);
        vm.expectRevert(IMarketFacet.Market_OracleNotApproved.selector);
        market.resolveMarket(id);
    }

    function test_F_D_03_revokedOracleAllowsRefundMode() public {
        // After revoke, admin can enableRefundMode cleanly — the resolve path
        // is blocked so there is no race.
        oracle.setResolution(id, true);
        vm.warp(endTime + 1);

        vm.prank(admin);
        market.revokeOracle(address(oracle));

        vm.prank(admin);
        market.enableRefundMode(id);

        IMarketFacet.MarketView memory m = market.getMarket(id);
        assertTrue(m.refundModeActive);
        assertFalse(m.isResolved);
    }

    function test_F_D_03_stillApprovedOracleResolvesNormally() public {
        // Sanity: resolve still works when oracle remains approved.
        oracle.setResolution(id, true);
        vm.warp(endTime + 1);
        vm.prank(bob);
        market.resolveMarket(id);
        assertTrue(market.getMarket(id).isResolved);
    }
}
