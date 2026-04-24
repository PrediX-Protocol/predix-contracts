// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {CommonBase} from "forge-std/Base.sol";
import {StdCheats} from "forge-std/StdCheats.sol";
import {StdUtils} from "forge-std/StdUtils.sol";

import {IEventFacet} from "@predix/shared/interfaces/IEventFacet.sol";
import {IMarketFacet} from "@predix/shared/interfaces/IMarketFacet.sol";
import {IOutcomeToken} from "@predix/shared/interfaces/IOutcomeToken.sol";

import {MockUSDC} from "../mocks/MockUSDC.sol";

/// @notice Stateful handler for EventFacet invariants. Randomly creates events,
///         splits / merges on their child markets, and occasionally resolves events,
///         exercising the mutual-exclusion and per-child binary invariants.
contract EventHandler is CommonBase, StdCheats, StdUtils {
    IMarketFacet internal immutable market;
    IEventFacet internal immutable eventFacet;
    MockUSDC internal immutable usdc;
    address internal immutable diamondAddr;
    address internal immutable admin;
    uint256 internal immutable eventEndTime;

    address[4] public users;

    uint256[] public eventIds;
    mapping(uint256 => uint256[]) public eventChildren;

    constructor(address _diamond, address _usdc, address _admin, uint256 _endTime) {
        market = IMarketFacet(_diamond);
        eventFacet = IEventFacet(_diamond);
        usdc = MockUSDC(_usdc);
        diamondAddr = _diamond;
        admin = _admin;
        eventEndTime = _endTime;

        for (uint256 i; i < users.length; ++i) {
            address u = address(uint160(uint256(keccak256(abi.encode("event.handler.user", i)))));
            users[i] = u;
            usdc.mint(u, 1_000_000_000e6);
            vm.prank(u);
            usdc.approve(_diamond, type(uint256).max);
        }
    }

    function createEvent(uint8 nRaw) external {
        if (eventIds.length >= 5) return;
        if (block.timestamp >= eventEndTime) return;
        uint256 n = bound(nRaw, 2, 5);
        string[] memory qs = new string[](n);
        for (uint256 i; i < n; ++i) {
            qs[i] = "q";
        }
        vm.prank(users[0]);
        (uint256 id, uint256[] memory mids) = eventFacet.createEvent("e", qs, eventEndTime);
        eventIds.push(id);
        for (uint256 i; i < mids.length; ++i) {
            eventChildren[id].push(mids[i]);
        }
    }

    function split(uint8 eIdxRaw, uint8 cIdxRaw, uint8 userIdx, uint96 amount) external {
        if (eventIds.length == 0) return;
        uint256 eId = eventIds[eIdxRaw % eventIds.length];
        uint256[] storage children = eventChildren[eId];
        uint256 marketId = children[cIdxRaw % children.length];
        IMarketFacet.MarketView memory m = market.getMarket(marketId);
        if (m.isResolved || m.refundModeActive || block.timestamp >= m.endTime) return;

        address user = users[userIdx % users.length];
        uint256 amt = bound(amount, 1, 100_000e6);
        vm.prank(user);
        market.splitPosition(marketId, amt);
    }

    function merge(uint8 eIdxRaw, uint8 cIdxRaw, uint8 userIdx, uint96 amount) external {
        if (eventIds.length == 0) return;
        uint256 eId = eventIds[eIdxRaw % eventIds.length];
        uint256[] storage children = eventChildren[eId];
        uint256 marketId = children[cIdxRaw % children.length];
        IMarketFacet.MarketView memory m = market.getMarket(marketId);
        if (m.isResolved || m.refundModeActive) return;

        address user = users[userIdx % users.length];
        uint256 yesBal = IOutcomeToken(m.yesToken).balanceOf(user);
        uint256 noBal = IOutcomeToken(m.noToken).balanceOf(user);
        uint256 maxBurn = yesBal < noBal ? yesBal : noBal;
        if (maxBurn == 0) return;
        uint256 amt = bound(amount, 1, maxBurn);
        vm.prank(user);
        market.mergePositions(marketId, amt);
    }

    function resolve(uint8 eIdxRaw, uint8 winIdxRaw) external {
        if (eventIds.length == 0) return;
        uint256 eId = eventIds[eIdxRaw % eventIds.length];
        IEventFacet.EventView memory e = eventFacet.getEvent(eId);
        if (e.isResolved || e.refundModeActive) return;

        if (block.timestamp < e.endTime) {
            vm.warp(e.endTime + 1);
        }
        uint256 winIdx = winIdxRaw % e.marketIds.length;
        vm.prank(admin);
        eventFacet.resolveEvent(eId, winIdx);
    }

    function eventCount() external view returns (uint256) {
        return eventIds.length;
    }

    function eventIdAt(uint256 i) external view returns (uint256) {
        return eventIds[i];
    }

    function childrenOf(uint256 eId) external view returns (uint256[] memory) {
        return eventChildren[eId];
    }
}
