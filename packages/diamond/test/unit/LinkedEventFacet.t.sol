// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import {EventFixture} from "../utils/EventFixture.sol";
import {IEventFacet} from "@predix/shared/interfaces/IEventFacet.sol";
import {IMarketFacet} from "@predix/shared/interfaces/IMarketFacet.sol";
import {IOutcomeToken} from "@predix/shared/interfaces/IOutcomeToken.sol";

/// @notice Tasks 4/6/7: createEvent, splitEvent/mergeEvent, redeemEvent.
contract LinkedEventFacetTest is EventFixture {
    uint256 internal endTime;

    function setUp() public override {
        super.setUp();
        endTime = block.timestamp + 30 days;
    }

    // ----------------------------- Task 4: createEvent -----------------------------

    function test_CreateLinkedEvent_SetsFlagsAndChildren() public {
        (uint256 eventId, uint256[] memory ids) = _createThreeCandidateEvent(endTime);

        assertTrue(eventFacet.getEvent(eventId).linked, "event not linked");
        assertEq(eventFacet.eventPoolOf(eventId), 0, "fresh pool != 0");

        IEventFacet.EventView memory e = eventFacet.getEvent(eventId);
        assertEq(e.marketIds.length, 3, "child count");
        for (uint256 i; i < ids.length; ++i) {
            IMarketFacet.MarketView memory m = market.getMarket(ids[i]);
            assertEq(m.eventId, eventId, "child eventId");
            assertEq(m.oracle, address(0), "child oracle must be 0");
            assertEq(m.totalCollateral, 0, "child collateral");
        }
    }

    function test_Revert_CreateLinkedEvent_NotCreator() public {
        string[] memory qs = _defaultQuestions(3);
        vm.prank(bob); // bob lacks CREATOR_ROLE
        vm.expectRevert(IEventFacet.Event_NotCreator.selector);
        eventFacet.createEvent("e", qs, endTime, address(eventOracle));
    }

    function test_Revert_CreateLinkedEvent_TooFewCandidates() public {
        string[] memory qs = _defaultQuestions(1);
        vm.prank(alice);
        vm.expectRevert(IEventFacet.Event_TooFewCandidates.selector);
        eventFacet.createEvent("e", qs, endTime, address(eventOracle));
    }

    // ----------------------------- Task 6: completeSet -----------------------------

    function test_MintCompleteSet_MintsOneYesPerOutcome() public {
        (uint256 eventId, uint256[] memory ids) = _createThreeCandidateEvent(endTime);
        _fundAndApprove(alice, 100e6);

        vm.prank(alice);
        eventFacet.splitEvent(eventId, 10e6);

        assertEq(eventFacet.eventPoolOf(eventId), 10e6, "pool");
        assertEq(market.totalCollateralLocked(), 10e6, "lockstep");
        for (uint256 i; i < ids.length; ++i) {
            IMarketFacet.MarketView memory m = market.getMarket(ids[i]);
            assertEq(IOutcomeToken(m.yesToken).balanceOf(alice), 10e6, "YES_i");
            assertEq(IOutcomeToken(m.noToken).balanceOf(alice), 0, "NO_i must be 0 (completeSet mints YES only)");
        }
    }

    function test_RedeemCompleteSet_ReversesMint() public {
        (uint256 eventId,) = _createThreeCandidateEvent(endTime);
        _fundAndApprove(alice, 100e6);

        vm.startPrank(alice);
        eventFacet.splitEvent(eventId, 10e6);
        eventFacet.mergeEvent(eventId, 4e6);
        vm.stopPrank();

        assertEq(eventFacet.eventPoolOf(eventId), 6e6, "pool after partial redeem");
        assertEq(market.totalCollateralLocked(), 6e6, "lockstep");
    }

    function test_Revert_MintCompleteSet_ZeroAmount() public {
        (uint256 eventId,) = _createThreeCandidateEvent(endTime);
        vm.prank(alice);
        vm.expectRevert(IEventFacet.Event_ZeroAmount.selector);
        eventFacet.splitEvent(eventId, 0);
    }

    function test_Revert_MintCompleteSet_Ended() public {
        (uint256 eventId,) = _createThreeCandidateEvent(endTime);
        _fundAndApprove(alice, 10e6);
        vm.warp(endTime + 1);
        vm.prank(alice);
        vm.expectRevert(IEventFacet.Event_Ended.selector);
        eventFacet.splitEvent(eventId, 1e6);
    }

    // ----------------------------- Task 7: redeemEvent -----------------------------

    function test_RedeemLinked_PaysWinnerYesAndLoserNo() public {
        (uint256 eventId, uint256[] memory ids) = _createThreeCandidateEvent(endTime);
        _fundAndApprove(alice, 100e6);

        // alice mints a complete set (1 YES of each) + splits outcome 1 (gets YES_1 + NO_1).
        vm.startPrank(alice);
        eventFacet.splitEvent(eventId, 10e6); // y_i += 10 each
        market.splitPosition(ids[1], 5e6); // y_1 += 5, n_1 += 5
        vm.stopPrank();

        // pool = 10 (completeSet) + 5 (split) = 15
        assertEq(eventFacet.eventPoolOf(eventId), 15e6, "pool pre-resolve");

        // resolve: outcome 0 wins
        vm.warp(endTime + 1);
        eventOracle.setEventResolution(eventId, 0);
        eventFacet.resolveEvent(eventId);

        // alice holds: YES_0=10 (winner) + NO_1=5 (loser) + NO_2=0; YES_1=15,YES_2=10 are losers' YES (worthless)
        // gross claim = YES_0 (10) + NO_1 (5) = 15 == pool
        uint256 balBefore = usdc.balanceOf(alice);
        vm.prank(alice);
        uint256 payout = eventFacet.redeemEvent(eventId);

        assertEq(payout, 15e6, "payout must equal winning-YES + losing-NO");
        assertEq(usdc.balanceOf(alice) - balBefore, 15e6, "USDC transferred");
        assertEq(eventFacet.eventPoolOf(eventId), 0, "pool fully drained (no funds stuck)");
        assertEq(market.totalCollateralLocked(), 0, "lockstep to zero");
    }

    function test_RedeemLinked_AnyWinner_PoolExactlySolvent() public {
        // For each possible winner k, a fresh event must pay exactly the pool. A monotonic `clock`
        // drives strictly-increasing, always-future endTimes so each iteration's `createEvent`
        // is valid after the previous iteration warped past its endTime to resolve.
        uint256 clock = block.timestamp;
        for (uint256 k; k < 3; ++k) {
            clock += 365 days;
            uint256 localEnd = clock;
            // diagnostic: endTime must be strictly in the future at creation time.
            assertGt(localEnd, block.timestamp, "test setup: endTime not in future");

            (uint256 eventId, uint256[] memory ids) = _createNCandidateEvent(3, localEnd);
            _fundAndApprove(alice, 100e6);

            vm.startPrank(alice);
            eventFacet.splitEvent(eventId, 7e6);
            market.splitPosition(ids[k], 3e6); // skew toward outcome k
            vm.stopPrank();

            uint256 pool = eventFacet.eventPoolOf(eventId);

            vm.warp(localEnd + 1);
            eventOracle.setEventResolution(eventId, k);
            eventFacet.resolveEvent(eventId);

            vm.prank(alice);
            uint256 payout = eventFacet.redeemEvent(eventId);
            assertEq(payout, pool, "payout != pool for some winner k");
            assertEq(eventFacet.eventPoolOf(eventId), 0, "pool not drained");
        }
    }

    function test_Revert_RedeemLinked_NotResolved() public {
        (uint256 eventId,) = _createThreeCandidateEvent(endTime);
        vm.prank(alice);
        vm.expectRevert(IEventFacet.Event_NotResolved.selector);
        eventFacet.redeemEvent(eventId);
    }

    function test_Revert_RedeemLinked_NothingToRedeem() public {
        (uint256 eventId,) = _createThreeCandidateEvent(endTime);
        vm.warp(endTime + 1);
        eventOracle.setEventResolution(eventId, 0);
        eventFacet.resolveEvent(eventId);
        // bob holds nothing
        vm.prank(bob);
        vm.expectRevert(IEventFacet.Event_NothingToRedeem.selector);
        eventFacet.redeemEvent(eventId);
    }

    function test_RedeemLinked_LinkedIsFeeFree_IgnoresDefault() public {
        // v1: linked events are fee-free. Even with a non-zero GLOBAL default fee set, a linked
        // event must ignore it and pay the full claim (owner decision 2026-05-31).
        vm.prank(admin);
        market.setDefaultRedemptionFeeBps(100); // 1% default — linked MUST ignore this

        (uint256 eventId, uint256[] memory ids) = _createThreeCandidateEvent(endTime);
        _fundAndApprove(alice, 100e6);
        vm.startPrank(alice);
        eventFacet.splitEvent(eventId, 10e6); // pool 10, alice holds YES_0..2 = 10 each
        vm.stopPrank();

        vm.warp(endTime + 1);
        eventOracle.setEventResolution(eventId, 0);
        eventFacet.resolveEvent(eventId);

        uint256 feeRecipientBefore = usdc.balanceOf(feeRecipient);
        uint256 aliceBefore = usdc.balanceOf(alice);
        vm.prank(alice);
        uint256 payout = eventFacet.redeemEvent(eventId);

        // Linked is fee-free: grossClaim = YES_0 = 10e6, fee = 0, payout = full 10e6.
        assertEq(payout, 10e6, "linked redeem must be fee-free");
        assertEq(usdc.balanceOf(alice) - aliceBefore, 10e6, "alice gets the full claim");
        assertEq(usdc.balanceOf(feeRecipient) - feeRecipientBefore, 0, "no fee taken for a linked event");
        assertEq(eventFacet.eventPoolOf(eventId), 0, "pool drained to zero");
        ids; // silence unused warning
    }
}
