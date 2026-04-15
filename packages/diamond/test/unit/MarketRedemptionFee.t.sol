// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {IAccessControlFacet} from "@predix/shared/interfaces/IAccessControlFacet.sol";
import {IMarketFacet} from "@predix/shared/interfaces/IMarketFacet.sol";
import {IOutcomeToken} from "@predix/shared/interfaces/IOutcomeToken.sol";
import {Roles} from "@predix/shared/constants/Roles.sol";

import {MarketFixture} from "../utils/MarketFixture.sol";

/// @notice Protocol redemption fee: admin-gated default + per-market override + ceiling +
///         view collapse + redeem-path math + refund-path no-fee property.
contract MarketRedemptionFeeTest is MarketFixture {
    uint256 internal constant MAX_BPS = 1500;
    uint256 internal constant BPS_DEN = 10_000;

    uint256 internal id;
    uint256 internal endTime;

    function setUp() public override {
        super.setUp();
        endTime = block.timestamp + 7 days;
        id = _createMarket(endTime);
    }

    // -----------------------------------------------------------------------
    // helpers
    // -----------------------------------------------------------------------

    function _resolveYes() internal {
        oracle.setResolution(id, true);
        vm.warp(endTime + 1);
        market.resolveMarket(id);
    }

    function _setDefaultFee(uint256 bps) internal {
        vm.prank(admin);
        market.setDefaultRedemptionFeeBps(bps);
    }

    /// @dev Default fee is snapshotted at creation (FINAL-H04). Tests that need a
    ///      market whose effective default fee is non-zero must set the default
    ///      before creating the market.
    function _createMarketWithDefault(uint256 bps) internal returns (uint256 newId) {
        _setDefaultFee(bps);
        newId = _createMarket(endTime);
    }

    function _setMarketFee(uint256 marketId, uint16 bps) internal {
        vm.prank(admin);
        market.setPerMarketRedemptionFeeBps(marketId, bps);
    }

    function _clearMarketFee(uint256 marketId) internal {
        vm.prank(admin);
        market.clearPerMarketRedemptionFee(marketId);
    }

    // -----------------------------------------------------------------------
    // defaults / startup state
    // -----------------------------------------------------------------------

    function test_DefaultRedemptionFeeBps_StartsZero() public view {
        assertEq(market.defaultRedemptionFeeBps(), 0);
        assertEq(market.effectiveRedemptionFeeBps(id), 0);
    }

    function test_GetMarket_IncludesPerMarketFeeFields() public {
        IMarketFacet.MarketView memory m = market.getMarket(id);
        assertEq(m.perMarketRedemptionFeeBps, 0);
        assertFalse(m.redemptionFeeOverridden);

        _setMarketFee(id, 250);
        m = market.getMarket(id);
        assertEq(m.perMarketRedemptionFeeBps, 250);
        assertTrue(m.redemptionFeeOverridden);
    }

    // -----------------------------------------------------------------------
    // setDefaultRedemptionFeeBps
    // -----------------------------------------------------------------------

    function test_SetDefaultRedemptionFeeBps_HappyPath() public {
        // Default updates the global config; existing markets retain their snapshot.
        _setDefaultFee(200);
        assertEq(market.defaultRedemptionFeeBps(), 200);
        assertEq(market.effectiveRedemptionFeeBps(id), 0, "existing market snapshot unchanged");
        // New markets pick up the new default.
        uint256 id2 = _createMarket(endTime);
        assertEq(market.effectiveRedemptionFeeBps(id2), 200);
    }

    function test_SetDefaultRedemptionFeeBps_AtCeiling() public {
        _setDefaultFee(MAX_BPS);
        assertEq(market.defaultRedemptionFeeBps(), MAX_BPS);
    }

    function test_Revert_SetDefaultRedemptionFeeBps_AboveCeiling() public {
        vm.expectRevert(IMarketFacet.Market_FeeTooHigh.selector);
        vm.prank(admin);
        market.setDefaultRedemptionFeeBps(MAX_BPS + 1);
    }

    function test_Revert_SetDefaultRedemptionFeeBps_NotAdmin() public {
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControlFacet.AccessControl_MissingRole.selector, Roles.ADMIN_ROLE, alice)
        );
        vm.prank(alice);
        market.setDefaultRedemptionFeeBps(100);
    }

    function test_SetDefaultRedemptionFeeBps_EmitsEvent() public {
        vm.expectEmit(true, true, true, true, address(diamond));
        emit IMarketFacet.DefaultRedemptionFeeUpdated(0, 300);
        vm.prank(admin);
        market.setDefaultRedemptionFeeBps(300);
    }

    // -----------------------------------------------------------------------
    // setPerMarketRedemptionFeeBps + clearPerMarketRedemptionFee
    // -----------------------------------------------------------------------

    function test_SetPerMarketRedemptionFeeBps_HappyPath() public {
        _setMarketFee(id, 500);
        assertEq(market.effectiveRedemptionFeeBps(id), 500);
    }

    function test_SetPerMarketRedemptionFeeBps_ExplicitZero() public {
        _setDefaultFee(200);
        _setMarketFee(id, 0);
        // Override present, value 0 → charges 0% even though default is 2%.
        assertEq(market.effectiveRedemptionFeeBps(id), 0);
        IMarketFacet.MarketView memory m = market.getMarket(id);
        assertTrue(m.redemptionFeeOverridden);
        assertEq(m.perMarketRedemptionFeeBps, 0);
    }

    function test_SetPerMarketRedemptionFeeBps_OverridesDefault() public {
        _setDefaultFee(200);
        _setMarketFee(id, 500);
        assertEq(market.effectiveRedemptionFeeBps(id), 500);
    }

    function test_Revert_SetPerMarketRedemptionFeeBps_AboveCeiling() public {
        vm.expectRevert(IMarketFacet.Market_FeeTooHigh.selector);
        vm.prank(admin);
        market.setPerMarketRedemptionFeeBps(id, uint16(MAX_BPS + 1));
    }

    function test_Revert_SetPerMarketRedemptionFeeBps_NotAdmin() public {
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControlFacet.AccessControl_MissingRole.selector, Roles.ADMIN_ROLE, alice)
        );
        vm.prank(alice);
        market.setPerMarketRedemptionFeeBps(id, 100);
    }

    function test_Revert_SetPerMarketRedemptionFeeBps_NotFound() public {
        vm.expectRevert(IMarketFacet.Market_NotFound.selector);
        vm.prank(admin);
        market.setPerMarketRedemptionFeeBps(999, 100);
    }

    function test_ClearPerMarketRedemptionFee_RestoresSnapshot() public {
        uint256 id2 = _createMarketWithDefault(200);
        _setMarketFee(id2, 500);
        assertEq(market.effectiveRedemptionFeeBps(id2), 500);
        _clearMarketFee(id2);
        assertEq(market.effectiveRedemptionFeeBps(id2), 200, "falls back to snapshot");
        IMarketFacet.MarketView memory m = market.getMarket(id2);
        assertFalse(m.redemptionFeeOverridden);
        assertEq(m.perMarketRedemptionFeeBps, 0);
    }

    function test_ClearPerMarketRedemptionFee_NoopIfNoOverride() public {
        _clearMarketFee(id); // No override set, should succeed idempotently.
        IMarketFacet.MarketView memory m = market.getMarket(id);
        assertFalse(m.redemptionFeeOverridden);
    }

    function test_PerMarketRedemptionFeeBps_EmitsEvent() public {
        vm.expectEmit(true, true, true, true, address(diamond));
        emit IMarketFacet.PerMarketRedemptionFeeUpdated(id, 400, true);
        vm.prank(admin);
        market.setPerMarketRedemptionFeeBps(id, 400);

        vm.expectEmit(true, true, true, true, address(diamond));
        emit IMarketFacet.PerMarketRedemptionFeeUpdated(id, 0, false);
        vm.prank(admin);
        market.clearPerMarketRedemptionFee(id);
    }

    function test_EffectiveRedemptionFeeBps_FollowsOverrideThenSnapshot() public {
        uint256 id2 = _createMarketWithDefault(200);
        assertEq(market.effectiveRedemptionFeeBps(id2), 200);
        // Override market to 500 → effective 500.
        _setMarketFee(id2, 500);
        assertEq(market.effectiveRedemptionFeeBps(id2), 500);
        // Clear override → effective back to snapshot 200.
        _clearMarketFee(id2);
        assertEq(market.effectiveRedemptionFeeBps(id2), 200);
    }

    // -----------------------------------------------------------------------
    // redeem math
    // -----------------------------------------------------------------------

    function test_Redeem_NoFee_PayoutFull() public {
        _split(alice, id, 1000e6);
        _resolveYes();
        uint256 aliceBalBefore = usdc.balanceOf(alice);
        uint256 feeRecipBefore = usdc.balanceOf(feeRecipient);
        vm.prank(alice);
        uint256 payout = market.redeem(id);
        assertEq(payout, 1000e6);
        assertEq(usdc.balanceOf(alice) - aliceBalBefore, 1000e6);
        assertEq(usdc.balanceOf(feeRecipient) - feeRecipBefore, 0);
    }

    function test_Redeem_DefaultFee_DeductedAndForwarded() public {
        uint256 id2 = _createMarketWithDefault(200); // 2%
        _split(alice, id2, 1000e6);
        oracle.setResolution(id2, true);
        vm.warp(endTime + 1);
        market.resolveMarket(id2);
        uint256 feeRecipBefore = usdc.balanceOf(feeRecipient);
        vm.prank(alice);
        uint256 payout = market.redeem(id2);
        assertEq(payout, 980e6);
        assertEq(usdc.balanceOf(feeRecipient) - feeRecipBefore, 20e6);
    }

    function test_Redeem_PerMarketFee_OverridesDefault() public {
        _setDefaultFee(200);
        _setMarketFee(id, 500); // 5%
        _split(alice, id, 1000e6);
        _resolveYes();
        uint256 feeRecipBefore = usdc.balanceOf(feeRecipient);
        vm.prank(alice);
        uint256 payout = market.redeem(id);
        assertEq(payout, 950e6);
        assertEq(usdc.balanceOf(feeRecipient) - feeRecipBefore, 50e6);
    }

    function test_Redeem_PerMarketFee_ExplicitZeroOverride() public {
        _setDefaultFee(200);
        _setMarketFee(id, 0); // explicit 0
        _split(alice, id, 1000e6);
        _resolveYes();
        uint256 feeRecipBefore = usdc.balanceOf(feeRecipient);
        vm.prank(alice);
        uint256 payout = market.redeem(id);
        assertEq(payout, 1000e6);
        assertEq(usdc.balanceOf(feeRecipient) - feeRecipBefore, 0);
    }

    function test_Redeem_FeeAtCeiling() public {
        uint256 id2 = _createMarketWithDefault(MAX_BPS); // 15%
        _split(alice, id2, 1000e6);
        oracle.setResolution(id2, true);
        vm.warp(endTime + 1);
        market.resolveMarket(id2);
        uint256 feeRecipBefore = usdc.balanceOf(feeRecipient);
        vm.prank(alice);
        uint256 payout = market.redeem(id2);
        assertEq(payout, 850e6);
        assertEq(usdc.balanceOf(feeRecipient) - feeRecipBefore, 150e6);
    }

    function test_Redeem_RoundingDown_NoLeftover() public {
        uint256 id2 = _createMarketWithDefault(200);
        _split(alice, id2, 333);
        oracle.setResolution(id2, true);
        vm.warp(endTime + 1);
        market.resolveMarket(id2);
        uint256 feeRecipBefore = usdc.balanceOf(feeRecipient);
        uint256 diamondBefore = usdc.balanceOf(address(diamond));
        vm.prank(alice);
        uint256 payout = market.redeem(id2);
        uint256 fee = usdc.balanceOf(feeRecipient) - feeRecipBefore;
        assertEq(fee + payout, 333);
        assertEq(diamondBefore - usdc.balanceOf(address(diamond)), 333);
    }

    function test_Redeem_OnlyLosingTokens_NoFee() public {
        // Alice split 100 USDC; bob ends up with 100 NO tokens (loser on YES outcome).
        _split(alice, id, 100e6);
        address noTok = market.getMarket(id).noToken;
        vm.prank(alice);
        IOutcomeToken(noTok).transfer(bob, 100e6);
        _setDefaultFee(1000); // fee ON, but bob only holds losers.
        _resolveYes();

        uint256 bobBefore = usdc.balanceOf(bob);
        uint256 feeRecipBefore = usdc.balanceOf(feeRecipient);
        vm.prank(bob);
        uint256 payout = market.redeem(id);
        assertEq(payout, 0);
        assertEq(usdc.balanceOf(bob) - bobBefore, 0);
        assertEq(usdc.balanceOf(feeRecipient) - feeRecipBefore, 0);
    }

    function test_Redeem_FeeEvent_FieldsCorrect() public {
        uint256 id2 = _createMarketWithDefault(500); // 5%
        _split(alice, id2, 1000e6);
        oracle.setResolution(id2, true);
        vm.warp(endTime + 1);
        market.resolveMarket(id2);
        vm.expectEmit(true, true, true, true, address(diamond));
        emit IMarketFacet.TokensRedeemed(id2, alice, 1000e6, 1000e6, 50e6, 950e6);
        vm.prank(alice);
        market.redeem(id2);
    }

    // -----------------------------------------------------------------------
    // Refund + Sweep unaffected
    // -----------------------------------------------------------------------

    function test_Refund_NoFee_EvenWhenRedemptionFeeSet() public {
        _setDefaultFee(MAX_BPS); // 15% redemption fee
        _split(alice, id, 1000e6);

        vm.warp(endTime + 1);
        vm.prank(admin);
        market.enableRefundMode(id);

        uint256 balBefore = usdc.balanceOf(alice);
        uint256 feeRecipBefore = usdc.balanceOf(feeRecipient);
        vm.prank(alice);
        uint256 payout = market.refund(id, 1000e6, 1000e6);
        assertEq(payout, 1000e6);
        assertEq(usdc.balanceOf(alice) - balBefore, 1000e6);
        assertEq(usdc.balanceOf(feeRecipient) - feeRecipBefore, 0);
    }

    function test_Sweep_StillWorks() public {
        _setDefaultFee(500);
        _split(alice, id, 100e6);
        _resolveYes();
        // Post-FINAL-H03: sweep must refuse to take backing while alice's winning
        // token is still live. Alice can still redeem post-grace.
        vm.warp(block.timestamp + 365 days + 1);
        uint256 before = usdc.balanceOf(feeRecipient);
        vm.prank(admin);
        uint256 swept = market.sweepUnclaimed(id);
        assertEq(swept, 0);
        assertEq(usdc.balanceOf(feeRecipient) - before, 0);
    }

    // -----------------------------------------------------------------------
    // Fuzz
    // -----------------------------------------------------------------------

    function testFuzz_FeeMath_PayoutPlusFeeEqualsBurned(uint256 winningAmount, uint16 bpsRaw) public pure {
        uint256 winning = bound(winningAmount, 0, 1e15);
        uint256 bps = bound(uint256(bpsRaw), 0, MAX_BPS);
        uint256 fee = (winning * bps) / BPS_DEN;
        uint256 payout = winning - fee;
        assertEq(fee + payout, winning);
    }

    function testFuzz_DefaultBpsRoundtrip(uint256 bpsRaw) public {
        uint256 bps = bound(bpsRaw, 0, MAX_BPS);
        _setDefaultFee(bps);
        assertEq(market.defaultRedemptionFeeBps(), bps);
        // Snapshotted: a new market reads the current default at creation.
        uint256 id2 = _createMarket(endTime);
        assertEq(market.effectiveRedemptionFeeBps(id2), bps);
    }

    function testFuzz_PerMarketBpsRoundtrip(uint16 bpsRaw) public {
        uint256 bps = bound(uint256(bpsRaw), 0, MAX_BPS);
        _setMarketFee(id, uint16(bps));
        assertEq(market.effectiveRedemptionFeeBps(id), bps);
    }

    function testFuzz_Revert_OutOfRange(uint256 bpsRaw) public {
        uint256 bps = bound(bpsRaw, MAX_BPS + 1, type(uint256).max);
        vm.expectRevert(IMarketFacet.Market_FeeTooHigh.selector);
        vm.prank(admin);
        market.setDefaultRedemptionFeeBps(bps);
    }
}
