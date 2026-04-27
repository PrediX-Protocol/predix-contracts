// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {IMarketFacet} from "@predix/shared/interfaces/IMarketFacet.sol";

import {MarketFixture} from "../utils/MarketFixture.sol";

/// @notice Fix-lock for AUDIT-M-02 (Pass 2.1, was L-04 in Pass 1):
///         `setPerMarketRedemptionFeeBps` now enforces `bps <=
///         snapshottedDefaultRedemptionFeeBps` so the per-market override can
///         only LOWER the effective fee, never raise it above the snapshot
///         taken at market creation. The FINAL-H04 snapshot promise is now
///         honoured for the override path too.
contract Audit_L04_PerMarketFeeMidFlight is MarketFixture {
    uint256 internal id;
    uint256 internal endTime;
    uint256 internal constant SPLIT_AMT = 1_000_000e6;

    function setUp() public override {
        super.setUp();
        endTime = block.timestamp + 7 days;
        // Default fee = 0 at creation → snapshot = 0
        id = _createMarket(endTime);
    }

    function _resolveYes() internal {
        oracle.setResolution(id, true);
        vm.warp(endTime + 1);
        market.resolveMarket(id);
    }

    /// @dev FIX-LOCK: with snapshot = 0, admin cannot set override > 0.
    ///      Attempt to extract 15% must revert.
    function test_Revert_OverrideAboveSnapshot_RejectsExtraction() public {
        _split(alice, id, SPLIT_AMT);
        assertEq(market.effectiveRedemptionFeeBps(id), 0, "snapshot 0");

        vm.prank(admin);
        vm.expectRevert(IMarketFacet.Market_FeeExceedsSnapshot.selector);
        market.setPerMarketRedemptionFeeBps(id, 1500);

        // Effective fee unchanged at 0.
        assertEq(market.effectiveRedemptionFeeBps(id), 0);

        _resolveYes();

        uint256 aliceBefore = usdc.balanceOf(alice);
        vm.prank(alice);
        uint256 payout = market.redeem(id);
        // Alice receives full payout — no fee extracted.
        assertEq(payout, SPLIT_AMT, "no retroactive fee");
        assertEq(usdc.balanceOf(alice) - aliceBefore, SPLIT_AMT);
    }

    /// @dev FIX-LOCK: admin CAN lower the per-market fee below the snapshot,
    ///      e.g. when snapshot was 1000 (10%) and admin wants to grant a
    ///      market 0% fee for promotional purposes.
    function test_OverrideBelowSnapshot_Allowed() public {
        // Bump default to 10% before creating a fresh market with snapshot = 1000.
        vm.prank(admin);
        market.setDefaultRedemptionFeeBps(1000);
        uint256 id2 = _createMarket(block.timestamp + 7 days);
        assertEq(market.effectiveRedemptionFeeBps(id2), 1000);

        // Lower per-market to 5% — must succeed (5% < 10% snapshot).
        vm.prank(admin);
        market.setPerMarketRedemptionFeeBps(id2, 500);
        assertEq(market.effectiveRedemptionFeeBps(id2), 500);

        // Lower to 0% — must succeed.
        vm.prank(admin);
        market.setPerMarketRedemptionFeeBps(id2, 0);
        assertEq(market.effectiveRedemptionFeeBps(id2), 0);

        // Try to raise above snapshot — must revert.
        vm.prank(admin);
        vm.expectRevert(IMarketFacet.Market_FeeExceedsSnapshot.selector);
        market.setPerMarketRedemptionFeeBps(id2, 1500);
    }

    /// @dev FIX-LOCK: setting override exactly equal to the snapshot is
    ///      allowed (boundary case).
    function test_OverrideEqualToSnapshot_Allowed() public {
        vm.prank(admin);
        market.setDefaultRedemptionFeeBps(800);
        uint256 id2 = _createMarket(block.timestamp + 7 days);

        vm.prank(admin);
        market.setPerMarketRedemptionFeeBps(id2, 800);
        assertEq(market.effectiveRedemptionFeeBps(id2), 800);
    }

    /// @dev Sanity: the existing protection IS in place — admin cannot set
    ///      override AFTER the market reaches a final state.
    function test_OverrideLocked_AfterResolved() public {
        _split(alice, id, SPLIT_AMT);
        _resolveYes();
        vm.expectRevert(IMarketFacet.Market_FeeLockedAfterFinal.selector);
        vm.prank(admin);
        market.setPerMarketRedemptionFeeBps(id, 0);
    }

    /// @dev Sanity: clearPerMarketRedemptionFee remains gated by final state
    ///      only (no snapshot bound — clearing reverts to default which is
    ///      itself protected by snapshot).
    function test_ClearOverride_StillWorks() public {
        vm.prank(admin);
        market.setDefaultRedemptionFeeBps(500);
        uint256 id2 = _createMarket(block.timestamp + 7 days);

        vm.prank(admin);
        market.setPerMarketRedemptionFeeBps(id2, 100);

        vm.prank(admin);
        market.clearPerMarketRedemptionFee(id2);
        // Falls back to snapshot = 500.
        assertEq(market.effectiveRedemptionFeeBps(id2), 500);
    }
}
