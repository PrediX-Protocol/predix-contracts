// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import {IMarketFacet} from "@predix/shared/interfaces/IMarketFacet.sol";

import {MarketFixture} from "../utils/MarketFixture.sol";

/// @notice AUDIT-M-02 (Pass 2.1, was L-04) was the `bps <= snapshottedDefaultRedemptionFeeBps`
///         ("override may only lower") rule. keyti-fqn8 (owner decision 2026-06-09) REVERSES it:
///         admin may now raise OR lower the per-market fee freely within the hard cap
///         (`MAX_REDEMPTION_FEE_BPS` = 1000 bps = 10%). The mid-flight-extraction risk is instead
///         contained by freezing the fee once the market has ended (`Market_Ended`), so the value an
///         in-flight redeemer pays is fixed before trading closes. This file locks THAT policy.
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

    /// @dev keyti-fqn8: admin CAN now raise the override above the (zero) snapshot, up to the cap.
    ///      Above the cap reverts `Market_FeeTooHigh`; once the market ends it reverts `Market_Ended`.
    function test_OverrideAboveSnapshot_NowAllowed_CappedAndEndLocked() public {
        _split(alice, id, SPLIT_AMT);
        assertEq(market.effectiveRedemptionFeeBps(id), 0, "snapshot 0");

        // Raise above the zero snapshot to the 10% cap — now allowed (was Market_FeeExceedsSnapshot).
        vm.prank(admin);
        market.setPerMarketRedemptionFeeBps(id, 1000);
        assertEq(market.effectiveRedemptionFeeBps(id), 1000);

        // Above the cap is still rejected.
        vm.prank(admin);
        vm.expectRevert(IMarketFacet.Market_FeeTooHigh.selector);
        market.setPerMarketRedemptionFeeBps(id, 1001);

        // Once the market has ended, the fee is frozen — no last-second hike before redeem.
        vm.warp(endTime);
        vm.prank(admin);
        vm.expectRevert(IMarketFacet.Market_Ended.selector);
        market.setPerMarketRedemptionFeeBps(id, 500);
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

        // keyti-fqn8: raising back up (within the 10% cap) is now allowed too.
        vm.prank(admin);
        market.setPerMarketRedemptionFeeBps(id2, 1000);
        assertEq(market.effectiveRedemptionFeeBps(id2), 1000);
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
