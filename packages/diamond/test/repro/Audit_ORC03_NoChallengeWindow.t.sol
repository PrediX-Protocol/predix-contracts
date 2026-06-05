// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import {IMarketFacet} from "@predix/shared/interfaces/IMarketFacet.sol";
import {ManualOracle} from "@predix/oracle/adapters/ManualOracle.sol";

import {MarketFixture} from "../utils/MarketFixture.sol";

/// @notice Reproduce-first lock for sc-audit finding ORC-03 (bd keyti-esiv, HIGH):
///         The LIVE ManualOracle (0x8EDD…) has `challengeDelay == 0` (verified on-chain, chain 130).
///         With a zero delay a report is consumable in the SAME block, so the admin
///         revoke/reopen "challenge window" is inert and a single REPORTER can finalize an
///         arbitrary (wrong) outcome that a holder of that leg immediately drains at par.
///         Breaks no conservation invariant, so the invariant suite cannot catch it.
contract Audit_ORC03_NoChallengeWindow is MarketFixture {
    uint256 internal constant AMT = 1_000e6;

    ManualOracle internal mo;
    address internal oracleAdmin = makeAddr("oracleAdmin");
    address internal reporter = makeAddr("reporter");

    function setUp() public override {
        super.setUp();
        // Deploy EXACTLY as live: challengeDelay defaults to 0 (the constructor sets no delay).
        mo = new ManualOracle(oracleAdmin, address(diamond));
        bytes32 reporterRole = mo.REPORTER_ROLE(); // resolve before prank (avoid nested-call prank gotcha)
        vm.prank(oracleAdmin);
        mo.grantRole(reporterRole, reporter);
        vm.prank(admin);
        market.approveOracle(address(mo));
    }

    /// @dev THE FINDING. challengeDelay==0 -> report finalizes in the same block/timestamp it lands,
    ///      leaving the admin ZERO window to revoke/reopen a bad report before the diamond consumes it.
    function test_ORC03_LiveConfig_ReportFinalizesSameBlock_NoAdminWindow() public {
        // Matches live mainnet: the deployed oracle reports finalize instantly.
        assertEq(mo.challengeDelay(), 0, "repro models the live config: challengeDelay==0");

        uint256 endTime = block.timestamp + 1 days;
        vm.prank(alice);
        uint256 id = market.createMarket("Will X happen?", endTime, address(mo));
        _split(bob, id, AMT); // bob holds YES+NO
        _split(alice, id, AMT);

        vm.warp(endTime + 1);

        // Single reporter publishes an outcome (here: YES). No second signer, no oracle agreement.
        uint256 reportTs = block.timestamp;
        vm.prank(reporter);
        mo.report(id, true);

        // ZERO challenge window: the report is consumable in the SAME timestamp it was made.
        assertEq(block.timestamp, reportTs, "no time elapsed since the report");
        assertTrue(
            mo.isResolved(id),
            "challengeDelay==0 -> finalized same block; admin has NO window to revoke/reopen a bad report"
        );

        // Permissionless consumption + redeem of the reporter-chosen winning leg at par.
        market.resolveMarket(id);
        assertTrue(market.getMarket(id).outcome, "reporter-chosen outcome consumed with no challenge window");

        uint256 before = usdc.balanceOf(bob);
        vm.prank(bob);
        assertEq(market.redeem(id), AMT, "holder of reporter-chosen leg drains at par");
        assertEq(usdc.balanceOf(bob) - before, AMT);
    }

    /// @dev THE FIX. With challengeDelay>0 the report is NOT consumable in the same block; the diamond
    ///      refuses to resolve until finalization, and the admin can reopen a bad report within the window.
    function test_ORC03_Fix_NonZeroChallengeDelay_RestoresAdminWindow() public {
        uint256 delay = 1 hours;
        vm.prank(oracleAdmin);
        mo.setChallengeDelay(delay);
        assertEq(mo.challengeDelay(), delay, "fix applied");

        uint256 endTime = block.timestamp + 1 days;
        vm.prank(alice);
        uint256 id = market.createMarket("Will X happen?", endTime, address(mo));
        _split(bob, id, AMT);
        vm.warp(endTime + 1);

        // Reporter publishes a (bad) outcome.
        vm.prank(reporter);
        mo.report(id, true);

        // NOT yet consumable — the challenge window is open and the diamond refuses to resolve.
        assertFalse(mo.isResolved(id), "challenge window open -> not finalized");
        vm.expectRevert(IMarketFacet.Market_OracleNotResolved.selector);
        market.resolveMarket(id);

        // Admin catches it and reopens within the window; reporter republishes the corrected outcome.
        vm.prank(oracleAdmin);
        mo.reopenReport(id);
        vm.prank(reporter);
        mo.report(id, false);

        vm.warp(block.timestamp + delay);
        assertTrue(mo.isResolved(id), "finalized after the window");
        market.resolveMarket(id);
        assertFalse(market.getMarket(id).outcome, "corrected outcome consumed - the window did its job");
    }
}
