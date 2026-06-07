// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import {IMarketFacet} from "@predix/shared/interfaces/IMarketFacet.sol";

import {EventFixture} from "../utils/EventFixture.sol";

/// @notice Reproduce-first lock for sc-audit finding U2-CAP-01 (bd keyti-esar, Low): the per-market
///         collateral cap (`defaultPerMarketCap` / `perMarketCap`) is an admin risk limit that is
///         silently NOT applied to linked (shared-collateral) children — their backing pools at the
///         event level, where no cap is checked. Standalone markets DO enforce it. This documents the
///         asymmetry: a linked event can pool arbitrary collateral regardless of the configured cap.
contract Audit_U2CAP_LinkedCapBypass is EventFixture {
    uint256 internal constant CAP = 100e6; // small admin cap
    uint256 internal constant BIG = 1_000e6; // 10x over the cap

    /// @dev Control: a standalone market enforces the cap.
    function test_U2CAP_StandaloneMarket_EnforcesPerMarketCap() public {
        vm.prank(admin);
        market.setDefaultPerMarketCap(CAP);

        uint256 id = _createMarket(block.timestamp + 1 days); // standalone (MockOracle)
        _fundAndApprove(bob, BIG);
        vm.prank(bob);
        vm.expectRevert(IMarketFacet.Market_ExceedsPerMarketCap.selector);
        market.splitPosition(id, BIG);
    }

    /// @dev The finding: a linked child pools BIG (>> CAP) with no cap check — via splitEvent AND
    ///      via a single-child split. The admin's per-market risk limit is silently bypassed.
    function test_U2CAP_LinkedChild_SilentlyBypassesPerMarketCap() public {
        vm.prank(admin);
        market.setDefaultPerMarketCap(CAP);

        (uint256 eventId, uint256[] memory ids) = _createThreeCandidateEvent(block.timestamp + 1 days);

        // splitEvent pools BIG with no cap enforcement
        _fundAndApprove(bob, BIG);
        vm.prank(bob);
        eventFacet.splitEvent(eventId, BIG);
        assertEq(eventFacet.eventPoolOf(eventId), BIG, "linked pool exceeded the per-market cap unchecked");

        // a single linked-child split also bypasses the cap (routes to the pool)
        _fundAndApprove(bob, BIG);
        vm.prank(bob);
        market.splitPosition(ids[0], BIG);
        assertEq(eventFacet.eventPoolOf(eventId), BIG * 2, "second over-cap deposit also accepted");
    }
}
