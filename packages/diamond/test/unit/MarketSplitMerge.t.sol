// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {IMarketFacet} from "@predix/shared/interfaces/IMarketFacet.sol";
import {IOutcomeToken} from "@predix/shared/interfaces/IOutcomeToken.sol";

import {MarketFixture} from "../utils/MarketFixture.sol";

contract MarketSplitMergeTest is MarketFixture {
    uint256 internal id;

    function setUp() public override {
        super.setUp();
        id = _createMarket(block.timestamp + 7 days);
    }

    function test_Split_HappyPath_MintsBothTokens() public {
        _split(alice, id, 100e6);
        assertEq(_yes(id).balanceOf(alice), 100e6);
        assertEq(_no(id).balanceOf(alice), 100e6);
        assertEq(market.getMarket(id).totalCollateral, 100e6);
        assertEq(usdc.balanceOf(address(diamond)), 100e6);
    }

    function test_Split_AccumulatesCollateralAcrossUsers() public {
        _split(alice, id, 100e6);
        _split(bob, id, 50e6);
        assertEq(market.getMarket(id).totalCollateral, 150e6);
        assertEq(_yes(id).totalSupply(), 150e6);
        assertEq(_no(id).totalSupply(), 150e6);
    }

    function test_Merge_BurnsAndReturns() public {
        _split(alice, id, 100e6);
        vm.prank(alice);
        market.mergePositions(id, 30e6);
        assertEq(_yes(id).balanceOf(alice), 70e6);
        assertEq(_no(id).balanceOf(alice), 70e6);
        assertEq(market.getMarket(id).totalCollateral, 70e6);
        assertEq(usdc.balanceOf(alice), 30e6);
    }

    function test_Merge_AllowedAfterEndTime() public {
        _split(alice, id, 100e6);
        vm.warp(block.timestamp + 8 days);
        vm.prank(alice);
        market.mergePositions(id, 100e6);
        assertEq(_yes(id).totalSupply(), 0);
    }

    function test_Revert_Split_ZeroAmount() public {
        vm.expectRevert(IMarketFacet.Market_ZeroAmount.selector);
        vm.prank(alice);
        market.splitPosition(id, 0);
    }

    function test_Revert_Split_AfterEndTime() public {
        vm.warp(block.timestamp + 8 days);
        _fundAndApprove(alice, 100e6);
        vm.expectRevert(IMarketFacet.Market_Ended.selector);
        vm.prank(alice);
        market.splitPosition(id, 100e6);
    }

    function test_Revert_Split_ExceedsPerMarketCap() public {
        vm.prank(admin);
        market.setPerMarketCap(id, 50e6);
        _fundAndApprove(alice, 100e6);
        vm.expectRevert(IMarketFacet.Market_ExceedsPerMarketCap.selector);
        vm.prank(alice);
        market.splitPosition(id, 100e6);
    }

    function test_Revert_Split_ExceedsDefaultCap() public {
        vm.prank(admin);
        market.setDefaultPerMarketCap(50e6);
        _fundAndApprove(alice, 100e6);
        vm.expectRevert(IMarketFacet.Market_ExceedsPerMarketCap.selector);
        vm.prank(alice);
        market.splitPosition(id, 100e6);
    }

    function test_Split_PerMarketCapOverridesDefault() public {
        vm.prank(admin);
        market.setDefaultPerMarketCap(50e6);
        vm.prank(admin);
        market.setPerMarketCap(id, 200e6);
        _split(alice, id, 100e6);
        assertEq(_yes(id).balanceOf(alice), 100e6);
    }

    function test_Revert_Split_NotFound() public {
        vm.expectRevert(IMarketFacet.Market_NotFound.selector);
        vm.prank(alice);
        market.splitPosition(999, 1e6);
    }

    function test_Revert_Merge_ZeroAmount() public {
        _split(alice, id, 100e6);
        vm.expectRevert(IMarketFacet.Market_ZeroAmount.selector);
        vm.prank(alice);
        market.mergePositions(id, 0);
    }

    function test_Revert_Merge_NotFound() public {
        vm.expectRevert(IMarketFacet.Market_NotFound.selector);
        vm.prank(alice);
        market.mergePositions(999, 1e6);
    }

    function test_Revert_Split_RefundMode() public {
        vm.warp(block.timestamp + 8 days);
        vm.prank(admin);
        market.enableRefundMode(id);
        _fundAndApprove(alice, 100e6);
        vm.expectRevert(IMarketFacet.Market_RefundModeActive.selector);
        vm.prank(alice);
        market.splitPosition(id, 100e6);
    }

    function test_Revert_Merge_RefundMode() public {
        _split(alice, id, 100e6);
        vm.warp(block.timestamp + 8 days);
        vm.prank(admin);
        market.enableRefundMode(id);
        vm.expectRevert(IMarketFacet.Market_RefundModeActive.selector);
        vm.prank(alice);
        market.mergePositions(id, 50e6);
    }

    function testFuzz_SplitMerge_Roundtrip(uint96 splitAmt, uint96 mergeAmt) public {
        splitAmt = uint96(bound(splitAmt, 1, 1e15));
        mergeAmt = uint96(bound(mergeAmt, 0, splitAmt));

        _split(alice, id, splitAmt);
        if (mergeAmt > 0) {
            vm.prank(alice);
            market.mergePositions(id, mergeAmt);
        }
        uint256 remaining = uint256(splitAmt) - uint256(mergeAmt);
        assertEq(_yes(id).balanceOf(alice), remaining);
        assertEq(_no(id).balanceOf(alice), remaining);
        assertEq(market.getMarket(id).totalCollateral, remaining);
        assertEq(usdc.balanceOf(alice), uint256(mergeAmt));
    }
}
