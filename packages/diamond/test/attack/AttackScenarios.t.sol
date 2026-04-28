// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {IMarketFacet} from "@predix/shared/interfaces/IMarketFacet.sol";
import {IOutcomeToken} from "@predix/shared/interfaces/IOutcomeToken.sol";
import {Roles} from "@predix/shared/constants/Roles.sol";

import {MarketFixture} from "../utils/MarketFixture.sol";

/// @notice Attack scenario tests — simulate real attacker behavior.
contract AttackScenarios is MarketFixture {
    uint256 internal id;
    uint256 internal endTime;

    function setUp() public override {
        super.setUp();
        endTime = block.timestamp + 7 days;
        id = _createMarket(endTime);
    }

    // ============ 1. Double-redeem attack ============

    function test_Attack_DoubleRedeem_Reverts() public {
        _split(alice, id, 100e6);
        oracle.setResolution(id, true);
        vm.warp(endTime + 1);
        market.resolveMarket(id);

        vm.prank(alice);
        market.redeem(id);

        // Second redeem: alice has 0 balance now.
        vm.prank(alice);
        vm.expectRevert(IMarketFacet.Market_NothingToRedeem.selector);
        market.redeem(id);
    }

    // ============ 2. Drain via split after endTime ============

    function test_Attack_SplitAfterEndTime_Reverts() public {
        vm.warp(endTime + 1);
        _fundAndApprove(alice, 100e6);
        vm.prank(alice);
        vm.expectRevert(IMarketFacet.Market_Ended.selector);
        market.splitPosition(id, 100e6);
    }

    // ============ 3. Drain via merge after resolve ============

    function test_Attack_MergeAfterResolve_Reverts() public {
        _split(alice, id, 100e6);
        oracle.setResolution(id, true);
        vm.warp(endTime + 1);
        market.resolveMarket(id);

        vm.prank(alice);
        vm.expectRevert(IMarketFacet.Market_AlreadyResolved.selector);
        market.mergePositions(id, 100e6);
    }

    // ============ 4. Collateral invariant after full lifecycle ============

    function test_Attack_CollateralInvariant_FullCycle() public {
        // Split
        _split(alice, id, 500e6);
        _split(bob, id, 300e6);

        assertEq(_yes(id).totalSupply(), 800e6);
        assertEq(_no(id).totalSupply(), 800e6);
        assertEq(market.getMarket(id).totalCollateral, 800e6);

        // Merge partial
        vm.prank(alice);
        market.mergePositions(id, 200e6);

        assertEq(_yes(id).totalSupply(), 600e6);
        assertEq(_no(id).totalSupply(), 600e6);
        assertEq(market.getMarket(id).totalCollateral, 600e6);

        // Resolve + redeem
        oracle.setResolution(id, true);
        vm.warp(endTime + 1);
        market.resolveMarket(id);

        vm.prank(alice);
        market.redeem(id);
        vm.prank(bob);
        market.redeem(id);

        // After all redeems: YES+NO supply should equal remaining collateral
        IMarketFacet.MarketView memory m = market.getMarket(id);
        uint256 winnerSupply = _yes(id).totalSupply();
        assertEq(m.totalCollateral, winnerSupply, "collateral == remaining winner supply");
    }

    // ============ 5. Unauthorized role escalation ============

    function test_Attack_RoleEscalation_Blocked() public {
        // Alice (no roles) tries every admin function
        vm.startPrank(alice);

        vm.expectRevert();
        market.approveOracle(address(0x999));

        vm.expectRevert();
        market.setFeeRecipient(alice);

        vm.expectRevert();
        market.setDefaultRedemptionFeeBps(1500);

        vm.expectRevert();
        market.enableRefundMode(id);

        vm.expectRevert();
        market.emergencyResolve(id, true);

        vm.stopPrank();
    }

    // ============ 6. Zero-amount attacks ============

    function test_Attack_ZeroAmount_Split_Reverts() public {
        _fundAndApprove(alice, 100e6);
        vm.prank(alice);
        vm.expectRevert(IMarketFacet.Market_ZeroAmount.selector);
        market.splitPosition(id, 0);
    }

    function test_Attack_ZeroAmount_Merge_Reverts() public {
        vm.prank(alice);
        vm.expectRevert(IMarketFacet.Market_ZeroAmount.selector);
        market.mergePositions(id, 0);
    }

    // ============ 7. Refund asymmetric burn ============

    function test_Attack_RefundMode_AsymmetricBalance() public {
        _split(alice, id, 100e6);

        // Alice transfers 50 YES to bob (simulates AMM trading)
        address yesAddr = address(_yes(id));
        vm.prank(alice);
        IOutcomeToken(yesAddr).transfer(bob, 50e6);

        vm.warp(endTime + 1);
        vm.prank(admin);
        market.enableRefundMode(id);

        // Alice: 50 YES + 100 NO → refund min(50, 100) = 50
        vm.prank(alice);
        uint256 payout = market.refund(id, 50e6, 100e6);
        assertEq(payout, 50e6, "min(yes, no) refunded");

        // Alice still has 50 NO leftover (from the asymmetry)
        assertEq(_no(id).balanceOf(alice), 50e6, "leftover NO");
        assertEq(_yes(id).balanceOf(alice), 0, "YES fully burned");
    }

    // ============ 8. Max cap enforcement ============

    function test_Attack_ExceedPerMarketCap() public {
        vm.prank(admin);
        market.setPerMarketCap(id, 100e6);

        _split(alice, id, 100e6);

        _fundAndApprove(bob, 1);
        vm.prank(bob);
        vm.expectRevert(IMarketFacet.Market_ExceedsPerMarketCap.selector);
        market.splitPosition(id, 1);
    }

    // ============ 9. Fee snapshot immutability ============

    function test_Attack_FeeSnapshotCannotBeRaised() public {
        // Default fee = 0 at create → snapshot = 0
        // Admin tries to raise per-market override above snapshot
        vm.prank(admin);
        vm.expectRevert(IMarketFacet.Market_FeeExceedsSnapshot.selector);
        market.setPerMarketRedemptionFeeBps(id, 1);
    }

    // ============ 10. Oracle re-approval check at resolve ============

    function test_Attack_RevokedOracle_BlocksResolve() public {
        _split(alice, id, 100e6);
        oracle.setResolution(id, true);
        vm.warp(endTime + 1);

        // Admin revokes oracle before anyone calls resolveMarket
        vm.prank(admin);
        market.revokeOracle(address(oracle));

        // Resolve blocked — oracle no longer approved
        vm.expectRevert(IMarketFacet.Market_OracleNotApproved.selector);
        market.resolveMarket(id);
    }
}
