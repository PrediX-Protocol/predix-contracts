// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import {IAccessControlFacet} from "@predix/shared/interfaces/IAccessControlFacet.sol";
import {IMarketFacet} from "@predix/shared/interfaces/IMarketFacet.sol";
import {Roles} from "@predix/shared/constants/Roles.sol";

import {MarketFixture} from "../utils/MarketFixture.sol";

/// @notice Protocol-fee CONFIG layer: admin-gated default + per-market override + clear + global rebate +
///         caps + creation snapshot + MarketView surfacing + effectiveProtocolFee resolution. No charging
///         (that is the Exchange/Router, Sub-plans 03/04). Mirrors `MarketRedemptionFee.t.sol`.
contract MarketProtocolFeeTest is MarketFixture {
    uint256 internal constant MAX_RATE = 700; // MAX_PROTOCOL_FEE_RATE_BPS
    uint256 internal constant MAX_REBATE = 2500; // MAX_PROTOCOL_MAKER_REBATE_BPS

    uint256 internal id;
    uint256 internal endTime;

    function setUp() public override {
        super.setUp();
        endTime = block.timestamp + 7 days;
        id = _createMarket(endTime);
    }

    // ---- helpers ----

    function _setDefaultRate(uint256 bps) internal {
        vm.prank(admin);
        market.setDefaultProtocolFeeRateBps(bps);
    }

    /// @dev Snapshot is frozen at creation: a market whose effective default rate is non-zero must be
    ///      created AFTER the default is set.
    function _createMarketWithDefaultRate(uint256 bps) internal returns (uint256 newId) {
        _setDefaultRate(bps);
        newId = _createMarket(endTime);
    }

    function _setMarketRate(uint256 marketId, uint16 bps) internal {
        vm.prank(admin);
        market.setPerMarketProtocolFeeRateBps(marketId, bps);
    }

    function _clearMarketRate(uint256 marketId) internal {
        vm.prank(admin);
        market.clearPerMarketProtocolFee(marketId);
    }

    function _setRebate(uint16 bps) internal {
        vm.prank(admin);
        market.setProtocolMakerRebateBps(bps);
    }

    function _rate(uint256 marketId) internal view returns (uint16 r) {
        (r,) = market.effectiveProtocolFee(marketId);
    }

    function _rebate(uint256 marketId) internal view returns (uint16 rb) {
        (, rb) = market.effectiveProtocolFee(marketId);
    }

    // ---- launch defaults ----

    function test_Defaults_StartZero() public view {
        assertEq(_rate(id), 0, "rate 0 at launch");
        assertEq(_rebate(id), 0, "rebate 0 at launch");
        IMarketFacet.MarketView memory m = market.getMarket(id);
        assertEq(m.protocolFeeRateBps, 0);
        assertEq(m.protocolMakerRebateBps, 0);
    }

    // ---- setDefaultProtocolFeeRateBps + snapshot ----

    function test_SetDefaultRate_SnapshotsAtCreate_NotRetroactive() public {
        _setDefaultRate(300);
        // Existing market `id` was created with default 0 → snapshot frozen at 0.
        assertEq(_rate(id), 0, "existing market snapshot unchanged");
        // New markets pick up the new default at creation.
        uint256 id2 = _createMarket(endTime);
        assertEq(_rate(id2), 300, "new market snapshots current default");
    }

    function test_SetDefaultRate_AtCeiling() public {
        _setDefaultRate(MAX_RATE);
        uint256 id2 = _createMarket(endTime);
        assertEq(_rate(id2), uint16(MAX_RATE));
    }

    function test_Revert_SetDefaultRate_AboveCeiling() public {
        vm.expectRevert(IMarketFacet.Market_FeeTooHigh.selector);
        vm.prank(admin);
        market.setDefaultProtocolFeeRateBps(MAX_RATE + 1);
    }

    function test_Revert_SetDefaultRate_NotAdmin() public {
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControlFacet.AccessControl_MissingRole.selector, Roles.ADMIN_ROLE, alice)
        );
        vm.prank(alice);
        market.setDefaultProtocolFeeRateBps(100);
    }

    function test_SetDefaultRate_EmitsEvent() public {
        vm.expectEmit(true, true, true, true, address(diamond));
        emit IMarketFacet.DefaultProtocolFeeRateSet(0, 300);
        vm.prank(admin);
        market.setDefaultProtocolFeeRateBps(300);
    }

    // ---- setPerMarketProtocolFeeRateBps + clear ----

    function test_SetPerMarketRate_OverridesSnapshot() public {
        uint256 id2 = _createMarketWithDefaultRate(500);
        _setMarketRate(id2, 200);
        assertEq(_rate(id2), 200);
        IMarketFacet.MarketView memory m = market.getMarket(id2);
        assertEq(m.protocolFeeRateBps, 200);
    }

    function test_SetPerMarketRate_ExplicitZero() public {
        uint256 id2 = _createMarketWithDefaultRate(300);
        _setMarketRate(id2, 0);
        assertEq(_rate(id2), 0, "explicit-0 override beats non-zero snapshot");
    }

    /// @dev Lower-after-end rule is DROPPED (§13.1): a RAISE after endTime is permitted (it cannot affect
    ///      any trade, which is blocked at endTime). This is the behavioral inversion vs. the redemption fee.
    function test_SetPerMarketRate_RaiseAfterEnd_Allowed() public {
        uint256 id2 = _createMarketWithDefaultRate(100);
        vm.warp(endTime + 1); // market has ended
        _setMarketRate(id2, 500); // a RAISE — would revert for redemption fee, allowed here
        assertEq(_rate(id2), 500);
    }

    function test_Revert_SetPerMarketRate_AboveCeiling() public {
        vm.expectRevert(IMarketFacet.Market_FeeTooHigh.selector);
        vm.prank(admin);
        market.setPerMarketProtocolFeeRateBps(id, uint16(MAX_RATE + 1));
    }

    function test_Revert_SetPerMarketRate_NotAdmin() public {
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControlFacet.AccessControl_MissingRole.selector, Roles.ADMIN_ROLE, alice)
        );
        vm.prank(alice);
        market.setPerMarketProtocolFeeRateBps(id, 100);
    }

    function test_Revert_SetPerMarketRate_NotFound() public {
        vm.expectRevert(IMarketFacet.Market_NotFound.selector);
        vm.prank(admin);
        market.setPerMarketProtocolFeeRateBps(999, 100);
    }

    function test_SetPerMarketRate_EmitsEvent() public {
        uint256 id2 = _createMarketWithDefaultRate(500);
        vm.expectEmit(true, true, true, true, address(diamond));
        emit IMarketFacet.PerMarketProtocolFeeRateSet(id2, 400, true);
        vm.prank(admin);
        market.setPerMarketProtocolFeeRateBps(id2, 400);
    }

    function test_ClearPerMarketRate_RestoresSnapshot() public {
        uint256 id2 = _createMarketWithDefaultRate(500);
        _setMarketRate(id2, 200);
        assertEq(_rate(id2), 200);
        _clearMarketRate(id2);
        assertEq(_rate(id2), 500, "falls back to snapshot");
        IMarketFacet.MarketView memory m = market.getMarket(id2);
        assertEq(m.protocolFeeRateBps, 500);
    }

    function test_ClearPerMarketRate_Idempotent_NoOverride() public {
        _clearMarketRate(id); // no override → succeeds, stays on snapshot 0
        assertEq(_rate(id), 0);
    }

    function test_ClearPerMarketRate_EmitsEvent() public {
        uint256 id2 = _createMarketWithDefaultRate(500);
        _setMarketRate(id2, 400);
        vm.expectEmit(true, true, true, true, address(diamond));
        emit IMarketFacet.PerMarketProtocolFeeRateSet(id2, 0, false);
        vm.prank(admin);
        market.clearPerMarketProtocolFee(id2);
    }

    function test_Revert_ClearPerMarketRate_NotAdmin() public {
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControlFacet.AccessControl_MissingRole.selector, Roles.ADMIN_ROLE, alice)
        );
        vm.prank(alice);
        market.clearPerMarketProtocolFee(id);
    }

    function test_EffectiveProtocolFee_OverrideThenSnapshot() public {
        uint256 id2 = _createMarketWithDefaultRate(500);
        assertEq(_rate(id2), 500);
        _setMarketRate(id2, 200);
        assertEq(_rate(id2), 200);
        _clearMarketRate(id2);
        assertEq(_rate(id2), 500);
    }

    // ---- setProtocolMakerRebateBps (global) ----

    function test_SetRebate_HappyPath_VisibleOnAllMarkets() public {
        _setRebate(1000);
        // Rebate is global → visible on every market regardless of creation order.
        assertEq(_rebate(id), 1000);
        uint256 id2 = _createMarket(endTime);
        assertEq(_rebate(id2), 1000);
        IMarketFacet.MarketView memory m = market.getMarket(id);
        assertEq(m.protocolMakerRebateBps, 1000);
    }

    function test_SetRebate_AtCeiling() public {
        _setRebate(uint16(MAX_REBATE));
        assertEq(_rebate(id), uint16(MAX_REBATE));
    }

    function test_Revert_SetRebate_AboveCeiling() public {
        vm.expectRevert(IMarketFacet.Market_FeeTooHigh.selector);
        vm.prank(admin);
        market.setProtocolMakerRebateBps(uint16(MAX_REBATE + 1));
    }

    function test_Revert_SetRebate_NotAdmin() public {
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControlFacet.AccessControl_MissingRole.selector, Roles.ADMIN_ROLE, alice)
        );
        vm.prank(alice);
        market.setProtocolMakerRebateBps(100);
    }

    function test_SetRebate_EmitsEvent() public {
        vm.expectEmit(true, true, true, true, address(diamond));
        emit IMarketFacet.ProtocolMakerRebateSet(0, 1500);
        vm.prank(admin);
        market.setProtocolMakerRebateBps(1500);
    }

    // ---- MarketView carries effective rate + rebate together ----

    function test_MarketView_CarriesEffectiveRateAndRebate() public {
        uint256 id2 = _createMarketWithDefaultRate(400);
        _setRebate(800);
        _setMarketRate(id2, 250); // override beats snapshot 400
        IMarketFacet.MarketView memory m = market.getMarket(id2);
        assertEq(m.protocolFeeRateBps, 250, "MarketView carries EFFECTIVE rate");
        assertEq(m.protocolMakerRebateBps, 800, "MarketView carries global rebate");
    }

    // ---- fuzz ----

    function testFuzz_DefaultRateRoundtrip_SnapshotOnNewMarket(uint256 bpsRaw) public {
        uint256 bps = bound(bpsRaw, 0, MAX_RATE);
        _setDefaultRate(bps);
        uint256 id2 = _createMarket(endTime);
        assertEq(_rate(id2), uint16(bps));
    }

    function testFuzz_PerMarketRateRoundtrip(uint16 bpsRaw) public {
        uint256 bps = bound(uint256(bpsRaw), 0, MAX_RATE);
        _setMarketRate(id, uint16(bps));
        assertEq(_rate(id), uint16(bps));
    }

    function testFuzz_Revert_RateOutOfRange(uint256 bpsRaw) public {
        uint256 bps = bound(bpsRaw, MAX_RATE + 1, type(uint256).max);
        vm.expectRevert(IMarketFacet.Market_FeeTooHigh.selector);
        vm.prank(admin);
        market.setDefaultProtocolFeeRateBps(bps);
    }

    function testFuzz_Revert_RebateOutOfRange(uint16 bpsRaw) public {
        vm.assume(bpsRaw > MAX_REBATE);
        vm.expectRevert(IMarketFacet.Market_FeeTooHigh.selector);
        vm.prank(admin);
        market.setProtocolMakerRebateBps(bpsRaw);
    }
}
