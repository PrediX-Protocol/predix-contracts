// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import {IEventFacet} from "@predix/shared/interfaces/IEventFacet.sol";
import {IMarketFacet} from "@predix/shared/interfaces/IMarketFacet.sol";

import {EventFixture} from "../utils/EventFixture.sol";

/// @title RedemptionFeeUnification
/// @notice TDD spec for keyti-fqn8: one per-market redemption-fee model for ALL markets (binary +
///         linked-event children). Cap 10%; per-market fee raise/lower freely (no ≤-snapshot rule);
///         per-market setter works on linked children and reverts after endTime; `redeemEvent` charges
///         EACH child's own effective fee on that child's claim and SUMS the net (no event-level fee).
contract RedemptionFeeUnificationTest is EventFixture {
    uint256 internal constant NEW_MAX = 1000; // 10%
    uint256 internal constant BPS = 10_000;

    uint256 internal endTime;

    function setUp() public override {
        super.setUp();
        endTime = block.timestamp + 7 days;
    }

    // -----------------------------------------------------------------------
    // helpers
    // -----------------------------------------------------------------------

    function _setDefault(uint256 bps) internal {
        vm.prank(admin);
        market.setDefaultRedemptionFeeBps(bps);
    }

    function _setPerMarket(uint256 marketId, uint16 bps) internal {
        vm.prank(admin);
        market.setPerMarketRedemptionFeeBps(marketId, bps);
    }

    function _mintSet(address user, uint256 eventId, uint256 amount) internal {
        _fundAndApprove(user, amount);
        vm.prank(user);
        eventFacet.splitEvent(eventId, amount);
    }

    function _resolveWinner(uint256 eventId, uint256 winIdx) internal {
        vm.warp(endTime + 1);
        eventOracle.setEventResolution(eventId, winIdx);
        eventFacet.resolveEvent(eventId);
    }

    // -----------------------------------------------------------------------
    // Hard cap = 10% (down from 15%)
    // -----------------------------------------------------------------------

    function test_Cap_SetDefault_AtNewCeiling() public {
        _setDefault(NEW_MAX);
        assertEq(market.defaultRedemptionFeeBps(), NEW_MAX);
    }

    function test_Revert_SetDefault_AboveNewCeiling() public {
        vm.expectRevert(IMarketFacet.Market_FeeTooHigh.selector);
        vm.prank(admin);
        market.setDefaultRedemptionFeeBps(NEW_MAX + 1);
    }

    function test_Revert_SetPerMarket_AboveNewCeiling() public {
        uint256 id = _createMarket(endTime);
        vm.expectRevert(IMarketFacet.Market_FeeTooHigh.selector);
        vm.prank(admin);
        market.setPerMarketRedemptionFeeBps(id, uint16(NEW_MAX + 1));
    }

    // -----------------------------------------------------------------------
    // Per-market fee: raise OR lower freely (no ≤-snapshot rule)
    // -----------------------------------------------------------------------

    function test_SetPerMarket_RaiseAboveSnapshot() public {
        _setDefault(100); // snapshot 1%
        uint256 id = _createMarket(endTime);
        _setPerMarket(id, 800); // raise to 8% — previously reverted Market_FeeExceedsSnapshot
        assertEq(market.effectiveRedemptionFeeBps(id), 800);
    }

    function test_SetPerMarket_RaiseToCeilingFromZeroSnapshot() public {
        uint256 id = _createMarket(endTime); // snapshot 0 (default 0)
        _setPerMarket(id, uint16(NEW_MAX)); // 10% even though snapshot is 0
        assertEq(market.effectiveRedemptionFeeBps(id), NEW_MAX);
    }

    // -----------------------------------------------------------------------
    // Per-market setter works on LINKED children (guard removed)
    // -----------------------------------------------------------------------

    function test_SetPerMarket_OnLinkedChild() public {
        (, uint256[] memory ids) = _createThreeCandidateEvent(endTime);
        _setPerMarket(ids[0], 700);
        assertEq(market.effectiveRedemptionFeeBps(ids[0]), 700);
    }

    function test_ClearPerMarket_OnLinkedChild() public {
        _setDefault(100);
        (, uint256[] memory ids) = _createThreeCandidateEvent(endTime); // children snapshot 1%
        _setPerMarket(ids[0], 700);
        vm.prank(admin);
        market.clearPerMarketRedemptionFee(ids[0]);
        assertEq(market.effectiveRedemptionFeeBps(ids[0]), 100, "falls back to child snapshot");
    }

    // -----------------------------------------------------------------------
    // Per-market setter reverts once the market has ended
    // -----------------------------------------------------------------------

    function test_Revert_SetPerMarket_RaiseAfterEndTime() public {
        uint256 id = _createMarket(endTime); // snapshot 0
        vm.warp(endTime); // block.timestamp >= endTime
        // A RAISE after the market ends is frozen (in-flight redeemer's fee can't increase).
        vm.expectRevert(IMarketFacet.Market_Ended.selector);
        vm.prank(admin);
        market.setPerMarketRedemptionFeeBps(id, 100);
    }

    /// @dev Remediation path (keyti-fqn8): after endTime the fee may still be LOWERED/waived — this is
    ///      always user-favorable and lets admin undo a retroactive or mis-set fee before users redeem.
    function test_SetPerMarket_LowerAfterEndTime_Allowed() public {
        _setDefault(500); // snapshot 5%
        uint256 id = _createMarket(endTime);
        vm.warp(endTime + 1); // ended
        _setPerMarket(id, 0); // waive to 0 after end — allowed
        assertEq(market.effectiveRedemptionFeeBps(id), 0);
    }

    function test_SetPerMarket_LowerAfterResolved_Allowed() public {
        _setDefault(500);
        uint256 id = _createMarket(endTime);
        oracle.setResolution(id, true);
        vm.warp(endTime + 1);
        market.resolveMarket(id);
        // Even after resolution (before users redeem) admin can waive the fee — remediation.
        _setPerMarket(id, 0);
        assertEq(market.effectiveRedemptionFeeBps(id), 0);
    }

    function test_Revert_ClearPerMarket_AfterEndTime() public {
        uint256 id = _createMarket(endTime);
        vm.warp(endTime + 1);
        vm.expectRevert(IMarketFacet.Market_Ended.selector);
        vm.prank(admin);
        market.clearPerMarketRedemptionFee(id);
    }

    // -----------------------------------------------------------------------
    // redeemEvent: per-child fee (no event-level fee)
    // -----------------------------------------------------------------------

    /// @dev Non-overridden children charge their snapshotted default at redeem.
    function test_RedeemEvent_ChildrenUseSnapshottedDefault() public {
        _setDefault(200); // children snapshot 2%
        (uint256 eventId,) = _createThreeCandidateEvent(endTime);
        _mintSet(alice, eventId, 100e6);
        _resolveWinner(eventId, 1);

        uint256 feeBefore = usdc.balanceOf(feeRecipient);
        vm.prank(alice);
        uint256 payout = eventFacet.redeemEvent(eventId);
        assertEq(payout, 98e6, "winner claim 100 @ 2% snapshot");
        assertEq(usdc.balanceOf(feeRecipient) - feeBefore, 2e6);
        assertEq(eventFacet.eventPoolOf(eventId), 0, "pool drains to 0");
        assertEq(market.totalCollateralLocked(), 0);
    }

    /// @dev A per-child override is honored at redeem for the winning child.
    function test_RedeemEvent_WinnerChildOverride() public {
        _setDefault(0);
        (uint256 eventId, uint256[] memory ids) = _createThreeCandidateEvent(endTime);
        _setPerMarket(ids[2], 300); // winner child 3%
        _mintSet(alice, eventId, 100e6);
        _resolveWinner(eventId, 2);

        uint256 feeBefore = usdc.balanceOf(feeRecipient);
        vm.prank(alice);
        uint256 payout = eventFacet.redeemEvent(eventId);
        assertEq(payout, 97e6);
        assertEq(usdc.balanceOf(feeRecipient) - feeBefore, 3e6);
    }

    /// @dev THE core property: distinct per-child fees, computed separately on each child's claim,
    ///      summed into one net payout. alice holds winner-YES0 (100 at 2%) + loser-NO1 (50 at 5%).
    function test_RedeemEvent_PerChildFee_Summed() public {
        _setDefault(0);
        (uint256 eventId, uint256[] memory ids) = _createThreeCandidateEvent(endTime);
        _setPerMarket(ids[0], 200); // 2%
        _setPerMarket(ids[1], 500); // 5%

        _mintSet(alice, eventId, 100e6); // +100 YES of each child, pool 100
        _split(alice, ids[1], 50e6); // +50 YES1 +50 NO1, pool 150
        _resolveWinner(eventId, 0); // winner child0

        uint256 feeBefore = usdc.balanceOf(feeRecipient);
        uint256 aliceBefore = usdc.balanceOf(alice);
        vm.prank(alice);
        uint256 payout = eventFacet.redeemEvent(eventId);

        // child0 YES0=100 @2% = 2 ; child1 NO1=50 @5% = 2.5 ; fee 4.5, gross 150.
        assertEq(payout, 145_500_000, "gross 150 - summed per-child fee 4.5");
        assertEq(usdc.balanceOf(alice) - aliceBefore, 145_500_000);
        assertEq(usdc.balanceOf(feeRecipient) - feeBefore, 4_500_000);
        assertEq(eventFacet.eventPoolOf(eventId), 0, "pool drains to exactly 0");
        assertEq(market.totalCollateralLocked(), 0, "lockstep restored");
    }

    // -----------------------------------------------------------------------
    // Create-time optional fee (OVERLOAD; omit => default)
    // -----------------------------------------------------------------------

    function test_CreateMarket_WithFee_SnapshotsFee() public {
        _setDefault(100); // default 1% — proves the explicit fee, not the default, is snapshotted
        vm.prank(alice);
        uint256 id = market.createMarketWithFee("Q?", endTime, address(oracle), 750);
        assertEq(market.effectiveRedemptionFeeBps(id), 750);
    }

    function test_CreateMarket_NoFee_UsesDefault() public {
        _setDefault(300);
        uint256 id = _createMarket(endTime); // no-fee overload
        assertEq(market.effectiveRedemptionFeeBps(id), 300);
    }

    function test_Revert_CreateMarket_WithFee_AboveCeiling() public {
        vm.expectRevert(IMarketFacet.Market_FeeTooHigh.selector);
        vm.prank(alice);
        market.createMarketWithFee("Q?", endTime, address(oracle), NEW_MAX + 1);
    }

    function test_CreateEvent_WithFee_SnapshotsIntoChildren() public {
        _setDefault(100);
        string[] memory qs = new string[](3);
        qs[0] = "A";
        qs[1] = "B";
        qs[2] = "C";
        vm.prank(alice);
        (, uint256[] memory ids) = eventFacet.createEventWithFee("E", qs, endTime, address(eventOracle), 600);
        assertEq(market.effectiveRedemptionFeeBps(ids[0]), 600);
        assertEq(market.effectiveRedemptionFeeBps(ids[1]), 600);
        assertEq(market.effectiveRedemptionFeeBps(ids[2]), 600);
    }

    function test_Revert_CreateEvent_WithFee_AboveCeiling() public {
        string[] memory qs = new string[](2);
        qs[0] = "A";
        qs[1] = "B";
        vm.expectRevert(IMarketFacet.Market_FeeTooHigh.selector);
        vm.prank(alice);
        eventFacet.createEventWithFee("E", qs, endTime, address(eventOracle), NEW_MAX + 1);
    }
}
