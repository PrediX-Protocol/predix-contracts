// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import {CommonBase} from "forge-std/Base.sol";
import {StdCheats} from "forge-std/StdCheats.sol";
import {StdUtils} from "forge-std/StdUtils.sol";

import {IEventFacet} from "@predix/shared/interfaces/IEventFacet.sol";
import {ILinkedEventFacet} from "@predix/shared/interfaces/ILinkedEventFacet.sol";
import {IMarketFacet} from "@predix/shared/interfaces/IMarketFacet.sol";
import {IOutcomeToken} from "@predix/shared/interfaces/IOutcomeToken.sol";

import {MockEventOracle} from "../mocks/MockEventOracle.sol";
import {MockUSDC} from "../mocks/MockUSDC.sol";

/// @notice Stateful handler for the shared-collateral engine. Exercises per-outcome split/merge (via the
///         linked-aware MarketFacet), complete-set mint/redeem, an attempt to append an outcome (which
///         must always revert on a linked event), and resolve-then-redeem — all bounded so the fuzzer
///         spends its runs on real flows. A single pre-seeded linked event keeps every invariant
///         non-trivial on every run.
contract LinkedEventHandler is CommonBase, StdCheats, StdUtils {
    IMarketFacet internal immutable market;
    IEventFacet internal immutable eventFacet;
    ILinkedEventFacet internal immutable linked;
    MockUSDC internal immutable usdc;
    MockEventOracle internal immutable eventOracle;
    address internal immutable diamondAddr;

    address[4] public users;

    uint256 public immutable eventId;
    uint256[] public childIds;
    uint256 internal immutable eventEndTime;

    bool public resolved;

    constructor(
        address _diamond,
        address _usdc,
        address _eventOracle,
        uint256 _eventId,
        uint256[] memory _childIds,
        uint256 _endTime
    ) {
        market = IMarketFacet(_diamond);
        eventFacet = IEventFacet(_diamond);
        linked = ILinkedEventFacet(_diamond);
        usdc = MockUSDC(_usdc);
        eventOracle = MockEventOracle(_eventOracle);
        diamondAddr = _diamond;
        eventId = _eventId;
        eventEndTime = _endTime;
        for (uint256 i; i < _childIds.length; ++i) {
            childIds.push(_childIds[i]);
        }

        for (uint256 i; i < users.length; ++i) {
            address u = address(uint160(uint256(keccak256(abi.encode("linked.handler.user", i)))));
            users[i] = u;
            usdc.mint(u, 1_000_000_000e6);
            vm.prank(u);
            usdc.approve(_diamond, type(uint256).max);
        }
    }

    function childCount() external view returns (uint256) {
        return childIds.length;
    }

    function splitOutcome(uint8 cIdxRaw, uint8 userIdx, uint96 amount) external {
        if (resolved) return;
        if (block.timestamp >= eventEndTime) return;
        uint256 marketId = childIds[cIdxRaw % childIds.length];
        address user = users[userIdx % users.length];
        uint256 amt = bound(amount, 1, 1_000_000e6);
        vm.prank(user);
        market.splitPosition(marketId, amt);
    }

    function mergeOutcome(uint8 cIdxRaw, uint8 userIdx, uint96 amount) external {
        if (resolved) return;
        uint256 marketId = childIds[cIdxRaw % childIds.length];
        address user = users[userIdx % users.length];
        IMarketFacet.MarketView memory m = market.getMarket(marketId);
        uint256 yesBal = IOutcomeToken(m.yesToken).balanceOf(user);
        uint256 noBal = IOutcomeToken(m.noToken).balanceOf(user);
        uint256 maxBurn = yesBal < noBal ? yesBal : noBal;
        if (maxBurn == 0) return;
        uint256 amt = bound(amount, 1, maxBurn);
        vm.prank(user);
        market.mergePositions(marketId, amt);
    }

    function mintCompleteSet(uint8 userIdx, uint96 amount) external {
        if (resolved) return;
        if (block.timestamp >= eventEndTime) return;
        address user = users[userIdx % users.length];
        uint256 amt = bound(amount, 1, 1_000_000e6);
        vm.prank(user);
        linked.mintCompleteSet(eventId, amt);
    }

    function redeemCompleteSet(uint8 userIdx, uint96 amount) external {
        if (resolved) return;
        address user = users[userIdx % users.length];
        // bound by the user's min YES balance across outcomes (a complete set needs one YES of each).
        uint256 maxSet = type(uint256).max;
        for (uint256 i; i < childIds.length; ++i) {
            uint256 y = IOutcomeToken(market.getMarket(childIds[i]).yesToken).balanceOf(user);
            if (y < maxSet) maxSet = y;
        }
        if (maxSet == 0) return;
        uint256 amt = bound(amount, 1, maxSet);
        vm.prank(user);
        linked.redeemCompleteSet(eventId, amt);
    }

    /// @notice Appending an outcome to a linked event must ALWAYS revert (audit F-A guard). The handler
    ///         treats the expected revert as a no-op so state stays valid; a successful call would be a bug
    ///         surfaced by the next invariant evaluation (the outcome set must stay fixed).
    function tryAddOutcome() external {
        if (resolved) return;
        try eventFacet.addEventOutcome(eventId, "late") {
        // unreachable; if it ever succeeds, childIds is now stale and invariants will catch the drift.
        }
            catch {}
    }

    function resolveThenRedeemAll(uint8 winIdxRaw) external {
        if (resolved) return;
        uint256 winIdx = winIdxRaw % childIds.length;
        if (block.timestamp < eventEndTime) {
            vm.warp(eventEndTime + 1);
        }
        eventOracle.setEventResolution(eventId, winIdx);
        eventFacet.resolveEvent(eventId);
        resolved = true;

        for (uint256 u; u < users.length; ++u) {
            try linked.redeemLinked(eventId) {} catch {}
            vm.prank(users[u]);
            try linked.redeemLinked(eventId) {} catch {}
        }
    }
}
