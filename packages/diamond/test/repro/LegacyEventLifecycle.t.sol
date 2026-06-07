// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import {IEventFacet} from "@predix/shared/interfaces/IEventFacet.sol";
import {IMarketFacet} from "@predix/shared/interfaces/IMarketFacet.sol";
import {IOutcomeToken} from "@predix/shared/interfaces/IOutcomeToken.sol";

import {LegacyEventForge} from "../utils/LegacyEventForge.sol";

/// @title LegacyEventLifecycle
/// @notice Consolidation regression lock: chain-130 still carries pre-consolidation LEGACY events
///         (per-child collateral, `linked == false`). The consolidated EventFacet/MarketFacet must
///         keep serving their full lifecycle — resolve → per-child redeem, refund-mode (the gates
///         behind the `Event_LinkedNoRefund` reject), per-child sweep — and must reject the
///         shared-pool ops on them with `Event_NotLinked`. Events here are storage-forged into the
///         exact legacy state (see `LegacyEventForge`) because the legacy creation path no longer
///         exists.
contract LegacyEventLifecycle is LegacyEventForge {
    uint256 internal endTime;

    function setUp() public override {
        super.setUp();
        endTime = block.timestamp + 7 days;
    }

    function _legacyWithSplit(uint256 childIdx, uint256 amount)
        internal
        returns (uint256 eventId, uint256[] memory ids)
    {
        (eventId, ids) = _createThreeCandidateEvent(endTime);
        _split(alice, ids[childIdx], amount);
        _forgeLegacyEvent(eventId);
    }

    function _resolveAt(uint256 eventId, uint256 winIdx) internal {
        vm.warp(endTime + 1);
        eventOracle.setEventResolution(eventId, winIdx);
        eventFacet.resolveEvent(eventId);
    }

    // -----------------------------------------------------------------------
    // Resolve → per-child redeem (the legacy money path)
    // -----------------------------------------------------------------------

    function test_Legacy_Resolve_PerChildRedeem_PaysOut() public {
        (uint256 eventId, uint256[] memory ids) = _legacyWithSplit(1, 100e6);
        _resolveAt(eventId, 1);

        uint256 balBefore = usdc.balanceOf(alice);
        vm.prank(alice);
        uint256 payout = market.redeem(ids[1]);
        assertEq(payout, 100e6, "legacy per-child winner redeem");
        assertEq(usdc.balanceOf(alice) - balBefore, 100e6);
        assertEq(market.getMarket(ids[1]).totalCollateral, 0, "legacy child collateral drained");
    }

    function test_Legacy_Resolve_OnlyLosingLeg_NothingWorthRedeeming() public {
        (uint256 eventId, uint256[] memory ids) = _legacyWithSplit(0, 100e6);
        IMarketFacet.MarketView memory m = market.getMarket(ids[0]);
        vm.prank(alice);
        IOutcomeToken(m.noToken).transfer(bob, 100e6);
        _resolveAt(eventId, 1);

        vm.prank(alice);
        vm.expectRevert(IMarketFacet.Market_NothingWorthRedeeming.selector);
        market.redeem(ids[0]);
    }

    // -----------------------------------------------------------------------
    // Refund-mode: gates + happy path sit BEHIND the linked reject — legacy-only territory
    // -----------------------------------------------------------------------

    function test_Legacy_EnableEventRefundMode_PropagatesAndRefunds() public {
        (uint256 eventId, uint256[] memory ids) = _legacyWithSplit(0, 100e6);
        vm.warp(endTime + 1);
        vm.prank(admin);
        eventFacet.enableEventRefundMode(eventId);

        IEventFacet.EventView memory e = eventFacet.getEvent(eventId);
        assertTrue(e.refundModeActive, "event refund mode set");
        for (uint256 i; i < ids.length; ++i) {
            assertTrue(market.getMarket(ids[i]).refundModeActive, "child refund mode set");
        }

        uint256 balBefore = usdc.balanceOf(alice);
        vm.prank(alice);
        market.refund(ids[0], 100e6, 100e6);
        assertEq(usdc.balanceOf(alice) - balBefore, 100e6, "legacy per-child refund");
    }

    function test_Legacy_Revert_ResolveEvent_RefundModeActive() public {
        (uint256 eventId,) = _legacyWithSplit(0, 1e6);
        vm.warp(endTime + 1);
        vm.prank(admin);
        eventFacet.enableEventRefundMode(eventId);

        eventOracle.setEventResolution(eventId, 0);
        vm.expectRevert(IEventFacet.Event_RefundModeActive.selector);
        eventFacet.resolveEvent(eventId);
    }

    function test_Legacy_Revert_EnableEventRefundMode_StateGates() public {
        // NotEnded
        (uint256 eventId,) = _legacyWithSplit(0, 1e6);
        vm.prank(admin);
        vm.expectRevert(IEventFacet.Event_NotEnded.selector);
        eventFacet.enableEventRefundMode(eventId);

        // RefundModeActive (second enable)
        vm.warp(endTime + 1);
        vm.prank(admin);
        eventFacet.enableEventRefundMode(eventId);
        vm.prank(admin);
        vm.expectRevert(IEventFacet.Event_RefundModeActive.selector);
        eventFacet.enableEventRefundMode(eventId);
    }

    function test_Legacy_Revert_EnableEventRefundMode_AlreadyResolved() public {
        (uint256 eventId,) = _legacyWithSplit(0, 1e6);
        _resolveAt(eventId, 0);
        vm.prank(admin);
        vm.expectRevert(IEventFacet.Event_AlreadyResolved.selector);
        eventFacet.enableEventRefundMode(eventId);
    }

    // -----------------------------------------------------------------------
    // Per-child sweep (legacy residual math) still works
    // -----------------------------------------------------------------------

    function test_Legacy_SweepUnclaimed_RefusesLiveBacking() public {
        (uint256 eventId, uint256[] memory ids) = _legacyWithSplit(0, 100e6);
        _resolveAt(eventId, 1);

        vm.warp(block.timestamp + 365 days + 1);
        vm.prank(admin);
        uint256 swept = market.sweepUnclaimed(ids[0]);
        assertEq(swept, 0, "live outcome-token supply must not be sweepable");
    }

    // -----------------------------------------------------------------------
    // Shared-pool ops must reject legacy events (Event_NotLinked)
    // -----------------------------------------------------------------------

    function test_Legacy_Revert_PoolOps_NotLinked() public {
        (uint256 eventId,) = _legacyWithSplit(0, 1e6);

        _fundAndApprove(alice, 1e6);
        vm.prank(alice);
        vm.expectRevert(IEventFacet.Event_NotLinked.selector);
        eventFacet.splitEvent(eventId, 1e6);

        vm.prank(alice);
        vm.expectRevert(IEventFacet.Event_NotLinked.selector);
        eventFacet.mergeEvent(eventId, 1e6);

        vm.prank(alice);
        vm.expectRevert(IEventFacet.Event_NotLinked.selector);
        eventFacet.redeemEvent(eventId);
    }

    // -----------------------------------------------------------------------
    // Sanity: forged state preserves the global accounting references
    // -----------------------------------------------------------------------

    function test_Legacy_Forge_PreservesGlobalLockAndSolvency() public {
        uint256 lockedBefore = market.totalCollateralLocked();
        (, uint256[] memory ids) = _legacyWithSplit(0, 100e6);
        assertEq(market.totalCollateralLocked(), lockedBefore + 100e6, "global lock unchanged by the forge");
        assertEq(usdc.balanceOf(address(diamond)), market.totalCollateralLocked(), "diamond balance covers the lock");
        IMarketFacet.MarketView memory m = market.getMarket(ids[0]);
        assertEq(m.totalCollateral, 100e6, "per-child collateral re-attributed");
        // Admin rescue must see zero surplus — the forge moved backing, it must not create any.
        vm.prank(admin);
        assertEq(market.rescueSurplus(), 0, "forge created phantom surplus");
    }
}
