// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {IEventFacet} from "@predix/shared/interfaces/IEventFacet.sol";
import {IMarketFacet} from "@predix/shared/interfaces/IMarketFacet.sol";
import {IOutcomeToken} from "@predix/shared/interfaces/IOutcomeToken.sol";
import {IDiamondLoupe} from "@predix/shared/interfaces/IDiamondLoupe.sol";

import {EventFacet} from "@predix/diamond/facets/event/EventFacet.sol";

interface ITestUSDC {
    function mint(address to, uint256 amount) external;
}

interface IManualOracleLike {
    function reportEvent(uint256 eventId, uint256 winningIndex) external;
    function challengeDelay() external view returns (uint256);
}

/// @title EventLiveForkE2E
/// @notice Fork verification of the consolidated shared-pool EventFacet on the LIVE chain-130
///         diamond. Skips explicitly until the consolidation cut (Replace lifecycle + Add
///         splitEvent/mergeEvent/redeemEvent/eventPoolOf + Remove legacy selectors) is live —
///         pre-cut coverage is provided by `ConsolidationCutForkSim`, which applies the cut on a
///         fork first. Once live: (a) selector routing + bytecode identity vs THIS source tree,
///         (b) full money flow via the live ManualOracle, (c) live guard behavior.
/// @dev    Requires `UNICHAIN_RPC_PRIMARY` (documented skip otherwise). State mutations are
///         fork-simulated via prank of the real role holders; nothing is broadcast.
contract EventLiveForkE2E is Test {
    // ---- Live chain-130 deployment (source: .testenv.local + mainnet broadcast logs) ----
    address internal constant DIAMOND = 0xC8F12AF2a396c9C906ac36Bc0AC2279BBb69Ef96;
    address internal constant MANUAL_ORACLE = 0x8EDD86CC637FA1ca178ac16f85b6777F05AC0ca7;
    address internal constant USDC = 0xB3FCA863dD0F6b496cCDDf6497Da5Dad67857F56; // TestUSDC (onlyOwner mint)
    /// @dev TestUSDC owner — pranked to fund fork actors (verified via owner()).
    address internal constant USDC_OWNER = 0x0c80F2e7372b669005C9dB68Ab7C704739cd9b82;
    /// @dev Holds CREATOR_ROLE on the live diamond (mainnet ops sender, verified via hasRole).
    address internal constant CREATOR_OPS = 0x8BD105eDD11C4132D2BD6a5DaC7dA5d7a02a48C9;
    /// @dev Holds REPORTER_ROLE on the live ManualOracle (batch-resolve sender, verified via hasRole).
    address internal constant REPORTER_OPS = 0x67934f8010F9E493f44E48d0F2381C175CCd04b1;

    /// @dev Total event selectors carried by the consolidated facet (lifecycle + views + pool ops).
    uint256 internal constant CONSOLIDATED_SELECTOR_COUNT = 13;

    IMarketFacet internal market = IMarketFacet(DIAMOND);
    IEventFacet internal eventFacet = IEventFacet(DIAMOND);
    IDiamondLoupe internal loupe = IDiamondLoupe(DIAMOND);

    address internal alice = makeAddr("fork.alice");
    address internal bob = makeAddr("fork.bob");

    function setUp() public {
        string memory rpc = vm.envOr("UNICHAIN_RPC_PRIMARY", string(""));
        if (bytes(rpc).length == 0) {
            vm.skip(true, "UNICHAIN_RPC_PRIMARY not set - live-fork verification skipped");
            return;
        }
        vm.createSelectFork(rpc);
        require(block.chainid == 130, "expected Unichain mainnet (130)");

        if (loupe.facetAddress(IEventFacet.splitEvent.selector) == address(0)) {
            vm.skip(true, "consolidation cut not yet live on chain-130 - see ConsolidationCutForkSim");
            return;
        }

        vm.startPrank(USDC_OWNER);
        ITestUSDC(USDC).mint(alice, 1_000e6);
        ITestUSDC(USDC).mint(bob, 1_000e6);
        vm.stopPrank();
        vm.prank(alice);
        IERC20(USDC).approve(DIAMOND, type(uint256).max);
        vm.prank(bob);
        IERC20(USDC).approve(DIAMOND, type(uint256).max);
    }

    // -----------------------------------------------------------------------
    // (a) Deployed selectors + bytecode == this source tree
    // -----------------------------------------------------------------------

    function test_Fork_LiveEventFacet_BytecodeMatchesSource() public {
        address liveFacet = loupe.facetAddress(IEventFacet.splitEvent.selector);
        bytes4[8] memory sels = [
            IEventFacet.createEvent.selector,
            IEventFacet.splitEvent.selector,
            IEventFacet.mergeEvent.selector,
            IEventFacet.redeemEvent.selector,
            IEventFacet.eventPoolOf.selector,
            IEventFacet.resolveEvent.selector,
            IEventFacet.emergencyResolveEvent.selector,
            IEventFacet.sweepUnclaimedEvent.selector
        ];
        for (uint256 i; i < sels.length; ++i) {
            assertEq(loupe.facetAddress(sels[i]), liveFacet, "event selector routed to unexpected facet");
        }
        assertEq(
            loupe.facetFunctionSelectors(liveFacet).length,
            CONSOLIDATED_SELECTOR_COUNT,
            "live consolidated facet selector count"
        );
        // Legacy selectors must be gone after the cut: createLinkedEvent, mintCompleteSet,
        // redeemCompleteSet, redeemLinked, isLinkedEvent, addEventOutcome.
        assertEq(loupe.facetAddress(0xa4128ef7), address(0), "createLinkedEvent selector still routed");
        assertEq(loupe.facetAddress(0x8578313a), address(0), "mintCompleteSet selector still routed");
        assertEq(loupe.facetAddress(0x754c7ec3), address(0), "redeemCompleteSet selector still routed");
        assertEq(loupe.facetAddress(0xf1f30c1a), address(0), "redeemLinked selector still routed");
        assertEq(loupe.facetAddress(0xc3bacd82), address(0), "isLinkedEvent selector still routed");

        // Byte-identical runtime code: deploy this tree's EventFacet on the fork and compare
        // codehash (foundry.toml pins bytecode_hash="none", so compilation is deterministic).
        EventFacet local = new EventFacet();
        assertEq(keccak256(address(local).code), keccak256(liveFacet.code), "live facet bytecode != source build");
    }

    // -----------------------------------------------------------------------
    // (b) Full shared-pool flow against the live diamond
    // -----------------------------------------------------------------------

    function test_Fork_Event_FullFlow_LiveDiamond_PoolDrainsToZero() public {
        uint256 endTime = block.timestamp + 1 days;
        string[] memory qs = new string[](3);
        qs[0] = "fork-verify A";
        qs[1] = "fork-verify B";
        qs[2] = "fork-verify C";

        vm.prank(CREATOR_OPS);
        (uint256 eventId, uint256[] memory ids) = eventFacet.createEvent("fork-verify", qs, endTime, MANUAL_ORACLE);
        assertTrue(eventFacet.getEvent(eventId).linked, "live event flagged linked");
        assertEq(ids.length, 3);

        uint256 lockedBefore = market.totalCollateralLocked();

        // splitEvent: pool credit + one YES per outcome.
        vm.prank(alice);
        eventFacet.splitEvent(eventId, 100e6);
        assertEq(eventFacet.eventPoolOf(eventId), 100e6, "pool after event split");

        // Linked-aware split/merge on a child routes to the EVENT pool, not per-child collateral.
        vm.prank(bob);
        market.splitPosition(ids[0], 50e6);
        assertEq(eventFacet.eventPoolOf(eventId), 150e6, "split credited eventPool");
        assertEq(market.getMarket(ids[0]).totalCollateral, 0, "live child holds no per-child collateral");
        vm.prank(bob);
        market.mergePositions(ids[0], 10e6);
        assertEq(eventFacet.eventPoolOf(eventId), 140e6, "merge debited eventPool");

        // Pre-resolution exit: mergeEvent burns one YES of every outcome.
        vm.prank(alice);
        eventFacet.mergeEvent(eventId, 20e6);
        assertEq(eventFacet.eventPoolOf(eventId), 120e6, "pool after event merge");
        _assertLinkedSolvent(eventId);
        assertEq(market.totalCollateralLocked(), lockedBefore + 120e6, "lockstep with global lock");

        // Resolution: the live ManualOracle only accepts event reports AFTER endTime
        // (ManualOracle_BeforeEventEnd), then the 600s challenge window must elapse before
        // the permissionless resolve can consume the outcome.
        vm.warp(endTime + 1);
        vm.prank(REPORTER_OPS);
        IManualOracleLike(MANUAL_ORACLE).reportEvent(eventId, 0);
        vm.warp(block.timestamp + IManualOracleLike(MANUAL_ORACLE).challengeDelay() + 1);
        eventFacet.resolveEvent(eventId);

        // alice: winner-YES0 80; bob: winner-YES0 40 (his NO0 is the winner's NO, worthless).
        uint256 aliceBefore = IERC20(USDC).balanceOf(alice);
        vm.prank(alice);
        uint256 alicePayout = eventFacet.redeemEvent(eventId);
        assertEq(alicePayout, 80e6, "alice winner-YES claim");
        assertEq(IERC20(USDC).balanceOf(alice) - aliceBefore, 80e6);

        vm.prank(bob);
        uint256 bobPayout = eventFacet.redeemEvent(eventId);
        assertEq(bobPayout, 40e6, "bob winner-YES claim");

        assertEq(eventFacet.eventPoolOf(eventId), 0, "live pool drains to exactly 0");
        assertEq(market.totalCollateralLocked(), lockedBefore, "global lock restored to pre-event level");
    }

    // -----------------------------------------------------------------------
    // (c) Live guards on event children
    // -----------------------------------------------------------------------

    function test_Fork_Event_Guards_LiveDiamond() public {
        uint256 endTime = block.timestamp + 1 days;
        string[] memory qs = new string[](2);
        qs[0] = "fork-guard A";
        qs[1] = "fork-guard B";
        vm.prank(CREATOR_OPS);
        (uint256 eventId, uint256[] memory ids) = eventFacet.createEvent("fork-guard", qs, endTime, MANUAL_ORACLE);

        vm.prank(alice);
        eventFacet.splitEvent(eventId, 10e6);

        // Per-child redeem/refund are blocked for event children — pool-level exit only.
        vm.prank(alice);
        vm.expectRevert(IMarketFacet.Market_LinkedEvent.selector);
        market.redeem(ids[0]);
        vm.prank(alice);
        vm.expectRevert(IMarketFacet.Market_LinkedEvent.selector);
        market.refund(ids[0], 1e6, 1e6);

        // splitEvent closes at endTime; mergeEvent stays open (deliberate asymmetry).
        vm.warp(endTime + 1);
        vm.prank(alice);
        vm.expectRevert(IEventFacet.Event_Ended.selector);
        eventFacet.splitEvent(eventId, 1e6);
        vm.prank(alice);
        eventFacet.mergeEvent(eventId, 10e6);
        assertEq(eventFacet.eventPoolOf(eventId), 0, "guard event pool emptied via event merge");
    }

    // -----------------------------------------------------------------------
    // Helpers
    // -----------------------------------------------------------------------

    function _assertLinkedSolvent(uint256 eventId) internal view {
        IEventFacet.EventView memory e = eventFacet.getEvent(eventId);
        if (e.isResolved) return;
        uint256 sumNo;
        int256 m0;
        for (uint256 i; i < e.marketIds.length; ++i) {
            IMarketFacet.MarketView memory m = market.getMarket(e.marketIds[i]);
            int256 margin =
                int256(IOutcomeToken(m.yesToken).totalSupply()) - int256(IOutcomeToken(m.noToken).totalSupply());
            if (i == 0) m0 = margin;
            else assertEq(margin, m0, "M not uniform on live event");
            sumNo += IOutcomeToken(m.noToken).totalSupply();
        }
        assertEq(int256(eventFacet.eventPoolOf(eventId)), int256(sumNo) + m0, "live eventPool != sum(NO_i) + M");
    }
}
