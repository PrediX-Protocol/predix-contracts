// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import {IMarketFacet} from "@predix/shared/interfaces/IMarketFacet.sol";
import {ManualOracle} from "@predix/oracle/adapters/ManualOracle.sol";

import {MarketFixture} from "../utils/MarketFixture.sol";

/// @notice Reproduce-first lock for sc-audit finding U1-CENT-01 (bd keyti-846w, Medium):
///         `MarketFacet.emergencyResolve` lets an OPERATOR write an ARBITRARY binary outcome after
///         endTime + 7d, with no oracle agreement and no second on-chain signer; a holder of the
///         operator-chosen leg then redeems at par. Breaks NO conservation invariant, so the
///         invariant suite cannot catch it — this test documents the trust assumption explicitly.
contract Audit_846w_EmergencyResolveArbitrary is MarketFixture {
    uint256 internal constant AMT = 1_000e6;
    uint256 internal constant EMERGENCY_DELAY = 7 days;

    ManualOracle internal mo;

    function setUp() public override {
        super.setUp();
        // A fresh, never-reported ManualOracle: isResolved()==false, so emergencyResolve proceeds
        // down the OracleUnready branch — the genuine "oracle stalled" scenario the path is for.
        mo = new ManualOracle(makeAddr("oracleAdmin"), address(diamond));
        vm.prank(admin);
        market.approveOracle(address(mo));
    }

    /// @dev The operator picks the outcome out of thin air; it is written verbatim and a holder of
    ///      that leg drains at par. `admin` holds OPERATOR_ROLE via DiamondInit.
    function test_846w_OperatorWritesArbitraryOutcome_ChosenLegDrainsAtPar() public {
        uint256 endTime = block.timestamp + 1 days;
        vm.prank(alice);
        uint256 id = market.createMarket("Will X happen?", endTime, address(mo));

        // bob will end up holding the operator-chosen winning leg; alice is an honest counterparty.
        _split(bob, id, AMT);
        _split(alice, id, AMT);

        // Oracle never answers. Pass the 7-day emergency cooldown.
        vm.warp(endTime + EMERGENCY_DELAY + 1);

        // OPERATOR resolves to YES with zero oracle input — the value is operator-chosen.
        vm.prank(admin);
        market.emergencyResolve(id, true);
        assertTrue(market.getMarket(id).outcome, "operator wrote an arbitrary YES, no oracle agreement");

        // bob redeems the operator-blessed YES at full par.
        uint256 before = usdc.balanceOf(bob);
        vm.prank(bob);
        uint256 payout = market.redeem(id);
        assertEq(payout, AMT, "operator-chosen-leg holder redeems full par");
        assertEq(usdc.balanceOf(bob) - before, AMT);
    }

    /// @dev The only on-chain guards are OPERATOR_ROLE + the 7-day delay. One second early reverts.
    function test_846w_EmergencyBlockedBeforeSevenDayWindow() public {
        uint256 endTime = block.timestamp + 1 days;
        vm.prank(alice);
        uint256 id = market.createMarket("Will X happen?", endTime, address(mo));
        _split(bob, id, AMT);

        vm.warp(endTime + EMERGENCY_DELAY - 1);
        vm.prank(admin);
        vm.expectRevert(IMarketFacet.Market_TooEarlyForEmergency.selector);
        market.emergencyResolve(id, true);
    }

    /// @dev A non-operator cannot reach the path at all.
    function test_846w_NonOperatorCannotEmergencyResolve() public {
        uint256 endTime = block.timestamp + 1 days;
        vm.prank(alice);
        uint256 id = market.createMarket("Will X happen?", endTime, address(mo));
        vm.warp(endTime + EMERGENCY_DELAY + 1);
        vm.prank(bob);
        vm.expectRevert();
        market.emergencyResolve(id, true);
    }
}
