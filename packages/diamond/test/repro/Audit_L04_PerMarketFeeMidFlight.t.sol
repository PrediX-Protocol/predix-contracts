// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {IMarketFacet} from "@predix/shared/interfaces/IMarketFacet.sol";

import {MarketFixture} from "../utils/MarketFixture.sol";

/// @notice Repro for AUDIT-L-04 (Professional audit 2026-04-25):
///         `setPerMarketRedemptionFeeBps` is callable at any time before
///         `isResolved || refundModeActive`. After users have already split,
///         admin can raise the per-market override up to `MAX_REDEMPTION_FEE_BPS`
///         (15%), bypassing the `snapshottedDefaultRedemptionFeeBps` protection
///         that exists for the default-fee path.
///
///         FinalH04 covers the snapshot path. This test covers the override path
///         which is the residual exploitation surface.
///
///         These tests demonstrate the bug exists in the current code at HEAD
///         `ce524ba`. They will FAIL when the fix lands (per audit recommendation:
///         constrain `bps <= snapshottedDefaultRedemptionFeeBps` OR lock at
///         first split).
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

    /// @dev DEMONSTRATES BUG: market created with snapshotted default fee = 0.
    ///      Users committed 1M USDC. Admin sets per-market override to 15%
    ///      (max). Winners now pay 15% instead of 0% — admin extracts 150k USDC
    ///      to feeRecipient.
    function test_BUG_AdminSetsOverrideMidFlight_ExtractsMaxFee() public {
        _split(alice, id, SPLIT_AMT);

        // Snapshot = 0 (default at create), no override yet.
        assertEq(market.effectiveRedemptionFeeBps(id), 0, "snapshot should be 0");

        // Admin raises per-market override to MAX (15%) AFTER users split.
        vm.prank(admin);
        market.setPerMarketRedemptionFeeBps(id, 1500);

        // Effective fee is now 15% — bypasses the snapshot protection.
        assertEq(market.effectiveRedemptionFeeBps(id), 1500, "override applies post-split");

        _resolveYes();

        uint256 feeRecipientBefore = usdc.balanceOf(feeRecipient);
        uint256 aliceBefore = usdc.balanceOf(alice);

        vm.prank(alice);
        uint256 payout = market.redeem(id);

        // Alice pays 15% fee that did NOT exist when she committed funds.
        uint256 expectedFee = (SPLIT_AMT * 1500) / 10_000;
        uint256 expectedPayout = SPLIT_AMT - expectedFee;
        assertEq(payout, expectedPayout, "payout reduced by retroactive override");
        assertEq(usdc.balanceOf(alice) - aliceBefore, expectedPayout);
        assertEq(usdc.balanceOf(feeRecipient) - feeRecipientBefore, expectedFee, "admin extracted 15%");
    }

    /// @dev DEMONSTRATES BUG: same vector via `setPerMarketRedemptionFeeBps`
    ///      mid-trade after partial split.
    function test_BUG_OverrideAfterPartialSplit_AppliesToAll() public {
        _split(alice, id, SPLIT_AMT / 2);

        vm.prank(admin);
        market.setPerMarketRedemptionFeeBps(id, 1000); // 10%

        _split(bob, id, SPLIT_AMT / 2);

        _resolveYes();

        uint256 aliceBefore = usdc.balanceOf(alice);
        vm.prank(alice);
        market.redeem(id);
        uint256 aliceFee = (SPLIT_AMT / 2 * 1000) / 10_000;
        assertEq(usdc.balanceOf(alice) - aliceBefore, SPLIT_AMT / 2 - aliceFee);
    }

    /// @dev Sanity: the existing protection IS in place — admin cannot set
    ///      override AFTER the market reaches a final state. The bug is that
    ///      pre-final, override is unconstrained.
    function test_OverrideLocked_AfterResolved() public {
        _split(alice, id, SPLIT_AMT);
        _resolveYes();
        vm.expectRevert(IMarketFacet.Market_FeeLockedAfterFinal.selector);
        vm.prank(admin);
        market.setPerMarketRedemptionFeeBps(id, 1500);
    }

    /// @dev EXPECTED-AFTER-FIX: this test specifies the post-fix behaviour.
    ///      Currently it FAILS because no constraint exists. After the fix
    ///      lands (audit recommendation A: bps <= snapshottedDefault), this
    ///      test will pass. Skip it now via skip-test pattern.
    function test_DESIRED_OverrideCannotExceedSnapshot_PendingFix() public pure {
        // Marker for fix-lock. Convert to non-skip when the fix lands:
        // 1. setDefaultRedemptionFeeBps(0) at create → snapshot 0
        // 2. setPerMarketRedemptionFeeBps(id, 1) MUST revert (override > snapshot)
        // OR audit recommendation B: lock override after first split.
        return;
    }
}
