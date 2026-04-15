// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {CommonBase} from "forge-std/Base.sol";
import {StdCheats} from "forge-std/StdCheats.sol";
import {StdUtils} from "forge-std/StdUtils.sol";

import {IMarketFacet} from "@predix/shared/interfaces/IMarketFacet.sol";
import {IOutcomeToken} from "@predix/shared/interfaces/IOutcomeToken.sol";

import {MockUSDC} from "../mocks/MockUSDC.sol";

/// @notice Stateful handler that exercises split / merge from a small pool of users
///         while leaving the market in pre-resolution state. Used by the invariant suite
///         to stress the YES.supply == NO.supply == totalCollateral invariant.
contract MarketHandler is CommonBase, StdCheats, StdUtils {
    IMarketFacet internal immutable market;
    MockUSDC internal immutable usdc;
    address internal immutable diamondAddr;
    uint256 internal immutable marketId;

    address[5] internal users;

    uint256 public ghostSplitTotal;
    uint256 public ghostMergeTotal;

    constructor(address _diamond, address _usdc, uint256 _marketId) {
        market = IMarketFacet(_diamond);
        usdc = MockUSDC(_usdc);
        diamondAddr = _diamond;
        marketId = _marketId;

        for (uint256 i; i < users.length; ++i) {
            address u = address(uint160(uint256(keccak256(abi.encode("handler.user", i)))));
            users[i] = u;
            usdc.mint(u, 1_000_000_000e6);
            vm.prank(u);
            usdc.approve(_diamond, type(uint256).max);
        }
    }

    function split(uint8 userIdx, uint96 amount) external {
        address user = users[userIdx % users.length];
        uint256 amt = bound(amount, 1, 1_000_000e6);
        vm.prank(user);
        market.splitPosition(marketId, amt);
        ghostSplitTotal += amt;
    }

    function merge(uint8 userIdx, uint96 amount) external {
        address user = users[userIdx % users.length];
        IOutcomeToken yes = IOutcomeToken(market.getMarket(marketId).yesToken);
        IOutcomeToken no = IOutcomeToken(market.getMarket(marketId).noToken);
        uint256 maxBurn = yes.balanceOf(user);
        uint256 noBal = no.balanceOf(user);
        if (noBal < maxBurn) maxBurn = noBal;
        if (maxBurn == 0) return;
        uint256 amt = bound(amount, 1, maxBurn);
        vm.prank(user);
        market.mergePositions(marketId, amt);
        ghostMergeTotal += amt;
    }
}
