// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IMarketFacet} from "@predix/shared/interfaces/IMarketFacet.sol";
import {IOutcomeToken} from "@predix/shared/interfaces/IOutcomeToken.sol";
import {ManualOracle} from "@predix/oracle/adapters/ManualOracle.sol";
import {E2EForkBase} from "./E2EForkBase.t.sol";

/// @title E2E_MarketLifecycle
/// @notice Groups A, B, C, D: Market create/split/merge, resolve/redeem, emergency/refund, fees.
///         197-case coverage: A01–A16, B01–B14, C01–C10, D01–D08.
contract E2E_MarketLifecycle is E2EForkBase {
    uint256 internal constant END_OFFSET = 7 days;

    // ================================================================
    // A. Market Creation
    // ================================================================

    function test_A01_createMarket_happyPath() public {
        _grantCreatorRole(alice);
        uint256 mid = _createMarket(alice, block.timestamp + END_OFFSET);
        IMarketFacet.MarketView memory m = diamond.getMarket(mid);
        assertGt(mid, 0);
        assertTrue(m.yesToken != address(0));
        assertTrue(m.noToken != address(0));
        assertEq(m.totalCollateral, 0);
        assertFalse(m.isResolved);
    }

    function test_A02_createMarket_Revert_nonCreator() public {
        vm.prank(eve);
        vm.expectRevert();
        diamond.createMarket("test", block.timestamp + 1 days, MANUAL_ORACLE);
    }

    function test_A03_createMarket_Revert_endTimeInPast() public {
        _grantCreatorRole(alice);
        vm.prank(alice);
        vm.expectRevert();
        diamond.createMarket("test", block.timestamp - 1, MANUAL_ORACLE);
    }

    function test_A04_createMarket_Revert_endTimeExactlyNow() public {
        _grantCreatorRole(alice);
        vm.prank(alice);
        vm.expectRevert();
        diamond.createMarket("test", block.timestamp, MANUAL_ORACLE);
    }

    function test_A05_createMarket_Revert_oracleNotApproved() public {
        _grantCreatorRole(alice);
        vm.prank(alice);
        vm.expectRevert();
        diamond.createMarket("test", block.timestamp + 1 days, address(0xdead));
    }

    function test_A06_createMarket_Revert_emptyQuestion() public {
        _grantCreatorRole(alice);
        vm.prank(alice);
        vm.expectRevert();
        diamond.createMarket("", block.timestamp + 1 days, MANUAL_ORACLE);
    }

    function test_A07_createMarket_Revert_oracleZeroAddress() public {
        _grantCreatorRole(alice);
        vm.prank(alice);
        vm.expectRevert();
        diamond.createMarket("test", block.timestamp + 1 days, address(0));
    }

    function test_A08_createMarket_withCreationFee() public {
        vm.prank(DEPLOYER);
        diamond.setMarketCreationFee(5e6);

        _grantCreatorRole(alice);
        uint256 balBefore = IERC20(USDC).balanceOf(alice);
        vm.startPrank(alice);
        IERC20(USDC).approve(DIAMOND, 5e6);
        diamond.createMarket("fee test", block.timestamp + 1 days, MANUAL_ORACLE);
        vm.stopPrank();
        assertEq(balBefore - IERC20(USDC).balanceOf(alice), 5e6);

        vm.prank(DEPLOYER);
        diamond.setMarketCreationFee(0);
    }

    // ================================================================
    // A. Split / Merge
    // ================================================================

    function test_A09_splitPosition_happyPath() public {
        _grantCreatorRole(alice);
        uint256 mid = _createMarket(alice, block.timestamp + END_OFFSET);
        _splitPosition(alice, mid, 1000e6);

        (address yes, address noToken) = _getTokens(mid);
        assertEq(IERC20(yes).balanceOf(alice), 1000e6);
        assertEq(IERC20(noToken).balanceOf(alice), 1000e6);
        assertEq(diamond.getMarket(mid).totalCollateral, 1000e6);
    }

    function test_A10_splitPosition_Revert_zeroAmount() public {
        _grantCreatorRole(alice);
        uint256 mid = _createMarket(alice, block.timestamp + END_OFFSET);
        vm.prank(alice);
        vm.expectRevert();
        diamond.splitPosition(mid, 0);
    }

    function test_A11_splitPosition_Revert_afterEndTime() public {
        _grantCreatorRole(alice);
        uint256 mid = _createMarket(alice, block.timestamp + 1 hours);
        vm.warp(block.timestamp + 2 hours);
        vm.startPrank(alice);
        IERC20(USDC).approve(DIAMOND, 100e6);
        vm.expectRevert();
        diamond.splitPosition(mid, 100e6);
        vm.stopPrank();
    }

    function test_A12_splitPosition_Revert_resolved() public {
        _grantCreatorRole(alice);
        uint256 mid = _createMarket(alice, block.timestamp + 1 hours);
        _splitPosition(alice, mid, 100e6);
        vm.warp(block.timestamp + 2 hours);
        _reportOutcome(mid, true);
        _resolveMarket(mid);

        vm.startPrank(alice);
        IERC20(USDC).approve(DIAMOND, 100e6);
        vm.expectRevert();
        diamond.splitPosition(mid, 100e6);
        vm.stopPrank();
    }

    function test_A13_splitPosition_Revert_refundMode() public {
        _grantCreatorRole(alice);
        uint256 mid = _createMarket(alice, block.timestamp + 1 hours);
        _splitPosition(alice, mid, 100e6);
        vm.warp(block.timestamp + 2 hours);
        vm.prank(DEPLOYER);
        diamond.enableRefundMode(mid);

        vm.startPrank(alice);
        IERC20(USDC).approve(DIAMOND, 100e6);
        vm.expectRevert();
        diamond.splitPosition(mid, 100e6);
        vm.stopPrank();
    }

    function test_A14_splitPosition_Revert_exceedsCap() public {
        _grantCreatorRole(alice);
        uint256 mid = _createMarket(alice, block.timestamp + END_OFFSET);
        vm.prank(DEPLOYER);
        diamond.setPerMarketCap(mid, 500e6);

        vm.startPrank(alice);
        IERC20(USDC).approve(DIAMOND, 600e6);
        vm.expectRevert();
        diamond.splitPosition(mid, 600e6);
        vm.stopPrank();
    }

    function test_A15_splitPosition_capZero_unlimited() public {
        _grantCreatorRole(alice);
        uint256 mid = _createMarket(alice, block.timestamp + END_OFFSET);
        _splitPosition(alice, mid, 50_000e6);
        assertEq(diamond.getMarket(mid).totalCollateral, 50_000e6);
    }

    function test_A16_mergePositions_partialMerge() public {
        _grantCreatorRole(alice);
        uint256 mid = _createMarket(alice, block.timestamp + END_OFFSET);
        _splitPosition(alice, mid, 1000e6);

        (address yes, address noToken) = _getTokens(mid);
        uint256 usdcBefore = IERC20(USDC).balanceOf(alice);
        vm.prank(alice);
        diamond.mergePositions(mid, 500e6);

        assertEq(IERC20(yes).balanceOf(alice), 500e6);
        assertEq(IERC20(noToken).balanceOf(alice), 500e6);
        assertEq(IERC20(USDC).balanceOf(alice) - usdcBefore, 500e6);
        assertEq(diamond.getMarket(mid).totalCollateral, 500e6);
    }

    // ================================================================
    // B. Resolve & Redeem
    // ================================================================

    function test_B01_resolveMarket_YESWins() public {
        _grantCreatorRole(alice);
        uint256 mid = _createMarket(alice, block.timestamp + 1 hours);
        _splitPosition(alice, mid, 1000e6);
        vm.warp(block.timestamp + 2 hours);
        _reportOutcome(mid, true);
        _resolveMarket(mid);

        IMarketFacet.MarketView memory m = diamond.getMarket(mid);
        assertTrue(m.isResolved);
        assertTrue(m.outcome);
    }

    function test_B02_resolveMarket_NOWins() public {
        _grantCreatorRole(alice);
        uint256 mid = _createMarket(alice, block.timestamp + 1 hours);
        _splitPosition(alice, mid, 1000e6);
        vm.warp(block.timestamp + 2 hours);
        _reportOutcome(mid, false);
        _resolveMarket(mid);

        IMarketFacet.MarketView memory m = diamond.getMarket(mid);
        assertTrue(m.isResolved);
        assertFalse(m.outcome);
    }

    function test_B03_resolveMarket_Revert_beforeEndTime() public {
        _grantCreatorRole(alice);
        uint256 mid = _createMarket(alice, block.timestamp + 1 days);
        vm.expectRevert();
        _resolveMarket(mid);
    }

    function test_B04_resolveMarket_Revert_oracleNotAnswered() public {
        _grantCreatorRole(alice);
        uint256 mid = _createMarket(alice, block.timestamp + 1 hours);
        vm.warp(block.timestamp + 2 hours);
        vm.expectRevert();
        _resolveMarket(mid);
    }

    function test_B05_resolveMarket_Revert_oracleRevoked() public {
        _grantCreatorRole(alice);
        uint256 mid = _createMarket(alice, block.timestamp + 1 hours);
        _splitPosition(alice, mid, 100e6);
        vm.warp(block.timestamp + 2 hours);
        _reportOutcome(mid, true);

        vm.prank(DEPLOYER);
        diamond.revokeOracle(MANUAL_ORACLE);
        vm.expectRevert();
        _resolveMarket(mid);

        vm.prank(DEPLOYER);
        diamond.approveOracle(MANUAL_ORACLE);
    }

    function test_B06_resolveMarket_Revert_twice() public {
        _grantCreatorRole(alice);
        uint256 mid = _createMarket(alice, block.timestamp + 1 hours);
        _splitPosition(alice, mid, 100e6);
        vm.warp(block.timestamp + 2 hours);
        _reportOutcome(mid, true);
        _resolveMarket(mid);
        vm.expectRevert();
        _resolveMarket(mid);
    }

    function test_B08_redeem_winner() public {
        _grantCreatorRole(alice);
        uint256 mid = _createMarket(alice, block.timestamp + 1 hours);
        _splitPosition(alice, mid, 1000e6);
        vm.warp(block.timestamp + 2 hours);
        _reportOutcome(mid, true);
        _resolveMarket(mid);

        (address yes,) = _getTokens(mid);
        uint256 yesBal = IERC20(yes).balanceOf(alice);
        uint256 usdcBefore = IERC20(USDC).balanceOf(alice);

        vm.prank(alice);
        uint256 payout = diamond.redeem(mid);

        assertGt(payout, 0);
        assertEq(IERC20(yes).balanceOf(alice), 0);
        assertEq(IERC20(USDC).balanceOf(alice) - usdcBefore, payout);
    }

    function test_B09_redeem_loser_zeroPayoutOrRevert() public {
        _grantCreatorRole(alice);
        uint256 mid = _createMarket(alice, block.timestamp + 1 hours);
        _splitPosition(alice, mid, 1000e6);

        (address yes, address noToken) = _getTokens(mid);
        // alice sends ALL YES to bob, keeps only NO (loser side)
        vm.startPrank(alice);
        IERC20(yes).transfer(bob, 1000e6);
        IERC20(noToken).transfer(charlie, 1000e6);
        vm.stopPrank();
        // alice has 0 YES + 0 NO → NothingToRedeem

        vm.warp(block.timestamp + 2 hours);
        _reportOutcome(mid, true);
        _resolveMarket(mid);

        vm.prank(alice);
        vm.expectRevert();
        diamond.redeem(mid);

        // charlie holds only NO (loser), redeem gives 0 payout
        vm.prank(charlie);
        uint256 payout = diamond.redeem(mid);
        assertEq(payout, 0);
    }

    function test_B10_redeem_holdBothSides() public {
        _grantCreatorRole(alice);
        uint256 mid = _createMarket(alice, block.timestamp + 1 hours);
        _splitPosition(alice, mid, 1000e6);

        (address yes, address noToken) = _getTokens(mid);
        vm.prank(alice);
        IERC20(noToken).transfer(bob, 500e6);
        // alice: 1000 YES + 500 NO

        vm.warp(block.timestamp + 2 hours);
        _reportOutcome(mid, true);
        _resolveMarket(mid);

        vm.prank(alice);
        uint256 payout = diamond.redeem(mid);
        // YES wins: payout from 1000 YES. NO worth 0 but still in wallet.
        assertGt(payout, 0);
        assertEq(IERC20(yes).balanceOf(alice), 0);
        // redeem burns BOTH YES and NO from caller — loser tokens burned too (worth 0)
        assertEq(IERC20(noToken).balanceOf(alice), 0);
    }

    function test_B11_redeem_Revert_beforeResolve() public {
        _grantCreatorRole(alice);
        uint256 mid = _createMarket(alice, block.timestamp + 1 hours);
        _splitPosition(alice, mid, 100e6);
        vm.prank(alice);
        vm.expectRevert();
        diamond.redeem(mid);
    }

    function test_B12_redeem_Revert_twice() public {
        _grantCreatorRole(alice);
        uint256 mid = _createMarket(alice, block.timestamp + 1 hours);
        _splitPosition(alice, mid, 1000e6);
        vm.warp(block.timestamp + 2 hours);
        _reportOutcome(mid, true);
        _resolveMarket(mid);

        vm.prank(alice);
        diamond.redeem(mid);
        vm.prank(alice);
        vm.expectRevert();
        diamond.redeem(mid);
    }

    function test_B13_redeem_withRedemptionFee() public {
        vm.prank(DEPLOYER);
        diamond.setDefaultRedemptionFeeBps(200);

        _grantCreatorRole(alice);
        uint256 mid = _createMarket(alice, block.timestamp + 1 hours);
        _splitPosition(alice, mid, 10_000e6);
        vm.warp(block.timestamp + 2 hours);
        _reportOutcome(mid, true);
        _resolveMarket(mid);

        uint256 usdcBefore = IERC20(USDC).balanceOf(alice);
        vm.prank(alice);
        uint256 payout = diamond.redeem(mid);

        assertEq(payout, 9800e6);
        assertEq(IERC20(USDC).balanceOf(alice) - usdcBefore, 9800e6);

        vm.prank(DEPLOYER);
        diamond.setDefaultRedemptionFeeBps(0);
    }

    function test_B14_feePlusPayoutEqualsBurned() public {
        vm.prank(DEPLOYER);
        diamond.setDefaultRedemptionFeeBps(200);

        _grantCreatorRole(alice);
        uint256 mid = _createMarket(alice, block.timestamp + 1 hours);
        _splitPosition(alice, mid, 10_000e6);
        vm.warp(block.timestamp + 2 hours);
        _reportOutcome(mid, true);
        _resolveMarket(mid);

        (address yes,) = _getTokens(mid);
        uint256 burned = IERC20(yes).balanceOf(alice);
        address feeRecip = diamond.feeRecipient();
        uint256 feeRecipBefore = IERC20(USDC).balanceOf(feeRecip);

        vm.prank(alice);
        uint256 payout = diamond.redeem(mid);

        uint256 feeCollected = IERC20(USDC).balanceOf(feeRecip) - feeRecipBefore;
        assertEq(payout + feeCollected, burned);

        vm.prank(DEPLOYER);
        diamond.setDefaultRedemptionFeeBps(0);
    }

    // ================================================================
    // C. Emergency & Refund
    // ================================================================

    function test_C01_emergencyResolve_after7dDelay() public {
        _grantCreatorRole(alice);
        uint256 mid = _createMarket(alice, block.timestamp + 1 hours);
        _splitPosition(alice, mid, 100e6);
        vm.warp(block.timestamp + 1 hours + 7 days + 1);

        vm.prank(DEPLOYER);
        diamond.emergencyResolve(mid, true);
        assertTrue(diamond.getMarket(mid).isResolved);
    }

    function test_C02_emergencyResolve_Revert_before7d() public {
        _grantCreatorRole(alice);
        uint256 mid = _createMarket(alice, block.timestamp + 1 hours);
        vm.warp(block.timestamp + 2 hours);
        vm.prank(DEPLOYER);
        vm.expectRevert();
        diamond.emergencyResolve(mid, true);
    }

    function test_C03_emergencyResolve_atExactly7d() public {
        _grantCreatorRole(alice);
        uint256 endTime = block.timestamp + 1 hours;
        uint256 mid = _createMarket(alice, endTime);
        _splitPosition(alice, mid, 100e6);
        vm.warp(endTime + 7 days);

        vm.prank(DEPLOYER);
        diamond.emergencyResolve(mid, true);
        assertTrue(diamond.getMarket(mid).isResolved);
    }

    function test_C04_emergencyResolve_Revert_oracleAnswered() public {
        _grantCreatorRole(alice);
        uint256 mid = _createMarket(alice, block.timestamp + 1 hours);
        _splitPosition(alice, mid, 100e6);
        vm.warp(block.timestamp + 1 hours + 7 days + 1);
        _reportOutcome(mid, true);

        vm.prank(DEPLOYER);
        vm.expectRevert();
        diamond.emergencyResolve(mid, true);
    }

    function test_C05_emergencyResolve_Revert_nonOperator() public {
        _grantCreatorRole(alice);
        uint256 mid = _createMarket(alice, block.timestamp + 1 hours);
        vm.warp(block.timestamp + 1 hours + 7 days + 1);
        vm.prank(eve);
        vm.expectRevert();
        diamond.emergencyResolve(mid, true);
    }

    function test_C06_enableRefundMode_postEndTime() public {
        _grantCreatorRole(alice);
        uint256 mid = _createMarket(alice, block.timestamp + 1 hours);
        _splitPosition(alice, mid, 100e6);
        vm.warp(block.timestamp + 2 hours);

        vm.prank(DEPLOYER);
        diamond.enableRefundMode(mid);
        assertTrue(diamond.getMarket(mid).refundModeActive);
    }

    function test_C07_enableRefundMode_Revert_beforeEndTime() public {
        _grantCreatorRole(alice);
        uint256 mid = _createMarket(alice, block.timestamp + 1 days);
        vm.prank(DEPLOYER);
        vm.expectRevert();
        diamond.enableRefundMode(mid);
    }

    function test_C09_refund_unequalAmounts() public {
        _grantCreatorRole(alice);
        uint256 mid = _createMarket(alice, block.timestamp + 1 hours);
        _splitPosition(alice, mid, 1000e6);
        vm.warp(block.timestamp + 2 hours);
        vm.prank(DEPLOYER);
        diamond.enableRefundMode(mid);

        uint256 usdcBefore = IERC20(USDC).balanceOf(alice);
        vm.prank(alice);
        diamond.refund(mid, 1000e6, 500e6);
        uint256 refunded = IERC20(USDC).balanceOf(alice) - usdcBefore;
        assertEq(refunded, 500e6);

        (address yes, address noToken) = _getTokens(mid);
        assertEq(IERC20(yes).balanceOf(alice), 500e6);
        assertEq(IERC20(noToken).balanceOf(alice), 500e6);
    }

    function test_C10_sweepUnclaimed_after365d() public {
        // Test sweep timing gate + successful call.
        // In standard flow (payout = burned), sweep returns 0 because
        // totalCollateral tracks payouts exactly. Sweep captures orphaned
        // collateral (e.g., tokens burned via transfer to dead address).
        _grantCreatorRole(alice);
        uint256 mid = _createMarket(alice, block.timestamp + 1 hours);
        _splitPosition(alice, mid, 1000e6);
        vm.warp(block.timestamp + 2 hours);
        _reportOutcome(mid, true);
        _resolveMarket(mid);

        // Before grace period: should revert
        vm.prank(DEPLOYER);
        vm.expectRevert();
        diamond.sweepUnclaimed(mid);

        // After grace period: callable (returns 0 in standard flow)
        vm.warp(block.timestamp + 365 days + 1);
        vm.prank(DEPLOYER);
        uint256 swept = diamond.sweepUnclaimed(mid);
        assertEq(swept, 0);
    }

    // ================================================================
    // D. Redemption Fee Edge Cases
    // ================================================================

    function test_D01_setDefaultRedemptionFeeBps() public {
        vm.prank(DEPLOYER);
        diamond.setDefaultRedemptionFeeBps(200);
        assertEq(diamond.defaultRedemptionFeeBps(), 200);
        vm.prank(DEPLOYER);
        diamond.setDefaultRedemptionFeeBps(0);
    }

    function test_D02_setDefaultRedemptionFeeBps_max1500() public {
        vm.prank(DEPLOYER);
        diamond.setDefaultRedemptionFeeBps(1500);
        assertEq(diamond.defaultRedemptionFeeBps(), 1500);
        vm.prank(DEPLOYER);
        diamond.setDefaultRedemptionFeeBps(0);
    }

    function test_D03_setDefaultRedemptionFeeBps_Revert_above1500() public {
        vm.prank(DEPLOYER);
        vm.expectRevert();
        diamond.setDefaultRedemptionFeeBps(1501);
    }

    function test_D04_setPerMarketFee_lowers() public {
        vm.prank(DEPLOYER);
        diamond.setDefaultRedemptionFeeBps(500);

        _grantCreatorRole(alice);
        uint256 mid = _createMarket(alice, block.timestamp + END_OFFSET);

        vm.prank(DEPLOYER);
        diamond.setPerMarketRedemptionFeeBps(mid, 100);
        assertEq(diamond.effectiveRedemptionFeeBps(mid), 100);

        vm.prank(DEPLOYER);
        diamond.setDefaultRedemptionFeeBps(0);
    }

    function test_D05_setPerMarketFee_Revert_aboveSnapshot() public {
        vm.prank(DEPLOYER);
        diamond.setDefaultRedemptionFeeBps(200);

        _grantCreatorRole(alice);
        uint256 mid = _createMarket(alice, block.timestamp + END_OFFSET);

        vm.prank(DEPLOYER);
        vm.expectRevert();
        diamond.setPerMarketRedemptionFeeBps(mid, 300);

        vm.prank(DEPLOYER);
        diamond.setDefaultRedemptionFeeBps(0);
    }

    function test_D06_clearPerMarketFee_fallsBackToDefault() public {
        vm.prank(DEPLOYER);
        diamond.setDefaultRedemptionFeeBps(500);

        _grantCreatorRole(alice);
        uint256 mid = _createMarket(alice, block.timestamp + END_OFFSET);

        vm.prank(DEPLOYER);
        diamond.setPerMarketRedemptionFeeBps(mid, 100);
        assertEq(diamond.effectiveRedemptionFeeBps(mid), 100);

        vm.prank(DEPLOYER);
        diamond.clearPerMarketRedemptionFee(mid);
        assertEq(diamond.effectiveRedemptionFeeBps(mid), 500);

        vm.prank(DEPLOYER);
        diamond.setDefaultRedemptionFeeBps(0);
    }

    function test_D07_feeChange_Revert_afterResolve() public {
        _grantCreatorRole(alice);
        uint256 mid = _createMarket(alice, block.timestamp + 1 hours);
        _splitPosition(alice, mid, 100e6);
        vm.warp(block.timestamp + 2 hours);
        _reportOutcome(mid, true);
        _resolveMarket(mid);

        vm.prank(DEPLOYER);
        vm.expectRevert();
        diamond.setPerMarketRedemptionFeeBps(mid, 50);
    }

    function test_D08_feeSnapshot_protectsUser() public {
        vm.prank(DEPLOYER);
        diamond.setDefaultRedemptionFeeBps(200);

        _grantCreatorRole(alice);
        uint256 mid = _createMarket(alice, block.timestamp + 1 hours);
        _splitPosition(alice, mid, 10_000e6);

        vm.prank(DEPLOYER);
        diamond.setDefaultRedemptionFeeBps(500);

        vm.warp(block.timestamp + 2 hours);
        _reportOutcome(mid, true);
        _resolveMarket(mid);

        vm.prank(alice);
        uint256 payout = diamond.redeem(mid);
        assertEq(payout, 9800e6);

        vm.prank(DEPLOYER);
        diamond.setDefaultRedemptionFeeBps(0);
    }
}
