// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {IMarketFacet} from "@predix/shared/interfaces/IMarketFacet.sol";

import {MarketFixture} from "../utils/MarketFixture.sol";

/// @notice Repro for FINAL-H04: admin could previously hike the redemption fee
///         after a market was resolved and have the new fee apply retroactively
///         to in-flight redeems. Fix: the default fee is snapshotted into
///         MarketData at creation; per-market fee mutation is locked after
///         finality.
contract FinalH04_RetroactiveFee is MarketFixture {
    uint256 internal id;
    uint256 internal endTime;

    function setUp() public override {
        super.setUp();
        endTime = block.timestamp + 7 days;
        id = _createMarket(endTime);
    }

    function _resolveYes() internal {
        oracle.setResolution(id, true);
        vm.warp(endTime + 1);
        market.resolveMarket(id);
    }

    /// @dev Market created with default fee = 0. Admin hikes default to 1500
    ///      bps (15%) before users redeem. Alice must still receive 100% of
    ///      her winning position because the fee was snapshotted to 0 at
    ///      creation.
    function test_RedemptionFee_SnapshottedAtCreate_NotRetroactive() public {
        _split(alice, id, 100e6);
        _resolveYes();

        vm.prank(admin);
        market.setDefaultRedemptionFeeBps(1500);

        // View must also return the snapshot, not the live config.
        assertEq(market.effectiveRedemptionFeeBps(id), 0);

        uint256 before = usdc.balanceOf(alice);
        vm.prank(alice);
        uint256 payout = market.redeem(id);
        assertEq(payout, 100e6, "retroactive fee must not apply");
        assertEq(usdc.balanceOf(alice) - before, 100e6);
    }

    function test_Revert_SetPerMarketRedemptionFee_AfterResolve() public {
        _split(alice, id, 100e6);
        _resolveYes();

        vm.expectRevert(IMarketFacet.Market_FeeLockedAfterFinal.selector);
        vm.prank(admin);
        market.setPerMarketRedemptionFeeBps(id, 500);
    }

    function test_Revert_ClearPerMarketRedemptionFee_AfterRefundMode() public {
        _split(alice, id, 100e6);
        vm.prank(admin);
        market.setPerMarketRedemptionFeeBps(id, 500);

        vm.warp(endTime + 1);
        vm.prank(admin);
        market.enableRefundMode(id);

        vm.expectRevert(IMarketFacet.Market_FeeLockedAfterFinal.selector);
        vm.prank(admin);
        market.clearPerMarketRedemptionFee(id);
    }

    /// @dev New markets created after the admin hike do pick up the new default
    ///      — snapshot only locks in the value at the moment of creation.
    function test_NewMarket_PicksUpCurrentDefault() public {
        vm.prank(admin);
        market.setDefaultRedemptionFeeBps(1000);

        uint256 id2 = _createMarket(block.timestamp + 7 days);
        assertEq(market.effectiveRedemptionFeeBps(id2), 1000);
    }
}
