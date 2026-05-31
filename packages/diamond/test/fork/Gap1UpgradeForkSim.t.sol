// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import {Test} from "forge-std/Test.sol";

import {IDiamondCut} from "@predix/shared/interfaces/IDiamondCut.sol";
import {IDiamondLoupe} from "@predix/shared/interfaces/IDiamondLoupe.sol";
import {IMarketFacet} from "@predix/shared/interfaces/IMarketFacet.sol";
import {IEventFacet} from "@predix/shared/interfaces/IEventFacet.sol";
import {ILinkedEventFacet} from "@predix/shared/interfaces/ILinkedEventFacet.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {MarketFacet} from "@predix/diamond/facets/market/MarketFacet.sol";
import {EventFacet} from "@predix/diamond/facets/event/EventFacet.sol";
import {LinkedEventFacet} from "@predix/diamond/facets/event/LinkedEventFacet.sol";

/// @notice Upgrade-safety regression: against the LIVE Unichain-mainnet diamond (forked), execute the
///         REAL Gap#1 diamond cut AS the Timelock and assert (1) existing markets / events / locked
///         collateral survive untouched (no brick) and the new engine is live, and (2) the cut is
///         REVERSIBLE — a rollback cut restores the exact pre-upgrade selector routing with funds intact.
///         The empirical complement to the static selector-set proof + the `AddLinkedEventFacet` dry-run.
/// @dev Requires env UNICHAIN_RPC_PRIMARY / DIAMOND_ADDRESS / TIMELOCK_ADDRESS / USDC_ADDRESS. Forks
///      latest; excluded from the default non-fork suite (lives under test/fork/).
contract Gap1UpgradeForkSim is Test {
    function test_Fork_Gap1Cut_NoBrick_LiveDiamond() public {
        vm.createSelectFork(vm.envString("UNICHAIN_RPC_PRIMARY"));
        address diamond = vm.envAddress("DIAMOND_ADDRESS");
        address timelock = vm.envAddress("TIMELOCK_ADDRESS");
        IERC20 usdc = IERC20(vm.envAddress("USDC_ADDRESS"));

        // --- snapshot the live state pre-upgrade ---
        uint256 mcBefore = IMarketFacet(diamond).marketCount();
        uint256 ecBefore = IEventFacet(diamond).eventCount();
        uint256 lockedBefore = IMarketFacet(diamond).totalCollateralLocked();
        uint256 usdcBefore = usdc.balanceOf(diamond);
        assertGt(mcBefore, 0, "no live markets to test against");
        assertGt(ecBefore, 0, "no live events to test against");

        IMarketFacet.MarketView memory mBefore = IMarketFacet(diamond).getMarket(mcBefore); // latest market
        IEventFacet.EventView memory eBefore = IEventFacet(diamond).getEvent(ecBefore); // latest event

        // --- derive the CURRENTLY-live MarketFacet/EventFacet dynamically (robust to fork block) ---
        address liveMarket = IDiamondLoupe(diamond).facetAddress(IMarketFacet.splitPosition.selector);
        address liveEvent = IDiamondLoupe(diamond).facetAddress(IEventFacet.createEvent.selector);
        bytes4[] memory mktSel = IDiamondLoupe(diamond).facetFunctionSelectors(liveMarket);
        bytes4[] memory evtSel = IDiamondLoupe(diamond).facetFunctionSelectors(liveEvent);

        // --- deploy the new (guarded, linked-aware) impls + build the exact 3-cut ---
        address newMarket = address(new MarketFacet());
        address newEvent = address(new EventFacet());
        address newLinked = address(new LinkedEventFacet());

        IDiamondCut.FacetCut[] memory cuts = new IDiamondCut.FacetCut[](3);
        cuts[0] = IDiamondCut.FacetCut(newMarket, IDiamondCut.FacetCutAction.Replace, mktSel);
        cuts[1] = IDiamondCut.FacetCut(newEvent, IDiamondCut.FacetCutAction.Replace, evtSel);
        cuts[2] = IDiamondCut.FacetCut(newLinked, IDiamondCut.FacetCutAction.Add, _linkedSelectors());

        // --- EXECUTE the cut as the authorized Timelock (CUT_EXECUTOR) ---
        vm.prank(timelock);
        IDiamondCut(diamond).diamondCut(cuts, address(0), "");

        // === NO-BRICK: every pre-existing money fact unchanged ===
        assertEq(IMarketFacet(diamond).marketCount(), mcBefore, "marketCount changed");
        assertEq(IEventFacet(diamond).eventCount(), ecBefore, "eventCount changed");
        assertEq(IMarketFacet(diamond).totalCollateralLocked(), lockedBefore, "totalCollateralLocked changed");
        assertEq(usdc.balanceOf(diamond), usdcBefore, "diamond USDC balance changed");

        IMarketFacet.MarketView memory mAfter = IMarketFacet(diamond).getMarket(mcBefore);
        assertEq(mAfter.yesToken, mBefore.yesToken, "existing market yesToken changed");
        assertEq(mAfter.noToken, mBefore.noToken, "existing market noToken changed");
        assertEq(mAfter.totalCollateral, mBefore.totalCollateral, "existing market collateral changed");
        assertEq(mAfter.endTime, mBefore.endTime, "existing market endTime changed");
        assertEq(mAfter.eventId, mBefore.eventId, "existing market eventId changed");

        IEventFacet.EventView memory eAfter = IEventFacet(diamond).getEvent(ecBefore);
        assertEq(eAfter.marketIds.length, eBefore.marketIds.length, "existing event children changed");

        // === NEW engine routed + pre-existing data reads as non-linked (append-only safe) ===
        assertEq(
            IDiamondLoupe(diamond).facetAddress(ILinkedEventFacet.createLinkedEvent.selector),
            newLinked,
            "linked facet not routed after Add"
        );
        assertEq(
            IDiamondLoupe(diamond).facetAddress(IMarketFacet.setPerMarketCap.selector),
            newMarket,
            "setPerMarketCap not on the new (F1-guarded) impl after Replace"
        );
        assertFalse(ILinkedEventFacet(diamond).isLinkedEvent(ecBefore), "pre-existing event must read non-linked");
        assertEq(ILinkedEventFacet(diamond).eventPoolOf(ecBefore), 0, "pre-existing event pool must read 0");
    }

    /// @notice ROLLBACK rehearsal (runbook §3e): after the forward Gap#1 cut, execute the REVERSE cut
    ///         AS the Timelock — Replace the new Market/Event impls back to the LIVE originals + Remove
    ///         the 6 linked selectors — and assert the diamond is restored to its exact pre-upgrade
    ///         selector routing with every money fact still intact. Proves the abort/restore path works
    ///         against live state, so a post-upgrade problem can be unwound without touching funds.
    function test_Fork_Gap1Cut_Rollback_RestoresLiveFacets() public {
        vm.createSelectFork(vm.envString("UNICHAIN_RPC_PRIMARY"));
        address diamond = vm.envAddress("DIAMOND_ADDRESS");
        address timelock = vm.envAddress("TIMELOCK_ADDRESS");
        IERC20 usdc = IERC20(vm.envAddress("USDC_ADDRESS"));

        // --- snapshot live money facts + the ORIGINAL facet routing (the rollback targets) ---
        uint256 lockedBefore = IMarketFacet(diamond).totalCollateralLocked();
        uint256 usdcBefore = usdc.balanceOf(diamond);
        uint256 mcBefore = IMarketFacet(diamond).marketCount();
        uint256 ecBefore = IEventFacet(diamond).eventCount();

        address liveMarket = IDiamondLoupe(diamond).facetAddress(IMarketFacet.splitPosition.selector);
        address liveEvent = IDiamondLoupe(diamond).facetAddress(IEventFacet.createEvent.selector);
        bytes4[] memory mktSel = IDiamondLoupe(diamond).facetFunctionSelectors(liveMarket);
        bytes4[] memory evtSel = IDiamondLoupe(diamond).facetFunctionSelectors(liveEvent);
        assertTrue(liveMarket != address(0) && liveEvent != address(0), "live facets not found");

        // --- FORWARD cut (Replace -> new, Add linked) ---
        address newMarket = address(new MarketFacet());
        address newEvent = address(new EventFacet());
        address newLinked = address(new LinkedEventFacet());
        IDiamondCut.FacetCut[] memory fwd = new IDiamondCut.FacetCut[](3);
        fwd[0] = IDiamondCut.FacetCut(newMarket, IDiamondCut.FacetCutAction.Replace, mktSel);
        fwd[1] = IDiamondCut.FacetCut(newEvent, IDiamondCut.FacetCutAction.Replace, evtSel);
        fwd[2] = IDiamondCut.FacetCut(newLinked, IDiamondCut.FacetCutAction.Add, _linkedSelectors());
        vm.prank(timelock);
        IDiamondCut(diamond).diamondCut(fwd, address(0), "");

        // sanity: forward cut landed
        assertEq(
            IDiamondLoupe(diamond).facetAddress(ILinkedEventFacet.createLinkedEvent.selector),
            newLinked,
            "fwd: linked not routed"
        );
        assertEq(
            IDiamondLoupe(diamond).facetAddress(IMarketFacet.splitPosition.selector),
            newMarket,
            "fwd: market not replaced"
        );

        // --- ROLLBACK cut: Replace back to live impls + Remove the linked selectors (facetAddress(0)) ---
        IDiamondCut.FacetCut[] memory back = new IDiamondCut.FacetCut[](3);
        back[0] = IDiamondCut.FacetCut(liveMarket, IDiamondCut.FacetCutAction.Replace, mktSel);
        back[1] = IDiamondCut.FacetCut(liveEvent, IDiamondCut.FacetCutAction.Replace, evtSel);
        back[2] = IDiamondCut.FacetCut(address(0), IDiamondCut.FacetCutAction.Remove, _linkedSelectors());
        vm.prank(timelock);
        IDiamondCut(diamond).diamondCut(back, address(0), "");

        // === RESTORED: routing back to the originals, linked selectors gone ===
        assertEq(
            IDiamondLoupe(diamond).facetAddress(IMarketFacet.splitPosition.selector),
            liveMarket,
            "rollback: market not restored"
        );
        assertEq(
            IDiamondLoupe(diamond).facetAddress(IEventFacet.createEvent.selector),
            liveEvent,
            "rollback: event not restored"
        );
        assertEq(
            IDiamondLoupe(diamond).facetAddress(ILinkedEventFacet.createLinkedEvent.selector),
            address(0),
            "rollback: linked selector not removed"
        );

        // === money facts untouched across forward + rollback ===
        assertEq(IMarketFacet(diamond).totalCollateralLocked(), lockedBefore, "locked changed");
        assertEq(usdc.balanceOf(diamond), usdcBefore, "usdc balance changed");
        assertEq(IMarketFacet(diamond).marketCount(), mcBefore, "marketCount changed");
        assertEq(IEventFacet(diamond).eventCount(), ecBefore, "eventCount changed");
    }

    function _linkedSelectors() internal pure returns (bytes4[] memory s) {
        s = new bytes4[](6);
        s[0] = ILinkedEventFacet.createLinkedEvent.selector;
        s[1] = ILinkedEventFacet.mintCompleteSet.selector;
        s[2] = ILinkedEventFacet.redeemCompleteSet.selector;
        s[3] = ILinkedEventFacet.redeemLinked.selector;
        s[4] = ILinkedEventFacet.eventPoolOf.selector;
        s[5] = ILinkedEventFacet.isLinkedEvent.selector;
    }
}
