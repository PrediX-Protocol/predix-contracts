// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import {MarketFixture} from "../utils/MarketFixture.sol";
import {IMarketFacet} from "@predix/shared/interfaces/IMarketFacet.sol";

/// @notice Storage-append regression lock for Gap#1. Appending `MarketData.linkedChild`,
///         `EventData.linked` / `redemptionFeeBps`, and `Layout.eventPool` must not shift any existing
///         slot — a legacy standalone market must keep its full pre-Gap#1 lifecycle behaviour. Slot
///         integrity for the whole diamond is additionally proven by the existing 815+ suite staying green.
contract Gap1StorageAppendOnly is MarketFixture {
    function test_LegacyMarket_UnaffectedByStorageAppend() public {
        uint256 id = _createMarket(block.timestamp + 7 days);

        IMarketFacet.MarketView memory m0 = market.getMarket(id);
        assertEq(m0.totalCollateral, 0, "fresh market collateral != 0");
        assertEq(m0.eventId, 0, "standalone market eventId != 0");
        assertFalse(m0.isResolved, "fresh market resolved");
        assertFalse(m0.refundModeActive, "fresh market refundModeActive");

        // `linkedChild` defaults to false (not in MarketView) → a legacy market must still split into
        // its OWN per-market collateral (not an event pool) and bump the global lock in lockstep.
        _split(alice, id, 1e6);

        IMarketFacet.MarketView memory m1 = market.getMarket(id);
        assertEq(m1.totalCollateral, 1e6, "legacy split must route to per-market collateral");
        assertEq(market.totalCollateralLocked(), 1e6, "global totalCollateralLocked not updated");
        assertEq(_yes(id).totalSupply(), 1e6, "YES supply");
        assertEq(_no(id).totalSupply(), 1e6, "NO supply");
    }
}
