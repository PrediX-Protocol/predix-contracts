// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {IDiamondCut} from "@predix/shared/interfaces/IDiamondCut.sol";
import {IDiamondLoupe} from "@predix/shared/interfaces/IDiamondLoupe.sol";
import {IEventFacet} from "@predix/shared/interfaces/IEventFacet.sol";
import {IMarketFacet} from "@predix/shared/interfaces/IMarketFacet.sol";

import {RedemptionFeeCut} from "../../script/RedemptionFeeCut.s.sol";

interface ITestUSDCSim {
    function mint(address to, uint256 amount) external;
}

interface IManualOracleSim {
    function reportEvent(uint256 eventId, uint256 winningIndex) external;
    function challengeDelay() external view returns (uint256);
}

/// @notice Upgrade-safety regression for the keyti-fqn8 REDEMPTION-FEE cut. Against the LIVE chain-130
///         diamond (forked), execute the real cut AS the Timelock and assert (1) no brick — every
///         pre-existing market/event/locked-collateral fact survives and the in-flight shared-pool event
///         41 stays solvent + operable; (2) the two new selectors route; (3) the per-child redemption fee
///         actually charges end-to-end on a freshly created event resolved by the live ManualOracle, and
///         `createMarketWithFee` snapshots the explicit fee. Live role holders are pranked; nothing is
///         broadcast. The cut is built by `RedemptionFeeCut.buildCuts` (single source of truth with the
///         eventual mainnet broadcast). Skips once the cut is already live.
/// @dev Requires env UNICHAIN_RPC_PRIMARY / DIAMOND_ADDRESS / TIMELOCK_ADDRESS (fail-loud, fork-dir
///      convention). The retroactive-fee question on EXISTING linked events is owner-accepted (unit-tested);
///      event 41 is in-flight (real positions) so it is exercised by split/merge round-trip only, never
///      redeemed here.
contract RedemptionFeeCutForkSim is Test {
    address internal constant MANUAL_ORACLE = 0x8EDD86CC637FA1ca178ac16f85b6777F05AC0ca7;
    address internal constant USDC = 0xB3FCA863dD0F6b496cCDDf6497Da5Dad67857F56;
    address internal constant USDC_OWNER = 0x0c80F2e7372b669005C9dB68Ab7C704739cd9b82;
    address internal constant CREATOR_OPS = 0x8BD105eDD11C4132D2BD6a5DaC7dA5d7a02a48C9;
    address internal constant REPORTER_OPS = 0x67934f8010F9E493f44E48d0F2381C175CCd04b1;

    RedemptionFeeCut internal cut;

    /// @dev Fork chain-130 and deploy this tree's cut builder. Skips if the cut is already live
    ///      (createMarketWithFee routed). The cut itself is applied by `_applyCut` on the SAME fork.
    function _fork() internal returns (address diamond) {
        vm.createSelectFork(vm.envString("UNICHAIN_RPC_PRIMARY"));
        cut = new RedemptionFeeCut(); // deployed AFTER the fork switch
        diamond = vm.envAddress("DIAMOND_ADDRESS");
        if (IDiamondLoupe(diamond).facetAddress(IMarketFacet.createMarketWithFee.selector) != address(0)) {
            vm.skip(true, "redemption-fee cut already live on the forked diamond - sim not applicable");
        }
    }

    /// @dev Deploy this tree's impls and apply the cut as the authorized Timelock (no fork — caller forks
    ///      first so pre-cut snapshots and the cut share one fork/block).
    function _applyCut(address diamond) internal {
        address timelock = vm.envAddress("TIMELOCK_ADDRESS");
        (address newMarketFacet, address newEventFacet) = cut.deployFacets();
        // cuts computed BEFORE the prank (the external buildCuts call would consume it).
        IDiamondCut.FacetCut[] memory cuts = cut.buildCuts(diamond, newMarketFacet, newEventFacet);
        vm.prank(timelock);
        IDiamondCut(diamond).diamondCut(cuts, address(0), "");

        IDiamondLoupe loupe = IDiamondLoupe(diamond);
        assertEq(
            loupe.facetAddress(IMarketFacet.createMarketWithFee.selector),
            newMarketFacet,
            "createMarketWithFee not routed"
        );
        assertEq(
            loupe.facetAddress(IEventFacet.createEventWithFee.selector), newEventFacet, "createEventWithFee not routed"
        );
        // representative replaced selectors now route to the new impls too.
        assertEq(loupe.facetAddress(IEventFacet.redeemEvent.selector), newEventFacet, "redeemEvent not replaced");
        assertEq(loupe.facetAddress(IMarketFacet.redeem.selector), newMarketFacet, "redeem not replaced");
    }

    function _forkAndCut() internal returns (address diamond) {
        diamond = _fork();
        _applyCut(diamond);
    }

    function test_Fork_RedemptionFeeCut_NoBrick_AndSolvent() public {
        address diamond = _fork();

        // --- snapshot the live state pre-cut (same fork) ---
        uint256 mcBefore = IMarketFacet(diamond).marketCount();
        uint256 ecBefore = IEventFacet(diamond).eventCount();
        uint256 lockedBefore = IMarketFacet(diamond).totalCollateralLocked();
        uint256 usdcBefore = IERC20(USDC).balanceOf(diamond);
        assertGt(mcBefore, 0, "no live markets to test against");
        assertGt(ecBefore, 0, "no live events to test against");
        IMarketFacet.MarketView memory mBefore = IMarketFacet(diamond).getMarket(mcBefore);

        // --- apply the cut on the SAME fork as the Timelock ---
        _applyCut(diamond);

        // === NO-BRICK: every pre-existing money fact unchanged ===
        assertEq(IMarketFacet(diamond).marketCount(), mcBefore, "marketCount changed");
        assertEq(IEventFacet(diamond).eventCount(), ecBefore, "eventCount changed");
        assertEq(IMarketFacet(diamond).totalCollateralLocked(), lockedBefore, "totalCollateralLocked changed");
        assertEq(IERC20(USDC).balanceOf(diamond), usdcBefore, "diamond USDC balance changed");

        IMarketFacet.MarketView memory mAfter = IMarketFacet(diamond).getMarket(mcBefore);
        assertEq(mAfter.yesToken, mBefore.yesToken, "existing market yesToken changed");
        assertEq(mAfter.totalCollateral, mBefore.totalCollateral, "existing market collateral changed");
        assertEq(mAfter.eventId, mBefore.eventId, "existing market eventId changed");

        // === the in-flight shared-pool event 41 survives + stays solvent through the new facet ===
        _assertInFlightLinkedEventSurvives(diamond);
    }

    function test_Fork_RedemptionFeeCut_PerChildFee_E2E() public {
        address diamond = _forkAndCut();

        // --- createMarketWithFee snapshots the explicit fee (Add selector + snapshot proof) ---
        vm.prank(CREATOR_OPS);
        uint256 mid = IMarketFacet(diamond).createMarketWithFee(
            "cut-sim binary", block.timestamp + 1 days, MANUAL_ORACLE, 750
        );
        assertEq(IMarketFacet(diamond).effectiveRedemptionFeeBps(mid), 750, "createMarketWithFee snapshot");

        // --- per-child fee charges end-to-end on a fresh event resolved by the live oracle ---
        address feeRecipient = IMarketFacet(diamond).feeRecipient();
        address alice = makeAddr("rfee.alice");
        vm.prank(USDC_OWNER);
        ITestUSDCSim(USDC).mint(alice, 200e6);
        vm.prank(alice);
        IERC20(USDC).approve(diamond, type(uint256).max);

        uint256 endTime = block.timestamp + 1 days;
        string[] memory qs = new string[](2);
        qs[0] = "rfee A";
        qs[1] = "rfee B";
        vm.prank(CREATOR_OPS);
        (uint256 eventId,) = IEventFacet(diamond).createEventWithFee("rfee", qs, endTime, MANUAL_ORACLE, 500); // 5%

        vm.prank(alice);
        IEventFacet(diamond).splitEvent(eventId, 100e6);
        assertEq(IEventFacet(diamond).eventPoolOf(eventId), 100e6, "pool credited");

        vm.warp(endTime + 1);
        vm.prank(REPORTER_OPS);
        IManualOracleSim(MANUAL_ORACLE).reportEvent(eventId, 0);
        vm.warp(block.timestamp + IManualOracleSim(MANUAL_ORACLE).challengeDelay() + 1);
        IEventFacet(diamond).resolveEvent(eventId);

        uint256 feeBefore = IERC20(USDC).balanceOf(feeRecipient);
        vm.prank(alice);
        uint256 payout = IEventFacet(diamond).redeemEvent(eventId);

        // winner-YES claim = 100e6 gross, child fee = 5% = 5e6, payout = 95e6 (per-child fee LIVE post-cut).
        assertEq(payout, 95e6, "per-child 5% fee charged on the linked redeem");
        assertEq(IERC20(USDC).balanceOf(feeRecipient) - feeBefore, 5e6, "5% fee forwarded to recipient");
        assertEq(IEventFacet(diamond).eventPoolOf(eventId), 0, "pool drains to exactly 0");
    }

    /// @dev Live chain-130 carries event 41: a shared-pool event holding ~144,289 USDC across its
    ///      children (M uniform, pool == ΣNO_i + M exact). The cut must not perturb its storage and the
    ///      new EventFacet must read+write that pre-existing pool correctly — proven by an additive
    ///      split/merge ROUND-TRIP (deposit returns in full, the 144,289 is untouched, solvency holds).
    function _assertInFlightLinkedEventSurvives(address diamond) private {
        uint256 EID = 41;
        IEventFacet ev = IEventFacet(diamond);
        IEventFacet.EventView memory e = ev.getEvent(EID);
        if (!e.linked || ev.eventPoolOf(EID) == 0 || e.isResolved || e.endTime <= block.timestamp) {
            // Event 41 drained/resolved/ended on a newer fork block — skip rather than assert stale shape.
            return;
        }

        uint256 poolBefore = ev.eventPoolOf(EID);
        uint256 lockedBefore = IMarketFacet(diamond).totalCollateralLocked();
        _assertEventSolvent(diamond, EID);

        address u = makeAddr("rfee.inflight");
        uint256 amt = 1_000e6;
        vm.prank(USDC_OWNER);
        ITestUSDCSim(USDC).mint(u, amt);
        vm.prank(u);
        IERC20(USDC).approve(diamond, type(uint256).max);

        vm.prank(u);
        ev.splitEvent(EID, amt);
        assertEq(ev.eventPoolOf(EID), poolBefore + amt, "splitEvent on in-flight event must grow the live pool");
        _assertEventSolvent(diamond, EID);

        vm.prank(u);
        ev.mergeEvent(EID, amt);
        assertEq(ev.eventPoolOf(EID), poolBefore, "mergeEvent must restore the pool to its exact pre-op value");
        assertEq(IERC20(USDC).balanceOf(u), amt, "round-trip must return the depositor's full amount");
        assertEq(IMarketFacet(diamond).totalCollateralLocked(), lockedBefore, "global lock unchanged after round-trip");
        _assertEventSolvent(diamond, EID);
    }

    /// @dev pool == Σ NO_i + M with M = (YES_i - NO_i) uniform across outcomes.
    function _assertEventSolvent(address diamond, uint256 eventId) private view {
        IEventFacet.EventView memory e = IEventFacet(diamond).getEvent(eventId);
        uint256 sumNo;
        int256 m0;
        for (uint256 i; i < e.marketIds.length; ++i) {
            IMarketFacet.MarketView memory m = IMarketFacet(diamond).getMarket(e.marketIds[i]);
            int256 margin = int256(IERC20(m.yesToken).totalSupply()) - int256(IERC20(m.noToken).totalSupply());
            if (i == 0) m0 = margin;
            else assertEq(margin, m0, "M not uniform on in-flight event");
            sumNo += IERC20(m.noToken).totalSupply();
        }
        assertEq(int256(IEventFacet(diamond).eventPoolOf(eventId)), int256(sumNo) + m0, "in-flight pool != sumNO + M");
    }
}
