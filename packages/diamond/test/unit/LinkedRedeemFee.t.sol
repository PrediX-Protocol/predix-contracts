// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import {IEventFacet} from "@predix/shared/interfaces/IEventFacet.sol";

import {LinkedEventFixture} from "../utils/LinkedEventFixture.sol";

/// @title LinkedRedeemFee
/// @notice Gap#1 v1.1 fee-path verification (keyti-3c3g.10 gap 4). In v1 `EventData.redemptionFeeBps`
///         is never written (no setter exists), so `redeemLinked`'s fee branch is dead code at 0 bps.
///         These tests force a non-zero fee directly into the documented slot-7 packing (bytes 23-24,
///         same offsets `Gap1UpgradeStorageBrick` pins) and prove the retained branch is CORRECT for
///         v1.1: `fee + payout == grossClaim` exactly, the pool is debited by the FULL gross (so it
///         still drains to 0), the fee lands at the fee recipient, and dust amounts floor the fee to
///         zero without stranding a wei.
contract LinkedRedeemFeeTest is LinkedEventFixture {
    // keccak256("predix.storage.event.v1") — LibEventStorage.SLOT.
    bytes32 internal constant EVENT_SLOT = keccak256("predix.storage.event.v1");
    // Mirrors MarketFacet.MAX_REDEMPTION_FEE_BPS — the bound a v1.1 setter must enforce.
    uint16 internal constant MAX_REDEMPTION_FEE_BPS = 1500;
    uint256 internal constant BPS = 10000;

    /// @dev Write `bps` into EventData slot 7 bytes 23-24 (`redemptionFeeBps`), preserving every other
    ///      packed field, then fail-loud cross-check via getters that ONLY the fee changed.
    function _setLinkedFee(uint256 eventId, uint16 bps) internal {
        bytes32 base = keccak256(abi.encode(eventId, uint256(EVENT_SLOT) + 1));
        bytes32 slot = bytes32(uint256(base) + 7);
        IEventFacet.EventView memory before_ = eventFacet.getEvent(eventId);
        bool linkedBefore = linked.isLinkedEvent(eventId);

        uint256 word = uint256(vm.load(address(diamond), slot));
        word = (word & ~(uint256(0xFFFF) << (8 * 23))) | (uint256(bps) << (8 * 23));
        vm.store(address(diamond), slot, bytes32(word));

        IEventFacet.EventView memory after_ = eventFacet.getEvent(eventId);
        assertEq(after_.oracle, before_.oracle, "fee store corrupted oracle");
        assertEq(after_.isResolved, before_.isResolved, "fee store corrupted isResolved");
        assertEq(after_.refundModeActive, before_.refundModeActive, "fee store corrupted refundModeActive");
        assertEq(linked.isLinkedEvent(eventId), linkedBefore, "fee store corrupted linked flag");
    }

    function _mintSet(address user, uint256 eventId, uint256 amount) internal {
        _fundAndApprove(user, amount);
        vm.prank(user);
        linked.mintCompleteSet(eventId, amount);
    }

    function _resolveWinner(uint256 eventId, uint256 endTime, uint256 winIdx) internal {
        vm.warp(endTime + 1);
        eventOracle.setEventResolution(eventId, winIdx);
        eventFacet.resolveEvent(eventId);
    }

    // -----------------------------------------------------------------------
    // Non-zero fee: exact split, full-gross pool debit, drains to 0
    // -----------------------------------------------------------------------

    function test_RedeemLinked_FeePath_ExactSplit_PoolDrainsToZero() public {
        uint256 endTime = block.timestamp + 7 days;
        (uint256 eventId, uint256[] memory ids) = _createLinked3(endTime);

        // alice holds a complete set (100); bob splits child0 (50) so a loser-NO claim exists too.
        _mintSet(alice, eventId, 100e6);
        _split(bob, ids[0], 50e6);
        assertEq(linked.eventPoolOf(eventId), 150e6, "pool = sum NO + M");

        _setLinkedFee(eventId, 500); // 5%
        _resolveWinner(eventId, endTime, 0);

        uint256 feeBefore = usdc.balanceOf(feeRecipient);

        // alice: winner-YES0 = 100 gross -> fee 5, payout 95.
        uint256 aliceBefore = usdc.balanceOf(alice);
        vm.prank(alice);
        uint256 alicePayout = linked.redeemLinked(eventId);
        assertEq(alicePayout, 95e6, "alice payout = gross - 5%");
        assertEq(usdc.balanceOf(alice) - aliceBefore, 95e6, "alice received payout");

        // bob: winner-YES0 = 50 gross (his NO0 is the winner's NO, worthless) -> fee 2.5, payout 47.5.
        uint256 bobBefore = usdc.balanceOf(bob);
        vm.prank(bob);
        uint256 bobPayout = linked.redeemLinked(eventId);
        assertEq(bobPayout, 47_500_000, "bob payout = gross - 5%");
        assertEq(usdc.balanceOf(bob) - bobBefore, 47_500_000, "bob received payout");

        // fee recipient got exactly the complement; pool debited by FULL gross -> exactly 0.
        assertEq(usdc.balanceOf(feeRecipient) - feeBefore, 7_500_000, "fee = 5% of 150");
        assertEq(linked.eventPoolOf(eventId), 0, "pool drains to exactly 0 with fee active");
        assertEq(market.totalCollateralLocked(), 0, "global lock back to baseline");
    }

    function test_RedeemLinked_FeePath_MaxBound_1500bps() public {
        uint256 endTime = block.timestamp + 7 days;
        (uint256 eventId,) = _createLinked3(endTime);
        _mintSet(alice, eventId, 100e6);

        _setLinkedFee(eventId, MAX_REDEMPTION_FEE_BPS);
        _resolveWinner(eventId, endTime, 2);

        vm.prank(alice);
        uint256 payout = linked.redeemLinked(eventId);
        assertEq(payout, 85e6, "payout at the 15% ceiling");
        assertEq(usdc.balanceOf(feeRecipient), 15e6, "fee at the 15% ceiling");
        assertEq(linked.eventPoolOf(eventId), 0, "pool drains to 0 at max fee");
    }

    // -----------------------------------------------------------------------
    // Dust regime: floor rounding favors the redeemer, never strands a wei
    // -----------------------------------------------------------------------

    function test_RedeemLinked_FeePath_DustGross_FeeFloorsToZero() public {
        uint256 endTime = block.timestamp + 7 days;
        (uint256 eventId,) = _createLinked3(endTime);
        _mintSet(alice, eventId, 19); // 19 wei gross; 19 * 500 / 10000 = 0 (floor)

        _setLinkedFee(eventId, 500);
        _resolveWinner(eventId, endTime, 1);

        vm.prank(alice);
        uint256 payout = linked.redeemLinked(eventId);
        assertEq(payout, 19, "fee floored to 0, full gross paid");
        assertEq(usdc.balanceOf(feeRecipient), 0, "no fee on dust");
        assertEq(linked.eventPoolOf(eventId), 0, "dust pool drains to 0");
    }

    function testFuzz_RedeemLinked_FeePath_FeePlusPayoutEqualsGross(uint96 amountRaw, uint16 bpsRaw) public {
        uint256 amount = bound(amountRaw, 1, 1_000_000e6);
        uint16 bps = uint16(bound(bpsRaw, 0, MAX_REDEMPTION_FEE_BPS));

        uint256 endTime = block.timestamp + 7 days;
        (uint256 eventId,) = _createLinked3(endTime);
        _mintSet(alice, eventId, amount);

        _setLinkedFee(eventId, bps);
        _resolveWinner(eventId, endTime, 0);

        uint256 feeBefore = usdc.balanceOf(feeRecipient);
        uint256 aliceBefore = usdc.balanceOf(alice);
        vm.prank(alice);
        uint256 payout = linked.redeemLinked(eventId);

        uint256 fee = usdc.balanceOf(feeRecipient) - feeBefore;
        assertEq(fee, (amount * bps) / BPS, "fee = floor(gross * bps / 10000)");
        assertEq(payout, amount - fee, "payout = gross - fee");
        assertEq(usdc.balanceOf(alice) - aliceBefore, payout, "transfer matches return value");
        assertEq(linked.eventPoolOf(eventId), 0, "pool debited by FULL gross");
        assertEq(market.totalCollateralLocked(), 0, "lockstep restored");
    }
}
