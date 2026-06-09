// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import {EventFixture} from "../utils/EventFixture.sol";

/// @title LinkedRedeemFee
/// @notice keyti-fqn8 per-child redemption-fee math on the linked redeem path. Fees are now a pure
///         per-MARKET property (snapshotted at creation via `createEventWithFee`, or set per child),
///         and `redeemEvent` charges each child's effective fee on its own claim. These tests pin the
///         money-flow properties for a uniform per-child fee: `fee + payout == grossClaim` exactly, the
///         pool is debited by the FULL gross (so it drains to 0), the fee lands at the fee recipient,
///         and dust amounts floor the fee to zero without stranding a wei.
contract LinkedRedeemFeeTest is EventFixture {
    uint256 internal constant MAX_REDEMPTION_FEE_BPS = 1000; // keyti-fqn8 hard cap (10%)
    uint256 internal constant BPS = 10000;

    /// @dev Create a 3-candidate linked event whose every child snapshots `feeBps` at creation.
    function _createThreeCandidateEventWithFee(uint256 endTime, uint256 feeBps)
        internal
        returns (uint256 eventId, uint256[] memory ids)
    {
        string[] memory qs = _defaultQuestions(3);
        vm.prank(alice);
        (eventId, ids) = eventFacet.createEventWithFee("Who wins?", qs, endTime, address(eventOracle), feeBps);
    }

    function _mintSet(address user, uint256 eventId, uint256 amount) internal {
        _fundAndApprove(user, amount);
        vm.prank(user);
        eventFacet.splitEvent(eventId, amount);
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
        (uint256 eventId, uint256[] memory ids) = _createThreeCandidateEventWithFee(endTime, 500); // 5%

        // alice holds a complete set (100); bob splits child0 (50) so a second winner-YES claim exists.
        _mintSet(alice, eventId, 100e6);
        _split(bob, ids[0], 50e6);
        assertEq(eventFacet.eventPoolOf(eventId), 150e6, "pool = sum NO + M");

        _resolveWinner(eventId, endTime, 0);

        uint256 feeBefore = usdc.balanceOf(feeRecipient);

        // alice: winner-YES0 = 100 gross -> fee 5, payout 95.
        uint256 aliceBefore = usdc.balanceOf(alice);
        vm.prank(alice);
        uint256 alicePayout = eventFacet.redeemEvent(eventId);
        assertEq(alicePayout, 95e6, "alice payout = gross - 5%");
        assertEq(usdc.balanceOf(alice) - aliceBefore, 95e6, "alice received payout");

        // bob: winner-YES0 = 50 gross (his NO0 is the winner's NO, worthless) -> fee 2.5, payout 47.5.
        uint256 bobBefore = usdc.balanceOf(bob);
        vm.prank(bob);
        uint256 bobPayout = eventFacet.redeemEvent(eventId);
        assertEq(bobPayout, 47_500_000, "bob payout = gross - 5%");
        assertEq(usdc.balanceOf(bob) - bobBefore, 47_500_000, "bob received payout");

        // fee recipient got exactly the complement; pool debited by FULL gross -> exactly 0.
        assertEq(usdc.balanceOf(feeRecipient) - feeBefore, 7_500_000, "fee = 5% of 150");
        assertEq(eventFacet.eventPoolOf(eventId), 0, "pool drains to exactly 0 with fee active");
        assertEq(market.totalCollateralLocked(), 0, "global lock back to baseline");
    }

    function test_RedeemLinked_FeePath_MaxBound_1000bps() public {
        uint256 endTime = block.timestamp + 7 days;
        (uint256 eventId,) = _createThreeCandidateEventWithFee(endTime, MAX_REDEMPTION_FEE_BPS);
        _mintSet(alice, eventId, 100e6);

        _resolveWinner(eventId, endTime, 2);

        vm.prank(alice);
        uint256 payout = eventFacet.redeemEvent(eventId);
        assertEq(payout, 90e6, "payout at the 10% ceiling");
        assertEq(usdc.balanceOf(feeRecipient), 10e6, "fee at the 10% ceiling");
        assertEq(eventFacet.eventPoolOf(eventId), 0, "pool drains to 0 at max fee");
    }

    // -----------------------------------------------------------------------
    // Dust regime: floor rounding favors the redeemer, never strands a wei
    // -----------------------------------------------------------------------

    function test_RedeemLinked_FeePath_DustGross_FeeFloorsToZero() public {
        uint256 endTime = block.timestamp + 7 days;
        (uint256 eventId,) = _createThreeCandidateEventWithFee(endTime, 500);
        _mintSet(alice, eventId, 19); // 19 wei gross; 19 * 500 / 10000 = 0 (floor)

        _resolveWinner(eventId, endTime, 1);

        vm.prank(alice);
        uint256 payout = eventFacet.redeemEvent(eventId);
        assertEq(payout, 19, "fee floored to 0, full gross paid");
        assertEq(usdc.balanceOf(feeRecipient), 0, "no fee on dust");
        assertEq(eventFacet.eventPoolOf(eventId), 0, "dust pool drains to 0");
    }

    function testFuzz_RedeemLinked_FeePath_FeePlusPayoutEqualsGross(uint96 amountRaw, uint16 bpsRaw) public {
        uint256 amount = bound(amountRaw, 1, 1_000_000e6);
        uint16 bps = uint16(bound(bpsRaw, 0, MAX_REDEMPTION_FEE_BPS));

        uint256 endTime = block.timestamp + 7 days;
        (uint256 eventId,) = _createThreeCandidateEventWithFee(endTime, bps);
        _mintSet(alice, eventId, amount);

        _resolveWinner(eventId, endTime, 0);

        uint256 feeBefore = usdc.balanceOf(feeRecipient);
        uint256 aliceBefore = usdc.balanceOf(alice);
        vm.prank(alice);
        uint256 payout = eventFacet.redeemEvent(eventId);

        // alice claims a single child (winner YES0), so the per-child floor equals the gross floor.
        uint256 fee = usdc.balanceOf(feeRecipient) - feeBefore;
        assertEq(fee, (amount * bps) / BPS, "fee = floor(gross * bps / 10000)");
        assertEq(payout, amount - fee, "payout = gross - fee");
        assertEq(usdc.balanceOf(alice) - aliceBefore, payout, "transfer matches return value");
        assertEq(eventFacet.eventPoolOf(eventId), 0, "pool debited by FULL gross");
        assertEq(market.totalCollateralLocked(), 0, "lockstep restored");
    }
}
