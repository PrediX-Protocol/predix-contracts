// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import {IMarketFacet} from "@predix/shared/interfaces/IMarketFacet.sol";
import {Modules} from "@predix/shared/constants/Modules.sol";
import {ManualOracle} from "@predix/oracle/adapters/ManualOracle.sol";

import {MarketFixture} from "../utils/MarketFixture.sol";

/// @notice Reproduce-first lock for sc-audit findings U15-01/02 (bd keyti-esar, Low): a compromised
///         PAUSER can pause the MARKET module and block `resolveMarket` (pause-gated), transitively
///         freezing winner redemption (`redeem` needs `isResolved`). The finding is LOW, not High,
///         precisely BECAUSE the freeze is recoverable: `emergencyResolve` (OPERATOR) and
///         `enableRefundMode` (ADMIN) both bypass the pause guard, so user exits are always restorable.
///         These tests demonstrate BOTH the freeze and the two escapes.
contract Audit_U15_PauserFreezeEscape is MarketFixture {
    uint256 internal constant AMT = 1_000e6;
    uint256 internal constant EMERGENCY_DELAY = 7 days;

    ManualOracle internal mo;
    address internal oracleAdmin = makeAddr("oracleAdmin");
    address internal reporter = makeAddr("reporter");

    function setUp() public override {
        super.setUp();
        mo = new ManualOracle(oracleAdmin, address(diamond));
        bytes32 reporterRole = mo.REPORTER_ROLE();
        vm.prank(oracleAdmin);
        mo.grantRole(reporterRole, reporter);
        vm.prank(admin);
        market.approveOracle(address(mo));
    }

    /// @dev U15-01: paused MARKET blocks resolveMarket even when the oracle answered, so the winner
    ///      cannot redeem (market stuck unresolved).
    function test_U15_PausedMarket_BlocksResolution_FreezesRedeem() public {
        uint256 endTime = block.timestamp + 1 days;
        vm.prank(alice);
        uint256 id = market.createMarket("Q", endTime, address(mo));
        _split(bob, id, AMT);

        vm.warp(endTime + 1);
        vm.prank(reporter);
        mo.report(id, true); // oracle has the answer

        vm.prank(admin);
        pausable.pauseModule(Modules.MARKET); // compromised PAUSER

        vm.expectRevert(); // resolveMarket is pause-gated
        market.resolveMarket(id);

        vm.prank(bob);
        vm.expectRevert(IMarketFacet.Market_NotResolved.selector); // winner cannot exit
        market.redeem(id);
    }

    /// @dev Escape A: OPERATOR emergencyResolve has no pause gate -> resolution + redeem restored.
    function test_U15_OperatorEmergencyBypassesPause_RestoresExit() public {
        uint256 endTime = block.timestamp + 1 days;
        vm.prank(alice);
        uint256 id = market.createMarket("Q", endTime, address(mo));
        _split(bob, id, AMT);

        vm.prank(admin);
        pausable.pauseModule(Modules.MARKET);

        vm.warp(endTime + EMERGENCY_DELAY + 1);
        vm.prank(admin);
        market.emergencyResolve(id, true); // bypasses pause

        uint256 before = usdc.balanceOf(bob);
        vm.prank(bob);
        assertEq(market.redeem(id), AMT, "winner exits despite paused MARKET");
        assertEq(usdc.balanceOf(bob) - before, AMT);
    }

    /// @dev Escape B: ADMIN enableRefundMode has no pause gate -> refund exit restored.
    function test_U15_AdminRefundModeBypassesPause_RestoresExit() public {
        uint256 endTime = block.timestamp + 1 days;
        vm.prank(alice);
        uint256 id = market.createMarket("Q", endTime, address(mo));
        _split(bob, id, AMT);

        vm.warp(endTime + 1);
        vm.prank(admin);
        pausable.pauseModule(Modules.MARKET);

        vm.prank(admin);
        market.enableRefundMode(id); // bypasses pause (oracle unreported -> stall recovery)

        uint256 before = usdc.balanceOf(bob);
        vm.prank(bob);
        assertEq(market.refund(id, AMT, AMT), AMT, "refund exit despite paused MARKET");
        assertEq(usdc.balanceOf(bob) - before, AMT);
    }
}
