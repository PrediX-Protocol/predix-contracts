// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {IMarketFacet} from "@predix/shared/interfaces/IMarketFacet.sol";
import {Roles} from "@predix/shared/constants/Roles.sol";

import {MarketFixture} from "../utils/MarketFixture.sol";

/// @notice Repro for FINAL-H05: `emergencyResolve` must defer to an oracle
///         that has since produced an answer. Pre-fix, operator could
///         force an arbitrary outcome even when the oracle was alive, as
///         long as the 7-day emergency delay had elapsed.
contract FinalH05_EmergencyResolveOracleCheck is MarketFixture {
    uint256 internal id;
    uint256 internal endTime;

    function setUp() public override {
        super.setUp();
        endTime = block.timestamp + 7 days;
        id = _createMarket(endTime);
        vm.prank(admin);
        accessControl.grantRole(Roles.OPERATOR_ROLE, alice);
    }

    function test_Revert_EmergencyResolve_OracleAlreadyResolved() public {
        // After endTime + 7d elapse, the oracle publishes YES. Operator must
        // NOT be able to override to NO.
        vm.warp(endTime + 7 days + 1);
        oracle.setResolution(id, true);

        vm.expectRevert(IMarketFacet.Market_OracleResolvedUseResolve.selector);
        vm.prank(alice);
        market.emergencyResolve(id, false);
    }

    function test_EmergencyResolve_StillWorks_WhenOracleSilent() public {
        vm.warp(endTime + 7 days + 1);
        // Oracle never reported — operator bypass is the intended path.
        vm.prank(alice);
        market.emergencyResolve(id, false);
        assertTrue(market.getMarket(id).isResolved);
        assertFalse(market.getMarket(id).outcome);
    }
}
