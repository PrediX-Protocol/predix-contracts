// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {IDiamondCut} from "@predix/shared/interfaces/IDiamondCut.sol";
import {IDiamondLoupe} from "@predix/shared/interfaces/IDiamondLoupe.sol";
import {IEventFacet} from "@predix/shared/interfaces/IEventFacet.sol";
import {IMarketFacet} from "@predix/shared/interfaces/IMarketFacet.sol";

import {EventFacet} from "@predix/diamond/facets/event/EventFacet.sol";
import {ConsolidateEventFacet} from "../../script/ConsolidateEventFacet.s.sol";

interface ITestUSDCSim {
    function mint(address to, uint256 amount) external;
}

interface IManualOracleSim {
    function reportEvent(uint256 eventId, uint256 winningIndex) external;
    function challengeDelay() external view returns (uint256);
}

/// @notice Upgrade-safety regression for the CONSOLIDATION cut: against the LIVE chain-130 diamond
///         (forked), execute the real cut AS the Timelock and assert (1) no brick — every
///         pre-existing market/event/locked-collateral fact survives, the live ManualOracle still
///         resolves a freshly created (now shared-pool) event end-to-end, and the legacy selectors
///         are gone; (2) the cut is REVERSIBLE — a rollback cut restores the exact pre-upgrade
///         routing with funds intact. Selector lists come from `ConsolidateEventFacet.buildCuts`
///         (single source of truth with the mainnet dry-run script).
/// @dev Requires env UNICHAIN_RPC_PRIMARY / DIAMOND_ADDRESS / TIMELOCK_ADDRESS (fail-loud, fork-dir
///      convention). Skips once the cut is already live. Live role holders are pranked; nothing is
///      broadcast.
contract ConsolidationCutForkSim is Test {
    address internal constant MANUAL_ORACLE = 0x8EDD86CC637FA1ca178ac16f85b6777F05AC0ca7;
    address internal constant USDC = 0xB3FCA863dD0F6b496cCDDf6497Da5Dad67857F56;
    address internal constant USDC_OWNER = 0x0c80F2e7372b669005C9dB68Ab7C704739cd9b82;
    address internal constant CREATOR_OPS = 0x8BD105eDD11C4132D2BD6a5DaC7dA5d7a02a48C9;
    address internal constant REPORTER_OPS = 0x67934f8010F9E493f44E48d0F2381C175CCd04b1;

    ConsolidateEventFacet internal cutScript;

    function _forkOrSkip() internal returns (address diamond, address timelock) {
        vm.createSelectFork(vm.envString("UNICHAIN_RPC_PRIMARY"));
        // Deployed AFTER the fork switch — contracts created pre-fork don't carry over.
        cutScript = new ConsolidateEventFacet();
        diamond = vm.envAddress("DIAMOND_ADDRESS");
        timelock = vm.envAddress("TIMELOCK_ADDRESS");
        if (IDiamondLoupe(diamond).facetAddress(IEventFacet.splitEvent.selector) != address(0)) {
            vm.skip(true, "consolidation cut already live on the forked diamond - sim not applicable");
        }
    }

    function test_Fork_ConsolidationCut_NoBrick_LiveDiamond() public {
        (address diamond, address timelock) = _forkOrSkip();

        // --- snapshot the live state pre-upgrade ---
        uint256 mcBefore = IMarketFacet(diamond).marketCount();
        uint256 ecBefore = IEventFacet(diamond).eventCount();
        uint256 lockedBefore = IMarketFacet(diamond).totalCollateralLocked();
        uint256 usdcBefore = IERC20(USDC).balanceOf(diamond);
        assertGt(mcBefore, 0, "no live markets to test against");
        assertGt(ecBefore, 0, "no live events to test against");
        IMarketFacet.MarketView memory mBefore = IMarketFacet(diamond).getMarket(mcBefore);

        // --- EXECUTE the real cut as the authorized Timelock (CUT_EXECUTOR) ---
        // (cuts computed BEFORE the prank — the external buildCuts call would consume it.)
        address newFacet = address(new EventFacet());
        IDiamondCut.FacetCut[] memory cuts = cutScript.buildCuts(newFacet);
        vm.prank(timelock);
        IDiamondCut(diamond).diamondCut(cuts, address(0), "");

        // === NO-BRICK: every pre-existing money fact unchanged ===
        assertEq(IMarketFacet(diamond).marketCount(), mcBefore, "marketCount changed");
        assertEq(IEventFacet(diamond).eventCount(), ecBefore, "eventCount changed");
        assertEq(IMarketFacet(diamond).totalCollateralLocked(), lockedBefore, "totalCollateralLocked changed");
        assertEq(IERC20(USDC).balanceOf(diamond), usdcBefore, "diamond USDC balance changed");

        IMarketFacet.MarketView memory mAfter = IMarketFacet(diamond).getMarket(mcBefore);
        assertEq(mAfter.yesToken, mBefore.yesToken, "existing market yesToken changed");
        assertEq(mAfter.totalCollateral, mBefore.totalCollateral, "existing market collateral changed");
        assertEq(mAfter.eventId, mBefore.eventId, "existing market eventId changed");

        // Pre-existing event reads through the NEW facet: appended `linked` view field must read
        // false for legacy events (append-only storage — same property Gap1UpgradeStorageBrick pins).
        IEventFacet.EventView memory eAfter = IEventFacet(diamond).getEvent(1);
        assertFalse(eAfter.linked, "pre-existing event must read non-linked");
        assertGt(eAfter.marketIds.length, 0, "pre-existing event children unreadable");

        // === routing: new ops live, legacy selectors gone ===
        IDiamondLoupe loupe = IDiamondLoupe(diamond);
        assertEq(loupe.facetAddress(IEventFacet.splitEvent.selector), newFacet, "splitEvent not routed");
        assertEq(loupe.facetAddress(IEventFacet.createEvent.selector), newFacet, "createEvent not replaced");
        assertEq(loupe.facetAddress(IEventFacet.eventPoolOf.selector), newFacet, "eventPoolOf not replaced");
        bytes4[] memory removed = cutScript.removeSelectors();
        for (uint256 i; i < removed.length; ++i) {
            assertEq(loupe.facetAddress(removed[i]), address(0), "legacy selector still routed");
        }
        assertEq(loupe.facetFunctionSelectors(newFacet).length, 13, "consolidated facet selector count");

        // === E2E post-cut: live ManualOracle still resolves a freshly created shared-pool event ===
        _postCutFlow(diamond);
    }

    function test_Fork_ConsolidationCut_Rollback_RestoresLiveFacets() public {
        (address diamond, address timelock) = _forkOrSkip();
        IDiamondLoupe loupe = IDiamondLoupe(diamond);

        // --- snapshot money facts + ORIGINAL routing (the rollback targets) ---
        uint256 lockedBefore = IMarketFacet(diamond).totalCollateralLocked();
        uint256 usdcBefore = IERC20(USDC).balanceOf(diamond);
        address liveEventFacet = loupe.facetAddress(IEventFacet.createEvent.selector);
        address liveLinkedFacet = loupe.facetAddress(bytes4(0xa4128ef7)); // createLinkedEvent
        assertTrue(liveEventFacet != address(0) && liveLinkedFacet != address(0), "live facets not found");

        // --- FORWARD cut (cuts computed BEFORE the prank — buildCuts would consume it) ---
        address newFacet = address(new EventFacet());
        IDiamondCut.FacetCut[] memory fwd = cutScript.buildCuts(newFacet);
        vm.prank(timelock);
        IDiamondCut(diamond).diamondCut(fwd, address(0), "");
        assertEq(loupe.facetAddress(IEventFacet.splitEvent.selector), newFacet, "fwd: splitEvent not routed");

        // --- ROLLBACK cut: Replace lifecycle back to the live EventFacet, eventPoolOf back to the
        //     live LinkedEventFacet, Remove the 3 new ops, re-Add the legacy selectors. ---
        IDiamondCut.FacetCut[] memory back = new IDiamondCut.FacetCut[](4);
        bytes4[] memory lifecycle = new bytes4[](9);
        {
            bytes4[] memory rep = cutScript.replaceSelectors();
            for (uint256 i; i < 9; ++i) {
                lifecycle[i] = rep[i]; // first 9 = lifecycle/views; index 9 is eventPoolOf
            }
        }
        bytes4[] memory poolOf = new bytes4[](1);
        poolOf[0] = IEventFacet.eventPoolOf.selector;
        bytes4[] memory legacyAdd = new bytes4[](5);
        {
            bytes4[] memory rem = cutScript.removeSelectors();
            // re-Add the 5 LinkedEventFacet selectors to the live linked facet; addEventOutcome
            // (rem[5]) goes back to the live EventFacet below.
            for (uint256 i; i < 5; ++i) {
                legacyAdd[i] = rem[i];
            }
        }
        bytes4[] memory addOutcome = new bytes4[](1);
        addOutcome[0] = bytes4(0x1a0dcf36);

        back[0] = IDiamondCut.FacetCut(liveEventFacet, IDiamondCut.FacetCutAction.Replace, lifecycle);
        back[1] = IDiamondCut.FacetCut(liveLinkedFacet, IDiamondCut.FacetCutAction.Replace, poolOf);
        back[2] = IDiamondCut.FacetCut(address(0), IDiamondCut.FacetCutAction.Remove, cutScript.addSelectors());
        back[3] = IDiamondCut.FacetCut(liveLinkedFacet, IDiamondCut.FacetCutAction.Add, legacyAdd);

        vm.prank(timelock);
        IDiamondCut(diamond).diamondCut(back, address(0), "");
        IDiamondCut.FacetCut[] memory backOutcome = new IDiamondCut.FacetCut[](1);
        backOutcome[0] = IDiamondCut.FacetCut(liveEventFacet, IDiamondCut.FacetCutAction.Add, addOutcome);
        vm.prank(timelock);
        IDiamondCut(diamond).diamondCut(backOutcome, address(0), "");

        // === RESTORED: routing identical to pre-upgrade, money facts untouched ===
        assertEq(loupe.facetAddress(IEventFacet.createEvent.selector), liveEventFacet, "rollback: createEvent");
        assertEq(loupe.facetAddress(bytes4(0xa4128ef7)), liveLinkedFacet, "rollback: createLinkedEvent");
        assertEq(loupe.facetAddress(bytes4(0x1a0dcf36)), liveEventFacet, "rollback: addEventOutcome");
        assertEq(loupe.facetAddress(IEventFacet.eventPoolOf.selector), liveLinkedFacet, "rollback: eventPoolOf");
        assertEq(loupe.facetAddress(IEventFacet.splitEvent.selector), address(0), "rollback: splitEvent not removed");
        assertEq(IMarketFacet(diamond).totalCollateralLocked(), lockedBefore, "rollback: locked changed");
        assertEq(IERC20(USDC).balanceOf(diamond), usdcBefore, "rollback: usdc balance changed");
    }

    /// @dev Post-cut E2E: create → splitEvent → child split (pool-routed) → live-oracle resolve →
    ///      redeemEvent drains the pool to exactly 0. Proves the live ManualOracle keeps working
    ///      against the consolidated facet (`getEventStatus` signature unchanged by design).
    function _postCutFlow(address diamond) private {
        address aliceFork = makeAddr("cutsim.alice");
        vm.prank(USDC_OWNER);
        ITestUSDCSim(USDC).mint(aliceFork, 200e6);
        vm.prank(aliceFork);
        IERC20(USDC).approve(diamond, type(uint256).max);

        uint256 endTime = block.timestamp + 1 days;
        string[] memory qs = new string[](2);
        qs[0] = "cut-sim A";
        qs[1] = "cut-sim B";
        vm.prank(CREATOR_OPS);
        (uint256 eventId, uint256[] memory ids) =
            IEventFacet(diamond).createEvent("cut-sim", qs, endTime, MANUAL_ORACLE);
        assertTrue(IEventFacet(diamond).getEvent(eventId).linked, "post-cut event must be shared-pool");

        vm.prank(aliceFork);
        IEventFacet(diamond).splitEvent(eventId, 100e6);
        vm.prank(aliceFork);
        IMarketFacet(diamond).splitPosition(ids[0], 50e6);
        assertEq(IEventFacet(diamond).eventPoolOf(eventId), 150e6, "pool credited");
        assertEq(IMarketFacet(diamond).getMarket(ids[0]).totalCollateral, 0, "child must hold no collateral");

        vm.warp(endTime + 1);
        vm.prank(REPORTER_OPS);
        IManualOracleSim(MANUAL_ORACLE).reportEvent(eventId, 0);
        vm.warp(block.timestamp + IManualOracleSim(MANUAL_ORACLE).challengeDelay() + 1);
        IEventFacet(diamond).resolveEvent(eventId);

        vm.prank(aliceFork);
        uint256 payout = IEventFacet(diamond).redeemEvent(eventId);
        assertEq(payout, 150e6, "winner-YES claims the full pool");
        assertEq(IEventFacet(diamond).eventPoolOf(eventId), 0, "post-cut pool drains to exactly 0");
    }
}
