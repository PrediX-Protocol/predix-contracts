// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import {IEventFacet} from "@predix/shared/interfaces/IEventFacet.sol";
import {IMarketFacet} from "@predix/shared/interfaces/IMarketFacet.sol";
import {IOutcomeToken} from "@predix/shared/interfaces/IOutcomeToken.sol";

import {LinkedEventFixture} from "../utils/LinkedEventFixture.sol";
import {LinkedEventHandler} from "./LinkedEventHandler.sol";

/// @notice Runtime solvency proof for the shared-collateral engine. Inherits ONLY LinkedEventFixture
///         (→ EventFixture), so it does NOT pick up the legacy `invariant_BinaryInvariantHoldsPerChild`,
///         which would false-fail on linked children (whose per-market totalCollateral is 0 by design).
contract LinkedEventInvariantTest is LinkedEventFixture {
    LinkedEventHandler internal handler;
    uint256 internal theEventId;
    uint256[] internal theChildIds;

    function setUp() public override {
        super.setUp();

        uint256 endTime = block.timestamp + 365 days;
        (theEventId, theChildIds) = _createLinkedN(4, endTime);

        handler = new LinkedEventHandler(
            address(diamond), address(usdc), address(eventOracle), theEventId, theChildIds, endTime
        );

        bytes4[] memory selectors = new bytes4[](6);
        selectors[0] = LinkedEventHandler.splitOutcome.selector;
        selectors[1] = LinkedEventHandler.mergeOutcome.selector;
        selectors[2] = LinkedEventHandler.mintCompleteSet.selector;
        selectors[3] = LinkedEventHandler.redeemCompleteSet.selector;
        selectors[4] = LinkedEventHandler.tryAddOutcome.selector;
        selectors[5] = LinkedEventHandler.resolveThenRedeemAll.selector;
        targetSelector(FuzzSelector({addr: address(handler), selectors: selectors}));
        targetContract(address(handler));
    }

    /// @dev `M = YES_0 − NO_0` must be identical for every outcome (the uniform-margin precondition the
    ///      F-A addEventOutcome guard protects).
    function invariant_MUniformAcrossOutcomes() public view {
        IEventFacet.EventView memory e = eventFacet.getEvent(theEventId);
        if (e.isResolved) return;
        int256 m0 = _margin(e.marketIds[0]);
        for (uint256 i = 1; i < e.marketIds.length; ++i) {
            assertEq(_margin(e.marketIds[i]), m0, "M not uniform across outcomes");
        }
    }

    /// @dev Pool accounting identity: `eventPool == Σ NO_i + M` for an unresolved linked event.
    function invariant_PoolEqualsSumNoPlusM() public view {
        IEventFacet.EventView memory e = eventFacet.getEvent(theEventId);
        if (e.isResolved) return;
        uint256 sumNo;
        for (uint256 i; i < e.marketIds.length; ++i) {
            sumNo += IOutcomeToken(market.getMarket(e.marketIds[i]).noToken).totalSupply();
        }
        int256 expected = int256(sumNo) + _margin(e.marketIds[0]);
        assertEq(int256(linked.eventPoolOf(theEventId)), expected, "eventPool != sum(NO_i) + M");
    }

    /// @dev THE solvency theorem as a runtime check: for an unresolved event and EVERY candidate winner k,
    ///      the total payout `y_k + Σ_{j≠k} n_j` equals the pool — so the pool is exactly solvent no
    ///      matter which outcome wins.
    function invariant_PoolSolventForEveryWinner() public view {
        IEventFacet.EventView memory e = eventFacet.getEvent(theEventId);
        if (e.isResolved) return;
        uint256 pool = linked.eventPoolOf(theEventId);
        uint256 n = e.marketIds.length;
        for (uint256 k; k < n; ++k) {
            uint256 claim;
            for (uint256 j; j < n; ++j) {
                IMarketFacet.MarketView memory m = market.getMarket(e.marketIds[j]);
                address tok = j == k ? m.yesToken : m.noToken;
                claim += IOutcomeToken(tok).totalSupply();
            }
            assertEq(claim, pool, "pool not exactly solvent for some winner");
        }
    }

    /// @dev The pool is always reflected inside the global lock, and the diamond holds at least the lock —
    ///      so `rescueSurplus` can never reach pooled backing.
    function invariant_PoolReflectedInTotalCollateralLocked() public view {
        uint256 pool = linked.eventPoolOf(theEventId);
        uint256 locked = market.totalCollateralLocked();
        assertLe(pool, locked, "eventPool exceeds totalCollateralLocked");
        assertGe(usdc.balanceOf(address(diamond)), locked, "diamond USDC below totalCollateralLocked");
    }

    /// @dev No funds stuck: once the event is resolved and every holder has redeemed, the pool is 0.
    function invariant_NoFundsStuck() public view {
        if (!handler.resolved()) return;
        // handler.resolveThenRedeemAll drains every user; any residual would be stranded collateral.
        assertEq(linked.eventPoolOf(theEventId), 0, "pool not fully drained after resolve+redeem");
    }

    function _margin(uint256 marketId) internal view returns (int256) {
        IMarketFacet.MarketView memory m = market.getMarket(marketId);
        return int256(IOutcomeToken(m.yesToken).totalSupply()) - int256(IOutcomeToken(m.noToken).totalSupply());
    }
}
