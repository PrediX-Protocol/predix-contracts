// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Test, stdError} from "forge-std/Test.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {HookMiner} from "@uniswap/v4-periphery/src/utils/HookMiner.sol";

import {PrediXHookV2} from "../../src/hooks/PrediXHookV2.sol";
import {PrediXHookProxyV2} from "../../src/proxy/PrediXHookProxyV2.sol";

import {MockDiamond} from "../utils/MockDiamond.sol";

/// @notice A14 audit repro — admin compromise can permanently brick the
///         proxy upgrade governance by raising `timelockDuration` near
///         `type(uint256).max`. Combined with P3 monotonic guard the
///         duration cannot be lowered, so all subsequent `proposeUpgrade`
///         and `proposeTimelockDuration` calls revert with arithmetic
///         overflow on `block.timestamp + current`.
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

    function test_A14_NearMaxTimelockBricksUpgradeFlow() public {
        // Admin proposes a near-max timelock, executes after delay.
        uint256 nearMax = type(uint256).max - 1 hours;
        vm.prank(proxyAdmin);
        proxy.proposeTimelockDuration(nearMax);

        vm.warp(block.timestamp + 48 hours + 1);
        vm.prank(proxyAdmin);
        proxy.executeTimelockDuration();
        assertEq(proxy.timelockDuration(), nearMax, "near-max applied");

        // proposeUpgrade now overflows on `block.timestamp + current`.
        PrediXHookV2 newImpl = new PrediXHookV2(IPoolManager(POOL_MANAGER), address(0xC0FFEE), 0x800000, int24(60));
        vm.prank(proxyAdmin);
        vm.expectRevert(stdError.arithmeticError);
        proxy.proposeUpgrade(address(newImpl));

        // proposeTimelockDuration also bricked (cannot lower per monotonic;
        // any value >= current overflows on readyAt computation).
        vm.prank(proxyAdmin);
        vm.expectRevert(stdError.arithmeticError);
        proxy.proposeTimelockDuration(nearMax + 1);
    }
}
