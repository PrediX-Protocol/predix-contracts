// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {IAccessControlFacet} from "@predix/shared/interfaces/IAccessControlFacet.sol";
import {IMarketFacet} from "@predix/shared/interfaces/IMarketFacet.sol";
import {Roles} from "@predix/shared/constants/Roles.sol";

import {MarketFixture} from "../utils/MarketFixture.sol";

contract MarketResolveTest is MarketFixture {
    uint256 internal id;
    uint256 internal endTime;

    function setUp() public override {
        super.setUp();
        endTime = block.timestamp + 7 days;
        id = _createMarket(endTime);
    }

    function test_Resolve_YesWins() public {
        oracle.setResolution(id, true);
        vm.warp(endTime + 1);
        vm.prank(bob);
        market.resolveMarket(id);
        IMarketFacet.MarketView memory m = market.getMarket(id);
        assertTrue(m.isResolved);
        assertTrue(m.outcome);
        assertEq(m.resolvedAt, block.timestamp);
    }

    function test_Resolve_NoWins() public {
        oracle.setResolution(id, false);
        vm.warp(endTime + 1);
        vm.prank(bob);
        market.resolveMarket(id);
        assertFalse(market.getMarket(id).outcome);
    }

    function test_Revert_Resolve_NotEnded() public {
        oracle.setResolution(id, true);
        vm.expectRevert(IMarketFacet.Market_NotEnded.selector);
        vm.prank(bob);
        market.resolveMarket(id);
    }

    function test_Revert_Resolve_OracleNotResolved() public {
        vm.warp(endTime + 1);
        vm.expectRevert(IMarketFacet.Market_OracleNotResolved.selector);
        vm.prank(bob);
        market.resolveMarket(id);
    }

    function test_Revert_Resolve_AlreadyResolved() public {
        oracle.setResolution(id, true);
        vm.warp(endTime + 1);
        vm.prank(bob);
        market.resolveMarket(id);

        vm.expectRevert(IMarketFacet.Market_AlreadyResolved.selector);
        vm.prank(bob);
        market.resolveMarket(id);
    }

    function test_Revert_Resolve_RefundMode() public {
        vm.warp(endTime + 1);
        vm.prank(admin);
        market.enableRefundMode(id);
        vm.expectRevert(IMarketFacet.Market_RefundModeActive.selector);
        market.resolveMarket(id);
    }

    function test_Revert_Resolve_NotFound() public {
        vm.expectRevert(IMarketFacet.Market_NotFound.selector);
        market.resolveMarket(999);
    }

    function test_EmergencyResolve_HappyPath() public {
        vm.warp(endTime + 7 days + 1);
        vm.prank(admin);
        market.emergencyResolve(id, true);
        IMarketFacet.MarketView memory m = market.getMarket(id);
        assertTrue(m.isResolved);
        assertTrue(m.outcome);
    }

    function test_Revert_EmergencyResolve_NotOperator() public {
        vm.warp(endTime + 7 days + 1);
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControlFacet.AccessControl_MissingRole.selector, Roles.OPERATOR_ROLE, alice)
        );
        vm.prank(alice);
        market.emergencyResolve(id, true);
    }

    function test_Revert_EmergencyResolve_TooEarly() public {
        vm.warp(endTime + 1);
        vm.expectRevert(IMarketFacet.Market_TooEarlyForEmergency.selector);
        vm.prank(admin);
        market.emergencyResolve(id, true);
    }

    function test_Revert_EmergencyResolve_AlreadyResolved() public {
        oracle.setResolution(id, true);
        vm.warp(endTime + 1);
        vm.prank(bob);
        market.resolveMarket(id);

        vm.warp(endTime + 7 days + 1);
        vm.expectRevert(IMarketFacet.Market_AlreadyResolved.selector);
        vm.prank(admin);
        market.emergencyResolve(id, false);
    }

    function test_Revert_EmergencyResolve_RefundMode() public {
        vm.warp(endTime + 1);
        vm.prank(admin);
        market.enableRefundMode(id);
        vm.warp(endTime + 7 days + 1);
        vm.expectRevert(IMarketFacet.Market_RefundModeActive.selector);
        vm.prank(admin);
        market.emergencyResolve(id, true);
    }

    /// @notice F2 regression — resolveMarket sets isResolved BEFORE the oracle
    ///         interaction (CEI order). After resolution, a second call correctly
    ///         reverts with AlreadyResolved — proves the state is set pre-interaction.
    function test_ResolveMarket_CEI_StateSetBeforeInteraction() public {
        oracle.setResolution(id, true);
        vm.warp(endTime + 1);
        market.resolveMarket(id);
        IMarketFacet.MarketView memory m = market.getMarket(id);
        assertTrue(m.isResolved, "isResolved set");
        assertTrue(m.outcome, "outcome correct");
        assertGt(m.resolvedAt, 0, "resolvedAt set");

        // Second call immediately reverts — proves isResolved was already true
        vm.expectRevert(IMarketFacet.Market_AlreadyResolved.selector);
        market.resolveMarket(id);
    }
}
