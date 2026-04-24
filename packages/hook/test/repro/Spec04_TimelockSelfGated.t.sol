// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {HookMiner} from "@uniswap/v4-periphery/src/utils/HookMiner.sol";

import {PrediXHookV2} from "../../src/hooks/PrediXHookV2.sol";
import {PrediXHookProxyV2} from "../../src/proxy/PrediXHookProxyV2.sol";
import {IPrediXHookProxy} from "../../src/interfaces/IPrediXHookProxy.sol";

import {MockDiamond} from "../utils/MockDiamond.sol";

/// @notice Repro for FINAL-M06 + SPEC-04 + SPEC-05 — the three proxy-timelock
///         fixes shipped together because they share the same bytecode
///         region and depend on each other.
///
///         FINAL-M06: `_MIN_TIMELOCK` 24h → 48h so the proxy floor matches
///         the diamond / external Timelock governance cadence.
///
///         SPEC-04: `setTimelockDuration` single-step replaced by a
///         propose/execute/cancel flow self-gated by the CURRENT timelock.
///         A compromised admin can no longer instant-shrink the delay it
///         is supposed to be constrained by.
///
///         SPEC-05: monotonic increase only. Proposed duration must be
///         strictly greater than the current value — admin can raise the
///         delay, never lower or no-op.
contract Spec04_TimelockSelfGated is Test {
    address internal constant POOL_MANAGER = address(0xCAFE);
    address internal constant USDC = address(0x10000);

    uint160 internal constant FLAGS = uint160(
        Hooks.BEFORE_INITIALIZE_FLAG | Hooks.BEFORE_ADD_LIQUIDITY_FLAG | Hooks.BEFORE_REMOVE_LIQUIDITY_FLAG
            | Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_SWAP_FLAG | Hooks.BEFORE_DONATE_FLAG
    );

    PrediXHookV2 internal impl;
    MockDiamond internal diamond;
    PrediXHookProxyV2 internal proxy;

    address internal proxyAdmin = makeAddr("proxyAdmin");
    address internal hookAdmin = makeAddr("hookAdmin");
    address internal rando = makeAddr("rando");

    function setUp() public {
        diamond = new MockDiamond();
        impl = new PrediXHookV2(IPoolManager(POOL_MANAGER), address(0xC0FFEE), 0x800000, int24(60));

        bytes memory ctorArgs =
            abi.encode(IPoolManager(POOL_MANAGER), address(impl), proxyAdmin, hookAdmin, address(diamond), USDC);
        (address expected, bytes32 salt) =
            HookMiner.find(address(this), FLAGS, type(PrediXHookProxyV2).creationCode, ctorArgs);
        proxy = new PrediXHookProxyV2{salt: salt}(
            IPoolManager(POOL_MANAGER), address(impl), proxyAdmin, hookAdmin, address(diamond), USDC
        );
        require(address(proxy) == expected, "Spec04 setup: mined address mismatch");
    }

    // ----------------------------------------------------------------
    // FINAL-M06 — minimum 48h floor
    // ----------------------------------------------------------------

    function test_FinalM06_ProposeBelow48h_Reverts() public {
        vm.prank(proxyAdmin);
        vm.expectRevert(IPrediXHookProxy.HookProxy_TimelockTooShort.selector);
        proxy.proposeTimelockDuration(47 hours + 59 minutes);
    }

    function test_FinalM06_ProposeExactly48h_StillReverts_BecauseMonotonic() public {
        // Constructor seeded `_DEFAULT_TIMELOCK = 48h`, so proposing exactly
        // 48h is now blocked by the SPEC-05 monotonic guard, not the
        // FINAL-M06 floor. This lock confirms the two checks stack in the
        // expected order — a later refactor that relaxes monotonic but keeps
        // the floor would change this to `TimelockTooShort` via an equality
        // test, a meaningful signal.
        vm.prank(proxyAdmin);
        vm.expectRevert(IPrediXHookProxy.HookProxy_TimelockCannotDecrease.selector);
        proxy.proposeTimelockDuration(48 hours);
    }

    function test_FinalM06_ProposeAbove48h_Success() public {
        vm.prank(proxyAdmin);
        proxy.proposeTimelockDuration(72 hours);
        (uint256 pending,) = proxy.pendingTimelockDuration();
        assertEq(pending, 72 hours);
    }

    // ----------------------------------------------------------------
    // SPEC-04 — propose / execute / cancel flow (self-gated)
    // ----------------------------------------------------------------

    function test_Spec04_ProposeSelfGated_UsesCurrentTimelock() public {
        // Current timelock is the constructor default (48h). `readyAt` must
        // be anchored to CURRENT timelock, not `_MIN_TIMELOCK` (which is
        // also 48h here, but the two sources are semantically distinct and
        // will diverge once admin raises the duration above the floor).
        vm.prank(proxyAdmin);
        proxy.proposeTimelockDuration(72 hours);

        (uint256 pending, uint256 readyAt) = proxy.pendingTimelockDuration();
        assertEq(pending, 72 hours);
        assertEq(readyAt, block.timestamp + 48 hours, "readyAt = now + current (48h)");
    }

    function test_Spec04_ExecuteBeforeDelay_Reverts() public {
        vm.prank(proxyAdmin);
        proxy.proposeTimelockDuration(72 hours);

        // 1 second before readyAt.
        vm.warp(block.timestamp + 48 hours - 1);

        vm.prank(proxyAdmin);
        vm.expectRevert(IPrediXHookProxy.HookProxy_TimelockDelayNotElapsed.selector);
        proxy.executeTimelockDuration();
    }

    function test_Spec04_ExecuteAfterDelay_Success() public {
        vm.prank(proxyAdmin);
        proxy.proposeTimelockDuration(72 hours);

        vm.warp(block.timestamp + 48 hours + 1);

        vm.prank(proxyAdmin);
        proxy.executeTimelockDuration();

        assertEq(proxy.timelockDuration(), 72 hours);
        (uint256 pending, uint256 readyAt) = proxy.pendingTimelockDuration();
        assertEq(pending, 0);
        assertEq(readyAt, 0);
    }

    function test_Spec04_Cancel_ClearsState_AllowsRepropose() public {
        vm.prank(proxyAdmin);
        proxy.proposeTimelockDuration(72 hours);

        vm.prank(proxyAdmin);
        proxy.cancelTimelockDuration();

        (uint256 pending, uint256 readyAt) = proxy.pendingTimelockDuration();
        assertEq(pending, 0);
        assertEq(readyAt, 0);

        // Re-propose after cancel — fresh timer.
        vm.warp(block.timestamp + 1 hours);
        vm.prank(proxyAdmin);
        proxy.proposeTimelockDuration(96 hours);
        (, uint256 readyAtAfter) = proxy.pendingTimelockDuration();
        assertEq(readyAtAfter, block.timestamp + 48 hours);
    }

    function test_Spec04_NoPendingExecute_Reverts() public {
        vm.prank(proxyAdmin);
        vm.expectRevert(IPrediXHookProxy.HookProxy_NoPendingTimelockChange.selector);
        proxy.executeTimelockDuration();

        vm.prank(proxyAdmin);
        vm.expectRevert(IPrediXHookProxy.HookProxy_NoPendingTimelockChange.selector);
        proxy.cancelTimelockDuration();
    }

    function test_Spec04_OnlyAdmin_CanProposeExecuteCancel() public {
        vm.prank(rando);
        vm.expectRevert(IPrediXHookProxy.HookProxy_OnlyAdmin.selector);
        proxy.proposeTimelockDuration(72 hours);

        vm.prank(rando);
        vm.expectRevert(IPrediXHookProxy.HookProxy_OnlyAdmin.selector);
        proxy.executeTimelockDuration();

        vm.prank(rando);
        vm.expectRevert(IPrediXHookProxy.HookProxy_OnlyAdmin.selector);
        proxy.cancelTimelockDuration();
    }

    function test_Spec04_SelfGated_UsesNewTimelockAfterRaise() public {
        // Raise the timelock once so CURRENT > _MIN_TIMELOCK.
        vm.prank(proxyAdmin);
        proxy.proposeTimelockDuration(72 hours);
        vm.warp(block.timestamp + 48 hours + 1);
        vm.prank(proxyAdmin);
        proxy.executeTimelockDuration();
        assertEq(proxy.timelockDuration(), 72 hours);

        // A second raise must now anchor readyAt to the NEW 72h, not the
        // 48h floor — proving self-gating tracks the current value.
        uint256 t = block.timestamp;
        vm.prank(proxyAdmin);
        proxy.proposeTimelockDuration(96 hours);
        (, uint256 readyAt) = proxy.pendingTimelockDuration();
        assertEq(readyAt, t + 72 hours, "readyAt tracks CURRENT (72h), not _MIN_TIMELOCK");
    }

    // ----------------------------------------------------------------
    // SPEC-05 — monotonic (strictly greater)
    // ----------------------------------------------------------------

    function test_Spec05_ProposeDurationBelowCurrent_Reverts() public {
        // Raise to 72h so "below current" has meaningful room between
        // _MIN_TIMELOCK (48h) and the current value (72h).
        vm.prank(proxyAdmin);
        proxy.proposeTimelockDuration(72 hours);
        vm.warp(block.timestamp + 48 hours + 1);
        vm.prank(proxyAdmin);
        proxy.executeTimelockDuration();

        // 60h is >= _MIN_TIMELOCK yet < current (72h) → monotonic revert.
        vm.prank(proxyAdmin);
        vm.expectRevert(IPrediXHookProxy.HookProxy_TimelockCannotDecrease.selector);
        proxy.proposeTimelockDuration(60 hours);
    }

    function test_Spec05_ProposeDurationEqualsCurrent_Reverts() public {
        // Default current = 48h. Equal-value proposal is rejected as no-op.
        vm.prank(proxyAdmin);
        vm.expectRevert(IPrediXHookProxy.HookProxy_TimelockCannotDecrease.selector);
        proxy.proposeTimelockDuration(48 hours);
    }

    function test_Spec05_ProposeDurationAboveCurrent_Success() public {
        vm.prank(proxyAdmin);
        proxy.proposeTimelockDuration(72 hours);
        (uint256 pending,) = proxy.pendingTimelockDuration();
        assertEq(pending, 72 hours);
    }
}
