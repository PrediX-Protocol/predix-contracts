// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Test, stdError} from "forge-std/Test.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {HookMiner} from "@uniswap/v4-periphery/src/utils/HookMiner.sol";

import {PrediXHookV2} from "../../src/hooks/PrediXHookV2.sol";
import {PrediXHookProxyV2} from "../../src/proxy/PrediXHookProxyV2.sol";
import {IPrediXHookProxy} from "../../src/interfaces/IPrediXHookProxy.sol";

import {MockDiamond} from "../utils/MockDiamond.sol";

/// @notice A14 audit lock — H-02 fix locked in: `proposeTimelockDuration`
///         is bounded above by `_MAX_TIMELOCK` (30 days). The pre-fix attack
///         (raise timelock near `type(uint256).max` → permanent overflow on
///         `block.timestamp + current` → upgrade governance bricked) is now
///         rejected at propose-time. Future regression that drops the
///         upper-bound guard will trip this test.
contract A14Repro is Test {
    address constant POOL_MANAGER = address(0xCAFE);
    address constant USDC = address(0x10000);
    uint160 constant FLAGS = uint160(
        Hooks.BEFORE_INITIALIZE_FLAG | Hooks.BEFORE_ADD_LIQUIDITY_FLAG | Hooks.BEFORE_REMOVE_LIQUIDITY_FLAG
            | Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_SWAP_FLAG | Hooks.BEFORE_DONATE_FLAG
    );

    PrediXHookProxyV2 internal proxy;
    address internal proxyAdmin = makeAddr("proxyAdmin");
    address internal hookAdmin = makeAddr("hookAdmin");

    function setUp() public {
        MockDiamond diamond = new MockDiamond();
        PrediXHookV2 impl = new PrediXHookV2(IPoolManager(POOL_MANAGER), address(0xC0FFEE), 0x800000, int24(60));
        bytes memory ctorArgs =
            abi.encode(IPoolManager(POOL_MANAGER), address(impl), proxyAdmin, hookAdmin, address(diamond), USDC);
        (address expected, bytes32 salt) =
            HookMiner.find(address(this), FLAGS, type(PrediXHookProxyV2).creationCode, ctorArgs);
        proxy = new PrediXHookProxyV2{salt: salt}(
            IPoolManager(POOL_MANAGER), address(impl), proxyAdmin, hookAdmin, address(diamond), USDC
        );
        require(address(proxy) == expected, "addr mismatch");
    }

    function test_A14_NearMaxRejected_AtPropose() public {
        // Pre-fix attack: propose near-max → execute → permanent brick.
        // Post-fix: propose itself reverts before any state change.
        vm.prank(proxyAdmin);
        vm.expectRevert(IPrediXHookProxy.HookProxy_TimelockTooLong.selector);
        proxy.proposeTimelockDuration(type(uint256).max - 1 hours);
    }

    function test_A14_BoundaryAt30DaysAccepted() public {
        // Exactly 30 days IS within the bound.
        vm.prank(proxyAdmin);
        proxy.proposeTimelockDuration(30 days);
        (uint256 pending,) = proxy.pendingTimelockDuration();
        assertEq(pending, 30 days, "30d ceiling accepted");
    }

    function test_A14_BoundaryAbove30DaysRejected() public {
        // 30 days + 1 second is over the cap.
        vm.prank(proxyAdmin);
        vm.expectRevert(IPrediXHookProxy.HookProxy_TimelockTooLong.selector);
        proxy.proposeTimelockDuration(30 days + 1);
    }

    function test_A14_PostExecuteAt30Days_ProposeUpgradeStillWorks() public {
        // After raising to the 30d ceiling, proposeUpgrade must remain
        // functional (block.timestamp + 30d well within uint256).
        vm.prank(proxyAdmin);
        proxy.proposeTimelockDuration(30 days);
        vm.warp(block.timestamp + 48 hours + 1);
        vm.prank(proxyAdmin);
        proxy.executeTimelockDuration();
        assertEq(proxy.timelockDuration(), 30 days, "ceiling applied");

        PrediXHookV2 newImpl = new PrediXHookV2(IPoolManager(POOL_MANAGER), address(0xC0FFEE), 0x800000, int24(60));
        vm.prank(proxyAdmin);
        proxy.proposeUpgrade(address(newImpl));
        // No revert — governance flow still functional at the ceiling.
        assertEq(proxy.upgradeReadyAt(), block.timestamp + 30 days, "upgrade scheduled at ceiling cadence");
    }
}
