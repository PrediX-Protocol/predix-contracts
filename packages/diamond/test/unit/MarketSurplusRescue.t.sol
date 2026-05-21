// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import {IMarketFacet} from "@predix/shared/interfaces/IMarketFacet.sol";

import {MarketFixture} from "../utils/MarketFixture.sol";

/// @notice Pins the `totalCollateralLocked` aggregate and the `rescueSurplus`
///         recovery path: surplus = `balanceOf(diamond) - totalCollateralLocked`
///         is forwarded to `feeRecipient` without ever touching live backing.
contract MarketSurplusRescueTest is MarketFixture {
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

    function _donate(uint256 amount) internal {
        usdc.mint(address(this), amount);
        usdc.transfer(address(diamond), amount);
    }

    function test_TotalCollateralLocked_TracksSplitAndMerge() public {
        assertEq(market.totalCollateralLocked(), 0);

        _split(alice, id, 100e6);
        assertEq(market.totalCollateralLocked(), 100e6);

        _split(bob, id, 50e6);
        assertEq(market.totalCollateralLocked(), 150e6);

        vm.prank(alice);
        market.mergePositions(id, 30e6);
        assertEq(market.totalCollateralLocked(), 120e6);
    }

    function test_TotalCollateralLocked_DecrementsOnRedeem() public {
        _split(alice, id, 100e6);
        _resolveYes();

        vm.prank(alice);
        market.redeem(id);
        assertEq(market.totalCollateralLocked(), 0);
    }

    function test_RescueSurplus_RecoversDirectDonation() public {
        _split(alice, id, 100e6);
        _donate(50e6);

        uint256 feeRecipBefore = usdc.balanceOf(feeRecipient);

        vm.prank(admin);
        uint256 surplus = market.rescueSurplus();

        assertEq(surplus, 50e6, "sweeps exactly the donation");
        assertEq(usdc.balanceOf(feeRecipient) - feeRecipBefore, 50e6);
        // Backing untouched.
        assertEq(market.totalCollateralLocked(), 100e6);
        assertEq(market.getMarket(id).totalCollateral, 100e6);
    }

    function test_RescueSurplus_NoSurplus_ReturnsZero() public {
        _split(alice, id, 100e6);
        vm.prank(admin);
        assertEq(market.rescueSurplus(), 0);
    }

    function test_RescueSurplus_NeverTouchesBacking() public {
        _split(alice, id, 100e6);
        _donate(50e6);

        vm.prank(admin);
        market.rescueSurplus();

        // Live backing is intact: alice still redeems her full winning amount.
        _resolveYes();
        vm.prank(alice);
        uint256 payout = market.redeem(id);
        assertEq(payout, 100e6);
    }

    function test_RescueSurplus_OnlyAdmin() public {
        _donate(50e6);
        vm.prank(alice);
        vm.expectRevert();
        market.rescueSurplus();
    }
}
