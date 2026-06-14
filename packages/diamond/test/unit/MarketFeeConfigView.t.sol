// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import {IAccessControlFacet} from "@predix/shared/interfaces/IAccessControlFacet.sol";
import {IMarketFacet} from "@predix/shared/interfaces/IMarketFacet.sol";
import {Roles} from "@predix/shared/constants/Roles.sol";

import {MarketFixture} from "../utils/MarketFixture.sol";

/// @notice Mức-1 fee module: `getFeeConfig` aggregates every diamond-resident fee for one market (effective
///         values + echoed caps) and the market-creation-fee cap. View + set-time clamp only; no charging.
contract MarketFeeConfigViewTest is MarketFixture {
    uint256 internal constant MAX_CREATE = 1_000e6;

    uint256 internal id;

    function setUp() public override {
        super.setUp();
        id = _createMarket(block.timestamp + 7 days);
    }

    function test_FeeConfig_LaunchZeros_WithCaps() public view {
        IMarketFacet.FeeConfig memory f = market.getFeeConfig(id);
        assertEq(f.redemptionFeeBps, 0, "redemption 0 at launch");
        assertEq(f.protocolFeeRateBps, 0, "protocol 0 at launch");
        assertEq(f.protocolMakerRebateBps, 0, "rebate 0 at launch");
        assertEq(f.maxRedemptionFeeBps, 1000);
        assertEq(f.maxProtocolFeeRateBps, 700);
        assertEq(f.maxProtocolMakerRebateBps, 2500);
        assertEq(f.maxMarketCreationFee, MAX_CREATE);
        assertTrue(f.feeRecipient != address(0), "recipient set at init");
    }

    function test_FeeConfig_ReflectsConfiguredFees() public {
        vm.startPrank(admin);
        market.setDefaultRedemptionFeeBps(250);
        market.setDefaultProtocolFeeRateBps(300);
        market.setProtocolMakerRebateBps(1000);
        vm.stopPrank();
        // snapshots freeze at creation → set BEFORE create
        uint256 id2 = _createMarket(block.timestamp + 7 days);
        IMarketFacet.FeeConfig memory f = market.getFeeConfig(id2);
        assertEq(f.redemptionFeeBps, 250);
        assertEq(f.protocolFeeRateBps, 300);
        assertEq(f.protocolMakerRebateBps, 1000, "rebate is global, applies immediately");
    }

    function test_FeeConfig_PerMarketProtocolOverride_Reflected() public {
        vm.prank(admin);
        market.setPerMarketProtocolFeeRateBps(id, 150);
        assertEq(market.getFeeConfig(id).protocolFeeRateBps, 150);
    }

    function test_CreationFeeCap_AtCeiling_OK() public {
        vm.prank(admin);
        market.setMarketCreationFee(MAX_CREATE); // == cap: must NOT revert
        assertEq(market.getFeeConfig(id).marketCreationFee, MAX_CREATE);
    }

    function test_Revert_CreationFee_AboveCeiling() public {
        vm.expectRevert(IMarketFacet.Market_FeeTooHigh.selector);
        vm.prank(admin);
        market.setMarketCreationFee(MAX_CREATE + 1);
    }

    function test_Revert_CreationFee_NotAdmin() public {
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControlFacet.AccessControl_MissingRole.selector, Roles.ADMIN_ROLE, alice)
        );
        vm.prank(alice);
        market.setMarketCreationFee(1e6);
    }

    function test_Revert_GetFeeConfig_UnknownMarket() public {
        vm.expectRevert(); // `_market` reverts on an unknown id
        market.getFeeConfig(type(uint256).max);
    }
}
