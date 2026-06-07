// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import {IAccessControlFacet} from "@predix/shared/interfaces/IAccessControlFacet.sol";
import {IEventFacet} from "@predix/shared/interfaces/IEventFacet.sol";
import {IMarketFacet} from "@predix/shared/interfaces/IMarketFacet.sol";
import {IOutcomeToken} from "@predix/shared/interfaces/IOutcomeToken.sol";
import {IPausableFacet} from "@predix/shared/interfaces/IPausableFacet.sol";
import {Modules} from "@predix/shared/constants/Modules.sol";
import {Roles} from "@predix/shared/constants/Roles.sol";

import {EventFixture} from "../utils/EventFixture.sol";

contract EventFacetTest is EventFixture {
    uint256 internal endTime;

    function setUp() public override {
        super.setUp();
        endTime = block.timestamp + 7 days;
    }

    // -----------------------------------------------------------------------
    // createEvent — happy path
    // -----------------------------------------------------------------------

    function test_CreateEvent_TwoCandidates_StoresData() public {
        string[] memory qs = new string[](2);
        qs[0] = "A wins";
        qs[1] = "B wins";
        vm.prank(alice);
        (uint256 eventId, uint256[] memory marketIds) = eventFacet.createEvent("AvB", qs, endTime, address(eventOracle));

        assertEq(eventId, 1);
        assertEq(marketIds.length, 2);
        IEventFacet.EventView memory e = eventFacet.getEvent(eventId);
        assertEq(e.name, "AvB");
        assertEq(e.endTime, endTime);
        assertEq(e.creator, alice);
        assertFalse(e.isResolved);
        assertFalse(e.refundModeActive);
        assertEq(e.oracle, address(eventOracle));
        assertEq(e.marketIds.length, 2);
        assertEq(e.marketIds[0], marketIds[0]);
        assertEq(e.marketIds[1], marketIds[1]);
    }

    function test_CreateEvent_ThreeCandidates_AllChildrenPointBack() public {
        (uint256 eventId, uint256[] memory marketIds) = _createThreeCandidateEvent(endTime);
        for (uint256 i; i < marketIds.length; ++i) {
            assertEq(market.getMarket(marketIds[i]).eventId, eventId);
            assertEq(eventFacet.eventOfMarket(marketIds[i]), eventId);
        }
    }

    function test_CreateEvent_FiftyCandidates() public {
        (uint256 eventId, uint256[] memory marketIds) = _createNCandidateEvent(50, endTime);
        assertEq(marketIds.length, 50);
        assertEq(eventFacet.getEvent(eventId).marketIds.length, 50);
    }

    function test_CreateEvent_IncrementsCount() public {
        _createThreeCandidateEvent(endTime);
        _createThreeCandidateEvent(endTime);
        assertEq(eventFacet.eventCount(), 2);
    }

    function test_CreateEvent_EmitsEvent_AllChildrenEmitMarketCreated() public {
        string[] memory qs = _defaultQuestions(3);

        // Three child markets → three MarketCreated emissions before EventCreated.
        // We only match indexed topics (marketId/creator/oracle) because the YES/NO
        // token addresses are CREATE-derived and not predictable here.
        for (uint256 i; i < 3; ++i) {
            vm.expectEmit(true, true, true, false, address(diamond));
            emit IMarketFacet.MarketCreated(i + 1, alice, address(0), address(0), address(0), endTime, "");
        }

        vm.prank(alice);
        eventFacet.createEvent("E", qs, endTime, address(eventOracle));
        assertEq(eventFacet.eventCount(), 1);
    }

    function test_CreateEvent_ChargesFeePerChild() public {
        vm.prank(admin);
        market.setMarketCreationFee(1e6);

        _fundAndApprove(alice, 3e6);
        uint256 before = usdc.balanceOf(feeRecipient);

        _createThreeCandidateEvent(endTime);

        assertEq(usdc.balanceOf(feeRecipient) - before, 3e6);
    }

    function test_CreateEvent_ChildrenHaveZeroOracle() public {
        (, uint256[] memory marketIds) = _createThreeCandidateEvent(endTime);
        for (uint256 i; i < marketIds.length; ++i) {
            assertEq(market.getMarket(marketIds[i]).oracle, address(0));
        }
    }

    function test_CreateEvent_ChildrenShareEndTime() public {
        (, uint256[] memory marketIds) = _createThreeCandidateEvent(endTime);
        for (uint256 i; i < marketIds.length; ++i) {
            assertEq(market.getMarket(marketIds[i]).endTime, endTime);
        }
    }

    // -----------------------------------------------------------------------
    // createEvent — reverts
    // -----------------------------------------------------------------------

    function test_Revert_CreateEvent_EmptyName() public {
        string[] memory qs = _defaultQuestions(2);
        vm.expectRevert(IEventFacet.Event_EmptyName.selector);
        vm.prank(alice);
        eventFacet.createEvent("", qs, endTime, address(eventOracle));
    }

    function test_Revert_CreateEvent_PastEndTime() public {
        string[] memory qs = _defaultQuestions(2);
        vm.expectRevert(IEventFacet.Event_InvalidEndTime.selector);
        vm.prank(alice);
        eventFacet.createEvent("E", qs, block.timestamp, address(eventOracle));
    }

    function test_Revert_CreateEvent_TooFew_Zero() public {
        string[] memory qs = new string[](0);
        vm.expectRevert(IEventFacet.Event_TooFewCandidates.selector);
        vm.prank(alice);
        eventFacet.createEvent("E", qs, endTime, address(eventOracle));
    }

    function test_Revert_CreateEvent_TooFew_One() public {
        string[] memory qs = _defaultQuestions(1);
        vm.expectRevert(IEventFacet.Event_TooFewCandidates.selector);
        vm.prank(alice);
        eventFacet.createEvent("E", qs, endTime, address(eventOracle));
    }

    function test_Revert_CreateEvent_TooMany() public {
        string[] memory qs = _defaultQuestions(51);
        vm.expectRevert(IEventFacet.Event_TooManyCandidates.selector);
        vm.prank(alice);
        eventFacet.createEvent("E", qs, endTime, address(eventOracle));
    }

    function test_Revert_CreateEvent_EmptyCandidateQuestion() public {
        string[] memory qs = _defaultQuestions(3);
        qs[2] = "";
        vm.expectRevert(IMarketFacet.Market_EmptyQuestion.selector);
        vm.prank(alice);
        eventFacet.createEvent("E", qs, endTime, address(eventOracle));

        // No partial state should have been written.
        assertEq(eventFacet.eventCount(), 0);
        assertEq(market.marketCount(), 0);
    }

    function test_Revert_CreateEvent_MarketModulePaused() public {
        vm.prank(admin);
        pausable.pauseModule(Modules.MARKET);

        string[] memory qs = _defaultQuestions(2);
        vm.expectRevert(abi.encodeWithSelector(IPausableFacet.Pausable_EnforcedPause.selector, Modules.MARKET));
        vm.prank(alice);
        eventFacet.createEvent("E", qs, endTime, address(eventOracle));
    }

    function test_Revert_CreateEvent_ZeroOracle() public {
        string[] memory qs = _defaultQuestions(2);
        vm.expectRevert(IEventFacet.Event_ZeroOracle.selector);
        vm.prank(alice);
        eventFacet.createEvent("E", qs, endTime, address(0));
    }

    function test_Revert_CreateEvent_OracleNotApproved() public {
        string[] memory qs = _defaultQuestions(2);
        vm.expectRevert(IEventFacet.Event_OracleNotApproved.selector);
        vm.prank(alice);
        eventFacet.createEvent("E", qs, endTime, makeAddr("unapproved"));
    }

    // -----------------------------------------------------------------------
    // resolveEvent — happy path
    // -----------------------------------------------------------------------

    function _resolveAt(uint256 eventId, uint256 winningIndex) internal {
        vm.warp(endTime + 1);
        eventOracle.setEventResolution(eventId, winningIndex);
        eventFacet.resolveEvent(eventId);
    }

    function test_ResolveEvent_WinnerFirst() public {
        (uint256 eventId, uint256[] memory marketIds) = _createThreeCandidateEvent(endTime);
        _resolveAt(eventId, 0);
        assertTrue(market.getMarket(marketIds[0]).outcome);
        assertFalse(market.getMarket(marketIds[1]).outcome);
        assertFalse(market.getMarket(marketIds[2]).outcome);
    }

    function test_ResolveEvent_WinnerMiddle() public {
        (uint256 eventId, uint256[] memory marketIds) = _createThreeCandidateEvent(endTime);
        _resolveAt(eventId, 1);
        assertFalse(market.getMarket(marketIds[0]).outcome);
        assertTrue(market.getMarket(marketIds[1]).outcome);
        assertFalse(market.getMarket(marketIds[2]).outcome);
    }

    function test_ResolveEvent_WinnerLast() public {
        (uint256 eventId, uint256[] memory marketIds) = _createThreeCandidateEvent(endTime);
        _resolveAt(eventId, 2);
        assertFalse(market.getMarket(marketIds[0]).outcome);
        assertFalse(market.getMarket(marketIds[1]).outcome);
        assertTrue(market.getMarket(marketIds[2]).outcome);
    }

    function test_ResolveEvent_EmitsEventResolved_AndOneMarketResolvedPerChild() public {
        (uint256 eventId, uint256[] memory marketIds) = _createThreeCandidateEvent(endTime);
        vm.warp(endTime + 1);
        eventOracle.setEventResolution(eventId, 0);

        for (uint256 i; i < marketIds.length; ++i) {
            vm.expectEmit(true, true, true, true, address(diamond));
            emit IMarketFacet.MarketResolved(marketIds[i], i == 0, address(this));
        }
        vm.expectEmit(true, true, true, true, address(diamond));
        emit IEventFacet.EventResolved(eventId, 0, address(this));

        eventFacet.resolveEvent(eventId);
    }

    function test_ResolveEvent_SetsAllChildrenOutcomes() public {
        (uint256 eventId, uint256[] memory marketIds) = _createThreeCandidateEvent(endTime);
        _resolveAt(eventId, 1);
        uint256 winners;
        uint256 losers;
        for (uint256 i; i < marketIds.length; ++i) {
            IMarketFacet.MarketView memory m = market.getMarket(marketIds[i]);
            assertTrue(m.isResolved);
            assertEq(m.resolvedAt, block.timestamp);
            if (m.outcome) winners++;
            else losers++;
        }
        assertEq(winners, 1);
        assertEq(losers, 2);

        IEventFacet.EventView memory e = eventFacet.getEvent(eventId);
        assertTrue(e.isResolved);
        assertEq(e.winningIndex, 1);
        assertEq(e.resolvedAt, block.timestamp);
    }

    // -----------------------------------------------------------------------
    // resolveEvent — reverts
    // -----------------------------------------------------------------------

    function test_Revert_ResolveEvent_OracleNotResolved() public {
        (uint256 eventId,) = _createThreeCandidateEvent(endTime);
        vm.warp(endTime + 1);
        vm.expectRevert(IEventFacet.Event_OracleNotResolved.selector);
        eventFacet.resolveEvent(eventId);
    }

    function test_Revert_ResolveEvent_OracleNotApproved() public {
        (uint256 eventId,) = _createThreeCandidateEvent(endTime);
        vm.warp(endTime + 1);
        eventOracle.setEventResolution(eventId, 0);
        vm.prank(admin);
        market.revokeOracle(address(eventOracle));
        vm.expectRevert(IEventFacet.Event_OracleNotApproved.selector);
        eventFacet.resolveEvent(eventId);
    }

    function test_Revert_ResolveEvent_NotFound() public {
        vm.expectRevert(IEventFacet.Event_NotFound.selector);
        eventFacet.resolveEvent(999);
    }

    function test_Revert_ResolveEvent_AlreadyResolved() public {
        (uint256 eventId,) = _createThreeCandidateEvent(endTime);
        _resolveAt(eventId, 0);
        vm.expectRevert(IEventFacet.Event_AlreadyResolved.selector);
        eventFacet.resolveEvent(eventId);
    }

    function test_Revert_ResolveEvent_NotEnded() public {
        (uint256 eventId,) = _createThreeCandidateEvent(endTime);
        eventOracle.setEventResolution(eventId, 0);
        vm.expectRevert(IEventFacet.Event_NotEnded.selector);
        eventFacet.resolveEvent(eventId);
    }

    function test_Revert_ResolveEvent_InvalidWinningIndex() public {
        (uint256 eventId,) = _createThreeCandidateEvent(endTime);
        vm.warp(endTime + 1);
        eventOracle.setEventResolution(eventId, 3);
        vm.expectRevert(IEventFacet.Event_InvalidWinningIndex.selector);
        eventFacet.resolveEvent(eventId);
    }

    // NOTE (consolidation): resolveEvent-vs-refundMode and the refund-mode happy paths are only
    // reachable for pre-consolidation legacy events (`linked == false`) — they are locked by the
    // storage-forged `LegacyEventLifecycle` repro. `enableEventRefundMode` on a (now always
    // shared-pool) event reverts `Event_LinkedNoRefund` — covered in `LinkedEventGuards`.

    // -----------------------------------------------------------------------
    // MarketFacet.* blocked on event children (CORE invariant)
    // -----------------------------------------------------------------------

    function test_Revert_MarketFacet_ResolveMarket_PartOfEvent() public {
        (, uint256[] memory marketIds) = _createThreeCandidateEvent(endTime);
        vm.warp(endTime + 1);
        vm.expectRevert(IMarketFacet.Market_PartOfEvent.selector);
        market.resolveMarket(marketIds[0]);
    }

    function test_Revert_MarketFacet_EmergencyResolve_PartOfEvent() public {
        (, uint256[] memory marketIds) = _createThreeCandidateEvent(endTime);
        vm.warp(endTime + 7 days + 1);
        vm.expectRevert(IMarketFacet.Market_PartOfEvent.selector);
        vm.prank(admin);
        market.emergencyResolve(marketIds[0], true);
    }

    function test_Revert_MarketFacet_EnableRefundMode_PartOfEvent() public {
        (, uint256[] memory marketIds) = _createThreeCandidateEvent(endTime);
        vm.warp(endTime + 1);
        vm.expectRevert(IMarketFacet.Market_PartOfEvent.selector);
        vm.prank(admin);
        market.enableRefundMode(marketIds[0]);
    }

    // -----------------------------------------------------------------------
    // enableEventRefundMode
    // -----------------------------------------------------------------------

    function test_Revert_EnableEventRefundMode_NotAdmin() public {
        (uint256 eventId,) = _createThreeCandidateEvent(endTime);
        vm.warp(endTime + 1);
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControlFacet.AccessControl_MissingRole.selector, Roles.ADMIN_ROLE, alice)
        );
        vm.prank(alice);
        eventFacet.enableEventRefundMode(eventId);
    }

    function test_Revert_EnableEventRefundMode_NotFound() public {
        vm.prank(admin);
        vm.expectRevert(IEventFacet.Event_NotFound.selector);
        eventFacet.enableEventRefundMode(999);
    }

    // NOTE (consolidation): the AlreadyResolved/NotEnded/RefundModeActive state gates of
    // `enableEventRefundMode` sit BEHIND the `Event_LinkedNoRefund` reject and are reachable only
    // for legacy events — locked by the storage-forged `LegacyEventLifecycle` repro.

    // -----------------------------------------------------------------------
    // Child-market trading
    // -----------------------------------------------------------------------

    function test_SplitPosition_OnEventChild_RoutesToEventPool() public {
        (uint256 eventId, uint256[] memory marketIds) = _createThreeCandidateEvent(endTime);
        _split(alice, marketIds[0], 50e6);
        assertEq(market.getMarket(marketIds[0]).totalCollateral, 0, "child must hold no per-child collateral");
        assertEq(eventFacet.eventPoolOf(eventId), 50e6, "split credits the shared pool");
    }

    function test_MergePositions_OnEventChild_DebitsEventPool() public {
        (uint256 eventId, uint256[] memory marketIds) = _createThreeCandidateEvent(endTime);
        _split(alice, marketIds[0], 50e6);
        vm.prank(alice);
        market.mergePositions(marketIds[0], 20e6);
        assertEq(market.getMarket(marketIds[0]).totalCollateral, 0, "child must hold no per-child collateral");
        assertEq(eventFacet.eventPoolOf(eventId), 30e6, "merge debits the shared pool");
    }

    function test_Redeem_OnEventChild_Blocked_RedeemEventPaysOut() public {
        (uint256 eventId, uint256[] memory marketIds) = _createThreeCandidateEvent(endTime);
        _split(alice, marketIds[1], 100e6);
        _resolveAt(eventId, 1);

        // Per-child redeem is blocked — the claim flows through the shared pool instead.
        vm.prank(alice);
        vm.expectRevert(IMarketFacet.Market_LinkedEvent.selector);
        market.redeem(marketIds[1]);

        uint256 balBefore = usdc.balanceOf(alice);
        vm.prank(alice);
        uint256 payout = eventFacet.redeemEvent(eventId);
        assertEq(payout, 100e6, "winner-YES claim pays from the pool");
        assertEq(usdc.balanceOf(alice) - balBefore, 100e6);
        assertEq(eventFacet.eventPoolOf(eventId), 0, "pool drains to exactly 0");
    }

    function test_Revert_RedeemEvent_OnlyLosingYes_NothingToRedeem() public {
        (uint256 eventId, uint256[] memory marketIds) = _createThreeCandidateEvent(endTime);
        // alice splits on the losing child, then offloads her NO leg to bob so her remaining
        // YES leg is a pure loser position once the event settles.
        _split(alice, marketIds[0], 100e6);
        IMarketFacet.MarketView memory m = market.getMarket(marketIds[0]);
        vm.prank(alice);
        IOutcomeToken(m.noToken).transfer(bob, 100e6);

        _resolveAt(eventId, 1);

        // alice holds only loser-YES — worthless, redeemEvent refuses (her balance is preserved).
        uint256 aliceYesBefore = IOutcomeToken(m.yesToken).balanceOf(alice);
        vm.prank(alice);
        vm.expectRevert(IEventFacet.Event_NothingToRedeem.selector);
        eventFacet.redeemEvent(eventId);
        assertEq(IOutcomeToken(m.yesToken).balanceOf(alice), aliceYesBefore);

        // bob holds loser-NO — that leg pays the pool's full backing.
        vm.prank(bob);
        assertEq(eventFacet.redeemEvent(eventId), 100e6, "loser-NO claim pays from the pool");
        assertEq(eventFacet.eventPoolOf(eventId), 0, "pool drains to exactly 0");
    }

    function test_Revert_SweepUnclaimed_OnEventChild() public {
        (uint256 eventId, uint256[] memory marketIds) = _createThreeCandidateEvent(endTime);
        _split(alice, marketIds[0], 100e6);
        _resolveAt(eventId, 1);

        // Event children carry no per-child collateral; the per-child residual sweep is rejected
        // outright (pool-level sweep is deferred to v1.1).
        vm.warp(block.timestamp + 365 days + 1);
        vm.prank(admin);
        vm.expectRevert(IMarketFacet.Market_LinkedEvent.selector);
        market.sweepUnclaimed(marketIds[0]);
    }

    // -----------------------------------------------------------------------
    // Views
    // -----------------------------------------------------------------------

    function test_GetEvent_ReturnsCorrectSnapshot() public {
        (uint256 eventId, uint256[] memory marketIds) = _createThreeCandidateEvent(endTime);
        IEventFacet.EventView memory e = eventFacet.getEvent(eventId);
        assertEq(e.name, "Who wins?");
        assertEq(e.marketIds.length, marketIds.length);
        assertEq(e.endTime, endTime);
        assertEq(e.creator, alice);
        assertEq(e.oracle, address(eventOracle));
        assertFalse(e.isResolved);
    }

    function test_EventOfMarket_ReturnsParent() public {
        (uint256 eventId, uint256[] memory marketIds) = _createThreeCandidateEvent(endTime);
        assertEq(eventFacet.eventOfMarket(marketIds[1]), eventId);
    }

    function test_EventOfMarket_StandaloneReturnsZero() public {
        uint256 standalone = _createMarket(endTime);
        assertEq(eventFacet.eventOfMarket(standalone), 0);
    }

    function test_EventCount_MonotonicIncrement() public {
        assertEq(eventFacet.eventCount(), 0);
        _createThreeCandidateEvent(endTime);
        assertEq(eventFacet.eventCount(), 1);
        _createThreeCandidateEvent(endTime);
        assertEq(eventFacet.eventCount(), 2);
    }

    // -----------------------------------------------------------------------
    // Fuzz
    // -----------------------------------------------------------------------

    function testFuzz_CreateEvent_AnyValidCandidateCount(uint8 nRaw) public {
        uint256 n = bound(nRaw, 2, 50);
        (uint256 eventId, uint256[] memory marketIds) = _createNCandidateEvent(n, endTime);
        assertEq(marketIds.length, n);
        for (uint256 i; i < n; ++i) {
            assertEq(eventFacet.eventOfMarket(marketIds[i]), eventId);
        }
    }

    function testFuzz_ResolveEvent_AnyWinningIndex(uint8 nRaw, uint8 winIdxRaw) public {
        uint256 n = bound(nRaw, 2, 10);
        uint256 winIdx = bound(winIdxRaw, 0, n - 1);
        (uint256 eventId, uint256[] memory marketIds) = _createNCandidateEvent(n, endTime);
        _resolveAt(eventId, winIdx);
        for (uint256 i; i < n; ++i) {
            IMarketFacet.MarketView memory m = market.getMarket(marketIds[i]);
            assertTrue(m.isResolved);
            assertEq(m.outcome, i == winIdx);
        }
    }

    /// @notice F4 regression — resolveEvent reverts when MARKET module is paused.
    function test_Revert_ResolveEvent_WhenPaused() public {
        (uint256 eventId,) = _createNCandidateEvent(2, endTime);
        vm.warp(endTime + 1);
        eventOracle.setEventResolution(eventId, 0);
        vm.prank(admin);
        pausable.pauseModule(Modules.MARKET);
        vm.expectRevert(abi.encodeWithSelector(IPausableFacet.Pausable_EnforcedPause.selector, Modules.MARKET));
        eventFacet.resolveEvent(eventId);
    }
}
