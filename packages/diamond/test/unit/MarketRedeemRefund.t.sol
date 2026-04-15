// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {IAccessControlFacet} from "@predix/shared/interfaces/IAccessControlFacet.sol";
import {IMarketFacet} from "@predix/shared/interfaces/IMarketFacet.sol";
import {IOutcomeToken} from "@predix/shared/interfaces/IOutcomeToken.sol";
import {Modules} from "@predix/shared/constants/Modules.sol";
import {Roles} from "@predix/shared/constants/Roles.sol";

import {MarketFixture} from "../utils/MarketFixture.sol";

contract MarketRedeemRefundTest is MarketFixture {
    uint256 internal id;
    uint256 internal endTime;

    function setUp() public override {
        super.setUp();
        endTime = block.timestamp + 7 days;
        id = _createMarket(endTime);
    }

    function _resolveYes() internal {
        oracle.setResolution(id, true);
        vm.warp(endTime + 1);
        market.resolveMarket(id);
    }

    // -------------------------------------------------
    // redeem
    // -------------------------------------------------

    function test_Redeem_YesWins_Pays1To1() public {
        _split(alice, id, 100e6);
        _resolveYes();
        vm.prank(alice);
        uint256 payout = market.redeem(id);
        assertEq(payout, 100e6);
        assertEq(usdc.balanceOf(alice), 100e6);
        assertEq(_yes(id).balanceOf(alice), 0);
        assertEq(_no(id).balanceOf(alice), 0);
        assertEq(market.getMarket(id).totalCollateral, 0);
    }

    function test_Redeem_BurnsBothBalances() public {
        _split(alice, id, 100e6);
        address noTok = address(_no(id));
        vm.prank(alice);
        IOutcomeToken(noTok).transfer(bob, 40e6);

        _resolveYes();

        // Alice has 100 YES + 60 NO. Redeem burns both, payout = 100.
        vm.prank(alice);
        uint256 payout = market.redeem(id);
        assertEq(payout, 100e6);
        assertEq(_yes(id).balanceOf(alice), 0);
        assertEq(_no(id).balanceOf(alice), 0);

        // Bob has 0 YES + 40 NO. Redeem burns NO only, payout = 0.
        vm.prank(bob);
        uint256 bobPayout = market.redeem(id);
        assertEq(bobPayout, 0);
        assertEq(_no(id).balanceOf(bob), 0);
    }

    function test_Revert_Redeem_NotResolved() public {
        _split(alice, id, 100e6);
        vm.expectRevert(IMarketFacet.Market_NotResolved.selector);
        vm.prank(alice);
        market.redeem(id);
    }

    function test_Revert_Redeem_NothingToRedeem() public {
        _resolveYes();
        vm.expectRevert(IMarketFacet.Market_NothingToRedeem.selector);
        vm.prank(alice);
        market.redeem(id);
    }

    // -------------------------------------------------
    // refund mode
    // -------------------------------------------------

    function test_EnableRefundMode_HappyPath() public {
        vm.warp(endTime + 1);
        vm.prank(admin);
        market.enableRefundMode(id);
        assertTrue(market.getMarket(id).refundModeActive);
    }

    function test_Revert_EnableRefundMode_NotAdmin() public {
        vm.warp(endTime + 1);
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControlFacet.AccessControl_MissingRole.selector, Roles.ADMIN_ROLE, alice)
        );
        vm.prank(alice);
        market.enableRefundMode(id);
    }

    function test_Revert_EnableRefundMode_NotEnded() public {
        vm.expectRevert(IMarketFacet.Market_NotEnded.selector);
        vm.prank(admin);
        market.enableRefundMode(id);
    }

    function test_Revert_EnableRefundMode_AlreadyResolved() public {
        _resolveYes();
        vm.expectRevert(IMarketFacet.Market_AlreadyResolved.selector);
        vm.prank(admin);
        market.enableRefundMode(id);
    }

    // -------------------------------------------------
    // refund
    // -------------------------------------------------

    function test_Refund_FullPair_Returns1To1() public {
        _split(alice, id, 100e6);
        vm.warp(endTime + 1);
        vm.prank(admin);
        market.enableRefundMode(id);

        vm.prank(alice);
        uint256 payout = market.refund(id, 100e6, 100e6);
        assertEq(payout, 100e6);
        assertEq(usdc.balanceOf(alice), 100e6);
        assertEq(market.getMarket(id).totalCollateral, 0);
    }

    function test_Revert_Refund_SingleLeg_NothingToRefund() public {
        _split(alice, id, 100e6);
        address noTok = address(_no(id));
        vm.prank(alice);
        IOutcomeToken(noTok).transfer(bob, 100e6);

        vm.warp(endTime + 1);
        vm.prank(admin);
        market.enableRefundMode(id);

        vm.expectRevert(IMarketFacet.Market_NothingToRefund.selector);
        vm.prank(alice);
        market.refund(id, 100e6, 0);

        vm.expectRevert(IMarketFacet.Market_NothingToRefund.selector);
        vm.prank(bob);
        market.refund(id, 0, 100e6);

        assertEq(market.getMarket(id).totalCollateral, 100e6);
    }

    function test_Refund_PartialAmounts() public {
        _split(alice, id, 100e6);
        vm.warp(endTime + 1);
        vm.prank(admin);
        market.enableRefundMode(id);

        vm.prank(alice);
        uint256 payout = market.refund(id, 30e6, 30e6);
        assertEq(payout, 30e6);
        assertEq(_yes(id).balanceOf(alice), 70e6);
        assertEq(_no(id).balanceOf(alice), 70e6);
    }

    function test_Revert_Refund_NotInRefundMode() public {
        _split(alice, id, 100e6);
        vm.expectRevert(IMarketFacet.Market_RefundModeInactive.selector);
        vm.prank(alice);
        market.refund(id, 100e6, 100e6);
    }

    function test_Revert_Refund_ZeroAmounts() public {
        vm.warp(endTime + 1);
        vm.prank(admin);
        market.enableRefundMode(id);
        vm.expectRevert(IMarketFacet.Market_NothingToRefund.selector);
        vm.prank(alice);
        market.refund(id, 0, 0);
    }

    function test_Revert_Refund_PayoutZeroFromOddSum() public {
        _split(alice, id, 100e6);
        vm.warp(endTime + 1);
        vm.prank(admin);
        market.enableRefundMode(id);
        vm.expectRevert(IMarketFacet.Market_NothingToRefund.selector);
        vm.prank(alice);
        market.refund(id, 1, 0);
    }

    function testFuzz_Refund_SymmetricBurn(uint96 splitAmt, uint96 yesBurn, uint96 noBurn) public {
        splitAmt = uint96(bound(splitAmt, 1, 1e15));
        yesBurn = uint96(bound(yesBurn, 0, splitAmt));
        noBurn = uint96(bound(noBurn, 0, splitAmt));
        uint256 refundable = yesBurn < noBurn ? yesBurn : noBurn;
        vm.assume(refundable >= 1);

        _split(alice, id, splitAmt);
        vm.warp(endTime + 1);
        vm.prank(admin);
        market.enableRefundMode(id);

        vm.prank(alice);
        uint256 payout = market.refund(id, yesBurn, noBurn);
        assertEq(payout, refundable);
        assertEq(_yes(id).balanceOf(alice), uint256(splitAmt) - refundable);
        assertEq(_no(id).balanceOf(alice), uint256(splitAmt) - refundable);
        assertEq(market.getMarket(id).totalCollateral, uint256(splitAmt) - refundable);
    }

    // -------------------------------------------------
    // sweep unclaimed
    // -------------------------------------------------

    function test_Sweep_AfterGrace_Resolved_RefusesLiveBacking() public {
        _split(alice, id, 100e6);
        _resolveYes();
        vm.warp(block.timestamp + 365 days + 1);
        vm.prank(admin);
        uint256 swept = market.sweepUnclaimed(id);
        // Post-FINAL-H03: winning supply is still live, sweep must leave it alone.
        assertEq(swept, 0);
        assertEq(market.getMarket(id).totalCollateral, 100e6);
        assertEq(usdc.balanceOf(feeRecipient), 0);
    }

    function test_Sweep_AfterGrace_RefundMode_RefusesLiveBacking() public {
        _split(alice, id, 100e6);
        vm.warp(endTime + 1);
        vm.prank(admin);
        market.enableRefundMode(id);
        vm.warp(block.timestamp + 365 days + 1);
        vm.prank(admin);
        uint256 swept = market.sweepUnclaimed(id);
        assertEq(swept, 0);
        assertEq(market.getMarket(id).totalCollateral, 100e6);
    }

    function test_Revert_Sweep_NotInFinalState() public {
        vm.expectRevert(IMarketFacet.Market_NotInFinalState.selector);
        vm.prank(admin);
        market.sweepUnclaimed(id);
    }

    function test_Revert_Sweep_GraceNotElapsed() public {
        _resolveYes();
        vm.expectRevert(IMarketFacet.Market_GracePeriodNotElapsed.selector);
        vm.prank(admin);
        market.sweepUnclaimed(id);
    }

    function test_EnableRefundMode_BypassesPause() public {
        vm.warp(endTime + 1);
        vm.prank(admin);
        pausable.pauseModule(Modules.MARKET);
        vm.prank(admin);
        market.enableRefundMode(id);
        assertTrue(market.getMarket(id).refundModeActive);
    }

    function test_EmergencyResolve_BypassesPause() public {
        vm.warp(endTime + 7 days + 1);
        vm.prank(admin);
        pausable.pauseModule(Modules.MARKET);
        vm.prank(admin);
        market.emergencyResolve(id, true);
        assertTrue(market.getMarket(id).isResolved);
    }

    function test_Sweep_BypassesPause() public {
        _split(alice, id, 100e6);
        _resolveYes();
        vm.prank(alice);
        market.redeem(id);
        vm.warp(block.timestamp + 365 days + 1);
        vm.prank(admin);
        pausable.pauseModule(Modules.MARKET);
        vm.prank(admin);
        // Bypass still works post-H03; function returns 0 because alice already
        // redeemed everything, but the call must not revert on pause.
        uint256 swept = market.sweepUnclaimed(id);
        assertEq(swept, 0);
    }

    function test_Revert_Sweep_NotAdmin() public {
        _resolveYes();
        vm.warp(block.timestamp + 365 days + 1);
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControlFacet.AccessControl_MissingRole.selector, Roles.ADMIN_ROLE, alice)
        );
        vm.prank(alice);
        market.sweepUnclaimed(id);
    }
}
