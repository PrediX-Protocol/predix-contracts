// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {IMarketFacet} from "@predix/shared/interfaces/IMarketFacet.sol";
import {IOutcomeToken} from "@predix/shared/interfaces/IOutcomeToken.sol";

import {MarketFixture} from "../utils/MarketFixture.sol";
import {MarketHandler} from "./MarketHandler.sol";

/// @notice Pre-resolution invariants for a single market exercised by `MarketHandler`.
///         Two invariants are critical to the diamond's solvency:
///           1. YES.totalSupply == NO.totalSupply == market.totalCollateral
///           2. market.totalCollateral <= USDC.balanceOf(diamond) (no over-accounting)
contract MarketInvariantTest is MarketFixture {
    MarketHandler internal handler;
    uint256 internal marketId;

    function setUp() public override {
        super.setUp();
        marketId = _createMarket(block.timestamp + 365 days);
        handler = new MarketHandler(address(diamond), address(usdc), marketId);

        bytes4[] memory selectors = new bytes4[](2);
        selectors[0] = MarketHandler.split.selector;
        selectors[1] = MarketHandler.merge.selector;
        targetSelector(FuzzSelector({addr: address(handler), selectors: selectors}));
        targetContract(address(handler));
    }

    function invariant_supplyEqualsCollateral() public view {
        IMarketFacet.MarketView memory m = market.getMarket(marketId);
        IOutcomeToken yes = IOutcomeToken(m.yesToken);
        IOutcomeToken no = IOutcomeToken(m.noToken);
        assertEq(yes.totalSupply(), m.totalCollateral, "yes != collateral");
        assertEq(no.totalSupply(), m.totalCollateral, "no != collateral");
    }

    function invariant_collateralBackedByUsdc() public view {
        IMarketFacet.MarketView memory m = market.getMarket(marketId);
        assertLe(m.totalCollateral, usdc.balanceOf(address(diamond)), "underbacked");
    }

    function invariant_ghostsConsistent() public view {
        IMarketFacet.MarketView memory m = market.getMarket(marketId);
        assertEq(handler.ghostSplitTotal() - handler.ghostMergeTotal(), m.totalCollateral, "ghost mismatch");
    }
}
