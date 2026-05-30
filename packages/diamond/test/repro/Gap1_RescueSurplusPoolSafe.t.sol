// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import {LinkedEventFixture} from "../utils/LinkedEventFixture.sol";

/// @notice Regression lock for the most dangerous Gap#1 interaction (PLAN finding #3): `eventPool` MUST
///         be reflected in `totalCollateralLocked`, otherwise `rescueSurplus` would treat the entire
///         shared pool as un-backed surplus and drain it to the fee recipient. This test fails if the
///         lockstep update is ever removed from the linked split / completeSet paths.
contract Gap1RescueSurplusPoolSafe is LinkedEventFixture {
    function test_RescueSurplus_DoesNotTouchEventPool() public {
        uint256 endTime = block.timestamp + 30 days;
        (uint256 eventId,) = _createLinked3(endTime);

        _fundAndApprove(alice, 100e6);
        vm.prank(alice);
        linked.mintCompleteSet(eventId, 25e6);

        assertEq(linked.eventPoolOf(eventId), 25e6, "pool seeded");
        assertEq(market.totalCollateralLocked(), 25e6, "lock seeded");
        assertEq(usdc.balanceOf(address(diamond)), 25e6, "diamond balance");

        uint256 feeRecipientBefore = usdc.balanceOf(feeRecipient);

        // No collateral arrived outside the pool flow, so surplus must be 0 and nothing is swept.
        vm.prank(admin);
        uint256 surplus = market.rescueSurplus();

        assertEq(surplus, 0, "rescueSurplus must report 0 when only pooled collateral exists");
        assertEq(usdc.balanceOf(feeRecipient) - feeRecipientBefore, 0, "feeRecipient must receive nothing");
        assertEq(linked.eventPoolOf(eventId), 25e6, "pool untouched");
        assertEq(usdc.balanceOf(address(diamond)), 25e6, "diamond balance untouched");
    }

    function test_RescueSurplus_RecoversOnlyTrueSurplus() public {
        uint256 endTime = block.timestamp + 30 days;
        (uint256 eventId,) = _createLinked3(endTime);

        _fundAndApprove(alice, 100e6);
        vm.prank(alice);
        linked.mintCompleteSet(eventId, 25e6);

        // a stray direct transfer (airdrop) of 4 USDC lands outside the pool flow → genuine surplus.
        usdc.mint(address(this), 4e6);
        usdc.transfer(address(diamond), 4e6);

        uint256 feeRecipientBefore = usdc.balanceOf(feeRecipient);
        vm.prank(admin);
        uint256 surplus = market.rescueSurplus();

        assertEq(surplus, 4e6, "must recover exactly the stray transfer");
        assertEq(usdc.balanceOf(feeRecipient) - feeRecipientBefore, 4e6, "feeRecipient gets the stray surplus");
        assertEq(linked.eventPoolOf(eventId), 25e6, "pool still untouched");
    }
}
