// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";

import {IPrediXHook} from "../../src/interfaces/IPrediXHook.sol";

import {MockDiamond} from "../utils/MockDiamond.sol";
import {TestHookHarness} from "../utils/TestHookHarness.sol";

/// @notice Repro for AUDIT-M-03 (Pass 2.1, 2026-04-25):
///
///         The hook's admin rotation (`setAdmin` → `acceptAdmin`) is 2-step
///         but has NO time delay between the two. Every other governance flow
///         in the hook (proposeDiamond, proposeUpgrade, proposeTimelockDuration,
///         proposeTrustedRouter, proposeUnregisterMarketPool) carries a 48 h
///         timelock. Admin rotation is the asymmetric outlier.
///
///         Threat model: a compromised admin key can be rotated to a fresh
///         attacker-controlled key in 2 transactions, racing the legitimate
///         admin's recovery attempt. With a 48 h timelock the legitimate
///         admin would have a recovery window to call `cancelAdminRotation`.
///         Without the timelock, the rotation is final the moment the new
///         admin (the attacker) submits `acceptAdmin`.
///
///         Documented "admin = trusted multisig" assumption is necessary but
///         not sufficient — defense-in-depth principle says critical
///         operations should require BOTH multisig AND timelock. Same applies
///         to the proxy admin (`changeProxyAdmin` / `acceptProxyAdmin` in
///         PrediXHookProxyV2).
///
///         These tests demonstrate the 2-tx-no-delay rotation at HEAD
///         `ce524ba`. After the fix lands (add `ADMIN_ROTATION_DELAY = 48
///         hours` and gate `acceptAdmin` on elapsed time), `BUG_*` tests
///         should be inverted to `Revert_AcceptAdmin_DelayNotElapsed`.
contract Audit_M03_AdminRotationNoTimelock is Test {
    TestHookHarness internal hook;
    MockDiamond internal diamond;

    address internal legitAdmin = makeAddr("legitAdmin");
    address internal compromisedAttacker = makeAddr("attacker");
    address internal usdc = address(0x10000);

    function setUp() public {
        diamond = new MockDiamond();
        hook = new TestHookHarness(IPoolManager(address(0xCAFE)), address(0xC0FFEE));
        hook.initialize(address(diamond), legitAdmin, usdc);
    }

    /// @dev DEMONSTRATES BUG: compromised admin rotates to fresh attacker
    ///      address in TWO transactions, no time delay possible.
    function test_BUG_CompromisedAdmin_RotatesInstantly_NoTimelock() public {
        uint256 t0 = block.timestamp;

        // Tx 1: compromised admin proposes attacker-controlled new admin.
        vm.prank(legitAdmin);
        hook.setAdmin(compromisedAttacker);

        // Tx 2: attacker accepts immediately. NO time delay enforced.
        vm.prank(compromisedAttacker);
        hook.acceptAdmin();

        // Confirmed: admin rotated within the same block (or any next tx).
        assertEq(hook.admin(), compromisedAttacker, "admin rotated without delay");
        assertEq(block.timestamp, t0, "no time elapsed");

        // Legitimate admin can no longer call admin functions.
        vm.prank(legitAdmin);
        vm.expectRevert(IPrediXHook.Hook_OnlyAdmin.selector);
        hook.setPaused(true);
    }

    /// @dev DEMONSTRATES BUG: rotation completes in single block. Compare
    ///      against the 48h delay enforced by every other propose flow:
    ///      proposeDiamond, proposeTrustedRouter, proposeUnregisterMarketPool,
    ///      and the proxy-side proposeUpgrade / proposeTimelockDuration.
    function test_BUG_RotationInSingleBlock_AsymmetricVsOtherProposeFlows() public {
        // Inspect the diamond rotation flow has a 48h delay constant
        assertEq(hook.DIAMOND_ROTATION_DELAY(), 48 hours, "diamond uses 48h");
        assertEq(hook.TRUSTED_ROUTER_DELAY(), 48 hours, "trusted-router uses 48h");
        assertEq(hook.MARKET_UNREGISTER_DELAY(), 48 hours, "unregister uses 48h");

        // No equivalent ADMIN_ROTATION_DELAY exists. Verify by completing
        // an admin rotation in zero seconds.
        vm.prank(legitAdmin);
        hook.setAdmin(compromisedAttacker);
        // No vm.warp — same block.
        vm.prank(compromisedAttacker);
        hook.acceptAdmin();
        assertEq(hook.admin(), compromisedAttacker);
    }

    /// @dev DEMONSTRATES BUG: legitimate admin's recovery attempt races
    ///      against attacker's accept and loses if attacker mines first.
    function test_BUG_LegitimateAdminCannotRecover_AfterAcceptLanded() public {
        // Compromised admin proposes attacker.
        vm.prank(legitAdmin);
        hook.setAdmin(compromisedAttacker);

        // Attacker accepts. Rotation complete.
        vm.prank(compromisedAttacker);
        hook.acceptAdmin();

        // Legitimate admin (with their original key) tries to recover by
        // proposing themselves back. Reverts because they're no longer admin.
        vm.prank(legitAdmin);
        vm.expectRevert(IPrediXHook.Hook_OnlyAdmin.selector);
        hook.setAdmin(legitAdmin);
    }

    /// @dev Sanity: confirm the diamond / unregister / trusted-router flows
    ///      DO have the 48h delay (proves admin rotation is the outlier).
    function test_Sanity_DiamondRotation_RequiresDelay() public {
        address newDiamond = address(new MockDiamond());
        vm.prank(legitAdmin);
        hook.proposeDiamond(newDiamond);

        // Try to execute immediately — must revert.
        vm.prank(legitAdmin);
        vm.expectRevert(IPrediXHook.Hook_DiamondDelayNotElapsed.selector);
        hook.executeDiamondRotation();

        // Warp 48h, succeeds.
        vm.warp(block.timestamp + 48 hours + 1);
        vm.prank(legitAdmin);
        hook.executeDiamondRotation();
        assertEq(hook.diamond(), newDiamond);
    }

    /// @dev EXPECTED-AFTER-FIX placeholder. After the fix lands, the rotation
    ///      should require:
    ///      1. `setAdmin(newAdmin)` writes pending + proposedAt timestamp
    ///      2. `acceptAdmin()` reverts with `Hook_AdminDelayNotElapsed` if
    ///         block.timestamp < proposedAt + ADMIN_ROTATION_DELAY (48h)
    ///      3. `cancelAdminRotation()` exists for legitimate-admin recovery
    function test_DESIRED_AdminRotationRequires48hDelay_PendingFix() public pure {
        return;
    }
}
