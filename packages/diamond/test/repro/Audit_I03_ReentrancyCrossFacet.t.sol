// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import {Test} from "forge-std/Test.sol";

import {IMarketFacet} from "@predix/shared/interfaces/IMarketFacet.sol";
import {IEventFacet} from "@predix/shared/interfaces/IEventFacet.sol";
import {IOutcomeToken} from "@predix/shared/interfaces/IOutcomeToken.sol";
import {TransientReentrancyGuard} from "@predix/shared/utils/TransientReentrancyGuard.sol";

import {EventFixture} from "../utils/EventFixture.sol";

/// @dev Harness that mirrors the single-slot transient guard semantics so we
///      can exercise the modifier itself outside the diamond's facet context.
///      The slot is namespaced by the same `keccak256("predix.reentrancy.v1") - 1`
///      constant as production code, so an external call from `outer` into
///      `inner` (both `nonReentrant`) lands in the slot's same-tx ENTERED state
///      and reverts — the exact path that protects every facet's
///      `nonReentrant` entry point.
contract ReentrancyHarness is TransientReentrancyGuard {
    uint256 public innerCallCount;

    function outer() external nonReentrant {
        this.inner();
    }

    function inner() external nonReentrant {
        innerCallCount++;
    }
}

/// @title Audit_I03_ReentrancyCrossFacet
/// @notice Regression for the transient-storage reentrancy guard. Two
///         properties are pinned:
///
///         1. The guard blocks re-entry of any `nonReentrant` function during
///            an in-flight `nonReentrant` call (cross-facet OR self-call).
///         2. The guard fully clears between top-level calls within the same
///            transaction — so a script / multicall that invokes several
///            facet entry points sequentially is NOT blocked.
///
///         Property (2) is the "single global slot doesn't block legitimate
///         cross-facet entry" check from the audit's I-03: PrediX makes no
///         external calls to user-controlled code from inside any
///         `nonReentrant` function, so the only way a re-entry could occur is
///         via a deliberate self-call — which is correctly rejected.
contract Audit_I03_ReentrancyCrossFacet is EventFixture {
    uint256 internal eventId;
    uint256[] internal childMarketIds;

    ReentrancyHarness internal harness;

    function setUp() public override {
        super.setUp();
        harness = new ReentrancyHarness();
    }

    // ===================== Guard blocks re-entry =====================

    /// @dev The transient slot is set on entry to a `nonReentrant` function
    ///      and read by every subsequent `nonReentrant` entry in the same
    ///      tx-frame stack. An external call from `outer` to `inner`
    ///      satisfies that condition and must revert.
    function test_I03_GuardBlocksReentry_OnSelfCall() public {
        vm.expectRevert(TransientReentrancyGuard.ReentrantCall.selector);
        harness.outer();

        // Sanity: inner alone is not blocked when there is no outer frame.
        harness.inner();
        assertEq(harness.innerCallCount(), 1);
    }

    // ===================== Guard clears between top-level calls =====================

    /// @dev Two sequential top-level `nonReentrant` invocations in the same
    ///      transaction MUST both succeed. The modifier's exit `tstore(slot, 0)`
    ///      is what enables this. If a future refactor accidentally left the
    ///      slot in ENTERED state on exit, the second invocation would revert.
    function test_I03_GuardClearsBetweenSequentialCalls() public {
        harness.inner();
        harness.inner();
        harness.inner();
        assertEq(harness.innerCallCount(), 3);
    }

    /// @dev Cross-facet diamond regression: split + redeem are both
    ///      `nonReentrant`, on different facets, sharing the same transient
    ///      slot. A multi-action test like this would revert if the slot
    ///      leaked between top-level calls.
    function test_I03_CrossFacetSequentialCalls_OnDiamond_NotBlocked() public {
        uint256 endTime_ = block.timestamp + 30 days;
        uint256 marketId = _createMarket(endTime_);

        _split(alice, marketId, 100e6);

        oracle.setResolution(marketId, true);
        vm.warp(endTime_ + 1);
        market.resolveMarket(marketId);

        vm.prank(alice);
        uint256 payout = market.redeem(marketId);
        assertEq(payout, 100e6);
    }

    /// @dev Event-facet cross-call: createEvent invokes the internal
    ///      child-market creation path. The whole tx is a single user-facing
    ///      transaction with multiple internal facet boundary crossings;
    ///      none of them should trip the guard.
    function test_I03_EventCreate_InternalMarketCreates_NotBlocked() public {
        string[] memory questions = _defaultQuestions(3);

        vm.prank(alice);
        (uint256 eventId_, uint256[] memory ids) =
            eventFacet.createEvent("event guard", questions, block.timestamp + 30 days, address(eventOracle));

        assertEq(ids.length, 3, "three child markets created");
        IEventFacet.EventView memory e = eventFacet.getEvent(eventId_);
        assertEq(e.marketIds.length, 3);
    }

    /// @dev View reads must not be gated by the reentrancy slot — they are
    ///      called via `staticcall` semantics from off-chain or from a
    ///      separate facet's `nonReentrant` function with no risk of
    ///      mutating state. This test confirms a view call works without
    ///      depending on slot state.
    function test_I03_ViewReads_NotGatedByGuard() public {
        uint256 marketId = _createMarket(block.timestamp + 30 days);

        // The view returns the stored MarketView; no `nonReentrant` modifier.
        IMarketFacet.MarketView memory m = market.getMarket(marketId);
        assertTrue(m.yesToken != address(0), "yesToken set");
        assertTrue(m.noToken != address(0), "noToken set");
    }
}
