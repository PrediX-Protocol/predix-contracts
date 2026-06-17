// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IDiamondCut} from "@predix/shared/interfaces/IDiamondCut.sol";
import {IDiamondLoupe} from "@predix/shared/interfaces/IDiamondLoupe.sol";
import {IMarketFacet} from "@predix/shared/interfaces/IMarketFacet.sol";
import {ProtocolFeeMarketCut} from "../../script/ProtocolFeeMarketCut.s.sol";

/// @notice Sub-plan 05 Task 3 — upgrade-safety regression for the Sub-plan 02 protocol-fee MarketFacet cut.
///         Execute the REAL Replace+Add cut AS the Timelock on a chain-130 fork and assert no brick + the
///         widened MarketView reads + effectiveProtocolFee clamps. Live role holders pranked; nothing broadcast.
/// @dev Requires env UNICHAIN_RPC_PRIMARY + DIAMOND_ADDRESS + TIMELOCK_ADDRESS. Skips if the cut is already
///      live on the forked diamond. Uses named-field MarketView access (ABI-arity-safe, no positional decode).
contract ProtocolFeeMarketCutForkSim is Test {
    address internal constant USDC = 0xB3FCA863dD0F6b496cCDDf6497Da5Dad67857F56;
    ProtocolFeeMarketCut internal cut;

    function _fork() internal returns (address diamond) {
        vm.createSelectFork(vm.envString("UNICHAIN_RPC_PRIMARY"));
        cut = new ProtocolFeeMarketCut();
        diamond = vm.envAddress("DIAMOND_ADDRESS");
        if (IDiamondLoupe(diamond).facetAddress(IMarketFacet.setDefaultProtocolFeeRateBps.selector) != address(0)) {
            vm.skip(true, "protocol-fee cut already live on the forked diamond");
        }
    }

    function _applyCut(address diamond) internal {
        address timelock = vm.envAddress("TIMELOCK_ADDRESS");
        address newMarketFacet = cut.deployMarketFacet();
        IDiamondCut.FacetCut[] memory cuts = cut.buildCuts(diamond, newMarketFacet); // before the prank
        vm.prank(timelock);
        IDiamondCut(diamond).diamondCut(cuts, address(0), "");

        IDiamondLoupe loupe = IDiamondLoupe(diamond);
        assertEq(
            loupe.facetAddress(IMarketFacet.setDefaultProtocolFeeRateBps.selector), newMarketFacet, "setter not added"
        );
        assertEq(loupe.facetAddress(IMarketFacet.effectiveProtocolFee.selector), newMarketFacet, "view not added");
        assertEq(loupe.facetAddress(IMarketFacet.getMarket.selector), newMarketFacet, "getMarket not replaced");
    }

    function test_Fork_ProtocolFeeCut_NoBrick_AndWidenedViewReads() public {
        address diamond = _fork();
        // Snapshot live money facts pre-cut using ARITY-STABLE single-value reads only. We CANNOT decode
        // getMarket() pre-cut: the live MarketFacet still returns the 15-field (pre-v1.7) MarketView, so the
        // widened 17-field decode reverts. This is exactly the diamond-cut-FIRST ordering constraint — any new
        // MarketView consumer (this test, the new Exchange/Router) must read getMarket only AFTER the cut.
        uint256 mcBefore = IMarketFacet(diamond).marketCount();
        uint256 lockedBefore = IMarketFacet(diamond).totalCollateralLocked();
        uint256 usdcBefore = IERC20(USDC).balanceOf(diamond);
        assertGt(mcBefore, 0, "no live markets");

        _applyCut(diamond);

        // NO-BRICK: counts / locked / balance unchanged across the cut.
        assertEq(IMarketFacet(diamond).marketCount(), mcBefore, "marketCount changed");
        assertEq(IMarketFacet(diamond).totalCollateralLocked(), lockedBefore, "locked changed");
        assertEq(IERC20(USDC).balanceOf(diamond), usdcBefore, "diamond USDC changed");

        // WIDENED MarketView now decodes cleanly on an EXISTING market (proves the cut fixed the arity AND the
        // market's storage survived): a real yesToken, and the two NEW fields read clean launch defaults (the
        // v1.7 MarketData slots were never written for a pre-cut market ⇒ 0).
        IMarketFacet.MarketView memory mAfter = IMarketFacet(diamond).getMarket(mcBefore);
        assertTrue(mAfter.yesToken != address(0), "existing market lost its yesToken across the cut");
        assertEq(mAfter.protocolFeeRateBps, 0, "new field protocolFeeRateBps not 0 at launch");
        assertEq(mAfter.protocolMakerRebateBps, 0, "new field protocolMakerRebateBps not 0 at launch");

        // effectiveProtocolFee returns clamped values (rate<=MAX 700, rebate<=MAX 2500) on a known market.
        (uint16 rate, uint16 rebate) = IMarketFacet(diamond).effectiveProtocolFee(mcBefore);
        assertLe(rate, 700, "effective rate not clamped to MAX 700");
        assertLe(rebate, 2500, "effective rebate not clamped to MAX 2500");
        assertEq(rate, 0, "launch rate must be 0");
        assertEq(rebate, 0, "launch rebate must be 0");
    }
}
