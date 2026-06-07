// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import {EventFixture} from "../utils/EventFixture.sol";
import {IMarketFacet} from "@predix/shared/interfaces/IMarketFacet.sol";
import {IOutcomeToken} from "@predix/shared/interfaces/IOutcomeToken.sol";

/// @notice Task 5: per-outcome split/merge for linked children (via the linked-aware MarketFacet) must
///         pool collateral at the event level and preserve `eventPool == Σ NO_i + M` with uniform M.
contract LinkedSplitMergeTest is EventFixture {
    uint256 internal eventId;
    uint256[] internal ids;
    uint256 internal endTime;

    function setUp() public override {
        super.setUp();
        endTime = block.timestamp + 30 days;
        (eventId, ids) = _createThreeCandidateEvent(endTime);
    }

    function test_LinkedSplit_PoolsCollateralPerOutcome() public {
        _fundAndApprove(alice, 100e6);
        vm.startPrank(alice);
        market.splitPosition(ids[0], 3e6);
        market.splitPosition(ids[1], 5e6);
        vm.stopPrank();

        assertEq(eventFacet.eventPoolOf(eventId), 8e6, "pool == sum of splits");
        assertEq(market.totalCollateralLocked(), 8e6, "lockstep");
        // every child keeps per-market collateral == 0; supply lives on the tokens
        for (uint256 i; i < ids.length; ++i) {
            assertEq(market.getMarket(ids[i]).totalCollateral, 0, "child collateral must be 0");
        }
        assertEq(_yes(ids[0]).totalSupply(), 3e6, "YES_0");
        assertEq(_no(ids[0]).totalSupply(), 3e6, "NO_0");
        assertEq(_yes(ids[1]).totalSupply(), 5e6, "YES_1");
    }

    function test_LinkedMerge_ReversesAndDebitsPool() public {
        _fundAndApprove(alice, 100e6);
        vm.startPrank(alice);
        market.splitPosition(ids[0], 5e6);
        market.mergePositions(ids[0], 2e6);
        vm.stopPrank();

        assertEq(eventFacet.eventPoolOf(eventId), 3e6, "pool -= merge");
        assertEq(market.totalCollateralLocked(), 3e6, "lockstep");
        assertEq(_yes(ids[0]).totalSupply(), 3e6, "YES_0 after merge");
        assertEq(_no(ids[0]).totalSupply(), 3e6, "NO_0 after merge");
    }

    /// @notice Fuzz: after a random split/merge/completeSet sequence over 3 outcomes, the pool equals
    ///         `Σ NO_i + M` with `M = YES_0 − NO_0` uniform across all outcomes.
    function testFuzz_LinkedSplitMerge_PreservesPoolEqualsSumNoPlusM(
        uint96 s0,
        uint96 s1,
        uint96 s2,
        uint96 cs,
        uint96 m0
    ) public {
        uint256 a0 = bound(s0, 1, 1_000_000e6);
        uint256 a1 = bound(s1, 1, 1_000_000e6);
        uint256 a2 = bound(s2, 1, 1_000_000e6);
        uint256 c = bound(cs, 1, 1_000_000e6);
        _fundAndApprove(alice, a0 + a1 + a2 + c + 1_000_000e6);

        vm.startPrank(alice);
        market.splitPosition(ids[0], a0);
        market.splitPosition(ids[1], a1);
        market.splitPosition(ids[2], a2);
        eventFacet.splitEvent(eventId, c);
        // merge back a bounded slice of outcome 0 (cannot exceed its YES==NO balance a0)
        uint256 mAmt = bound(m0, 0, a0);
        if (mAmt > 0) market.mergePositions(ids[0], mAmt);
        vm.stopPrank();

        // M must be uniform across outcomes
        int256 m = int256(_yes(ids[0]).totalSupply()) - int256(_no(ids[0]).totalSupply());
        for (uint256 i = 1; i < ids.length; ++i) {
            int256 mi = int256(_yes(ids[i]).totalSupply()) - int256(_no(ids[i]).totalSupply());
            assertEq(mi, m, "M not uniform across outcomes");
        }
        // pool == Σ NO_i + M
        uint256 sumNo;
        for (uint256 i; i < ids.length; ++i) {
            sumNo += _no(ids[i]).totalSupply();
        }
        assertEq(int256(eventFacet.eventPoolOf(eventId)), int256(sumNo) + m, "pool != sum(NO_i) + M");
        // and pool solvent for every winner k
        uint256 pool = eventFacet.eventPoolOf(eventId);
        for (uint256 k; k < ids.length; ++k) {
            uint256 claim;
            for (uint256 j; j < ids.length; ++j) {
                claim += (j == k) ? _yes(ids[j]).totalSupply() : _no(ids[j]).totalSupply();
            }
            assertEq(claim, pool, "payout(k) != pool for some k");
        }
    }

    function test_Revert_LinkedSplit_ZeroAmount() public {
        vm.prank(alice);
        vm.expectRevert(IMarketFacet.Market_ZeroAmount.selector);
        market.splitPosition(ids[0], 0);
    }

    function test_Revert_LinkedSplit_AfterEnd() public {
        _fundAndApprove(alice, 10e6);
        vm.warp(endTime + 1);
        vm.prank(alice);
        vm.expectRevert(IMarketFacet.Market_Ended.selector);
        market.splitPosition(ids[0], 1e6);
    }
}
