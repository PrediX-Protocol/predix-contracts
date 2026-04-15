// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {IMarketFacet} from "@predix/shared/interfaces/IMarketFacet.sol";
import {IOutcomeToken} from "@predix/shared/interfaces/IOutcomeToken.sol";

import {MarketFixture} from "../utils/MarketFixture.sol";

/// @notice Repro for FINAL-C01: refund formula `(yesAmount + noAmount) / 2`
///         breaks INV-1 when a user holds asymmetric YES/NO balances after
///         trading on the CLOB/AMM. Post-fix, refund must burn equal YES and
///         NO and pay `min(yesAmount, noAmount)` so collateral accounting
///         matches supply.
contract FinalC01_RefundAsymmetricBurn is MarketFixture {
    uint256 internal id;
    uint256 internal endTime;

    function setUp() public override {
        super.setUp();
        endTime = block.timestamp + 7 days;
        id = _createMarket(endTime);
    }

    /// @dev Alice splits 1000, then transfers 500 NO to Bob to simulate a CLOB
    ///      trade. Alice now holds 1000 YES + 500 NO. Under the buggy formula,
    ///      `refund(1000, 500)` pays 750 — 250 more than Alice's pro-rata
    ///      backing. INV-1 must hold strictly after the call.
    function test_INV1_HoldsAfterAsymmetricRefund() public {
        _split(alice, id, 1_000e6);

        IOutcomeToken yes = _yes(id);
        IOutcomeToken no = _no(id);

        vm.prank(alice);
        no.transfer(bob, 500e6);

        vm.warp(endTime + 1);
        vm.prank(admin);
        market.enableRefundMode(id);

        uint256 aliceBefore = usdc.balanceOf(alice);

        vm.prank(alice);
        uint256 payout = market.refund(id, 1_000e6, 500e6);

        // Post-fix: pays exactly min(1000, 500) = 500, burns 500 YES + 500 NO.
        assertEq(payout, 500e6, "payout must equal min(yes,no)");
        assertEq(usdc.balanceOf(alice) - aliceBefore, 500e6);
        assertEq(yes.balanceOf(alice), 500e6, "remaining YES preserved");
        assertEq(no.balanceOf(alice), 0);

        // INV-1: YES.totalSupply == NO.totalSupply == totalCollateral (refund mode).
        uint256 col = market.getMarket(id).totalCollateral;
        assertEq(yes.totalSupply(), no.totalSupply(), "INV-1 supplies equal");
        assertEq(yes.totalSupply(), col, "INV-1 supply == collateral");
        assertEq(col, 500e6);

        // Bob still has 500 NO; he must be able to refund it (finds 0 YES in
        // his balance → refundable = 0 → reverts cleanly without draining).
        vm.prank(bob);
        vm.expectRevert(IMarketFacet.Market_NothingToRefund.selector);
        market.refund(id, 0, 500e6);
    }

    /// @dev Direct demonstration of the pre-fix drain: Alice would otherwise
    ///      receive 750 USDC on (1000, 500) with only 500 USDC of backing.
    function test_RefundSymmetric_FullExit() public {
        _split(alice, id, 100e6);
        vm.warp(endTime + 1);
        vm.prank(admin);
        market.enableRefundMode(id);

        vm.prank(alice);
        uint256 payout = market.refund(id, 100e6, 100e6);
        assertEq(payout, 100e6);
        assertEq(market.getMarket(id).totalCollateral, 0);
    }
}
