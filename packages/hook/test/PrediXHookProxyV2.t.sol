// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {HookMiner} from "@uniswap/v4-periphery/src/utils/HookMiner.sol";

import {PrediXHookV2} from "../src/hooks/PrediXHookV2.sol";
import {PrediXHookProxyV2} from "../src/proxy/PrediXHookProxyV2.sol";
import {IPrediXHook} from "../src/interfaces/IPrediXHook.sol";
import {IPrediXHookProxy} from "../src/interfaces/IPrediXHookProxy.sol";

import {MockDiamond} from "./utils/MockDiamond.sol";

/// @dev Test stub: any call (including the proxy's atomic `initialize` delegatecall)
///      reverts with empty return data. Used to verify `HookProxy_InitReverted`.
contract EmptyRevertStub {
    fallback() external {
        assembly {
            revert(0, 0)
        }
    }
}

contract PrediXHookProxyV2Test is Test {
    address internal constant POOL_MANAGER = address(0xCAFE);
    address internal constant USDC = address(0x10000);

    /// @dev Permission flags for the proxy address. Mirrors `getHookPermissions`:
    ///      beforeInitialize | beforeAddLiquidity | beforeRemoveLiquidity
    ///      | beforeSwap | afterSwap | beforeDonate.
    uint160 internal constant FLAGS = uint160(
        Hooks.BEFORE_INITIALIZE_FLAG | Hooks.BEFORE_ADD_LIQUIDITY_FLAG | Hooks.BEFORE_REMOVE_LIQUIDITY_FLAG
            | Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_SWAP_FLAG | Hooks.BEFORE_DONATE_FLAG
    );

    PrediXHookV2 internal impl;
    MockDiamond internal diamond;
    PrediXHookProxyV2 internal proxy;

    address internal proxyAdmin = makeAddr("proxyAdmin");
    address internal hookAdmin = makeAddr("hookAdmin");
    address internal otherAdmin = makeAddr("otherAdmin");

    function setUp() public {
        diamond = new MockDiamond();
        impl = new PrediXHookV2(IPoolManager(POOL_MANAGER), address(0xC0FFEE), 0x800000, int24(60));
        proxy = _deployProxy(address(impl), proxyAdmin, hookAdmin, address(diamond), USDC);
    }

    function _deployProxy(address impl_, address pAdmin, address hAdmin, address diamond_, address quote)
        internal
        returns (PrediXHookProxyV2)
    {
        bytes memory ctorArgs = abi.encode(IPoolManager(POOL_MANAGER), impl_, pAdmin, hAdmin, diamond_, quote);
        (address expected, bytes32 salt) =
            HookMiner.find(address(this), FLAGS, type(PrediXHookProxyV2).creationCode, ctorArgs);
        PrediXHookProxyV2 p =
            new PrediXHookProxyV2{salt: salt}(IPoolManager(POOL_MANAGER), impl_, pAdmin, hAdmin, diamond_, quote);
        require(address(p) == expected, "PrediXHookProxyV2Test: mined address mismatch");
        return p;
    }

    // -----------------------------------------------------------------
    // Constructor — atomic init (C2)
    // -----------------------------------------------------------------

    function test_Constructor_BindsImplementationAndAdmin() public view {
        assertEq(proxy.implementation(), address(impl));
        assertEq(proxy.proxyAdmin(), proxyAdmin);
        assertEq(proxy.timelockDuration(), 48 hours);
        assertEq(proxy.upgradeReadyAt(), 0);
        assertEq(proxy.pendingImplementation(), address(0));
        assertEq(proxy.pendingProxyAdmin(), address(0));
    }

    function test_Constructor_AtomicInit_PopulatesImplState() public view {
        // Hook state was set by the delegatecall inside the constructor.
        assertEq(IPrediXHook(address(proxy)).diamond(), address(diamond));
        assertEq(IPrediXHook(address(proxy)).admin(), hookAdmin);
        assertEq(IPrediXHook(address(proxy)).quoteToken(), USDC);
        assertFalse(IPrediXHook(address(proxy)).paused());
    }

    function test_Revert_Reinitialize_FrontRunBlocked() public {
        // Any post-deploy `initialize` call MUST revert because the constructor
        // already set `_initialized = true` atomically.
        vm.expectRevert(IPrediXHook.Hook_AlreadyInitialized.selector);
        IPrediXHook(address(proxy)).initialize(address(diamond), hookAdmin, USDC);
    }

    function test_Revert_Constructor_ZeroImpl() public {
        bytes memory ctorArgs =
            abi.encode(IPoolManager(POOL_MANAGER), address(0), proxyAdmin, hookAdmin, address(diamond), USDC);
        (, bytes32 salt) = HookMiner.find(address(this), FLAGS, type(PrediXHookProxyV2).creationCode, ctorArgs);
        vm.expectRevert(IPrediXHookProxy.HookProxy_ZeroAddress.selector);
        new PrediXHookProxyV2{salt: salt}(
            IPoolManager(POOL_MANAGER), address(0), proxyAdmin, hookAdmin, address(diamond), USDC
        );
    }

    function test_Revert_Constructor_ImplNotAContract() public {
        address eoa = makeAddr("eoa");
        bytes memory ctorArgs =
            abi.encode(IPoolManager(POOL_MANAGER), eoa, proxyAdmin, hookAdmin, address(diamond), USDC);
        (, bytes32 salt) = HookMiner.find(address(this), FLAGS, type(PrediXHookProxyV2).creationCode, ctorArgs);
        vm.expectRevert(IPrediXHookProxy.HookProxy_NotAContract.selector);
        new PrediXHookProxyV2{salt: salt}(
            IPoolManager(POOL_MANAGER), eoa, proxyAdmin, hookAdmin, address(diamond), USDC
        );
    }

    function test_Revert_Constructor_InitProxyArgsCaughtBeforeDelegate() public {
        // The proxy constructor validates ALL its address args BEFORE the atomic
        // delegatecall, so a zero quoteToken trips `HookProxy_ZeroAddress` (not the
        // implementation's `Hook_ZeroAddress`). This documents the order of checks.
        bytes memory ctorArgs =
            abi.encode(IPoolManager(POOL_MANAGER), address(impl), proxyAdmin, hookAdmin, address(diamond), address(0));
        (, bytes32 salt) = HookMiner.find(address(this), FLAGS, type(PrediXHookProxyV2).creationCode, ctorArgs);
        vm.expectRevert(IPrediXHookProxy.HookProxy_ZeroAddress.selector);
        new PrediXHookProxyV2{salt: salt}(
            IPoolManager(POOL_MANAGER), address(impl), proxyAdmin, hookAdmin, address(diamond), address(0)
        );
    }

    function test_Revert_Constructor_InitRevertBubbles() public {
        // Deploy a stub impl whose `initialize` selector reverts with EMPTY data.
        // The proxy constructor must catch it and surface `HookProxy_InitReverted`.
        EmptyRevertStub stub = new EmptyRevertStub();
        bytes memory ctorArgs =
            abi.encode(IPoolManager(POOL_MANAGER), address(stub), proxyAdmin, hookAdmin, address(diamond), USDC);
        (, bytes32 salt) = HookMiner.find(address(this), FLAGS, type(PrediXHookProxyV2).creationCode, ctorArgs);
        vm.expectRevert(IPrediXHookProxy.HookProxy_InitReverted.selector);
        new PrediXHookProxyV2{salt: salt}(
            IPoolManager(POOL_MANAGER), address(stub), proxyAdmin, hookAdmin, address(diamond), USDC
        );
    }

    // -----------------------------------------------------------------
    // Upgrade timelock flow
    // -----------------------------------------------------------------

    function test_ProposeUpgrade_StoresPendingAndReadyAt() public {
        PrediXHookV2 newImpl = new PrediXHookV2(IPoolManager(POOL_MANAGER), address(0xC0FFEE), 0x800000, int24(60));
        vm.prank(proxyAdmin);
        proxy.proposeUpgrade(address(newImpl));
        assertEq(proxy.pendingImplementation(), address(newImpl));
        assertEq(proxy.upgradeReadyAt(), block.timestamp + 48 hours);
    }

    function test_Revert_ProposeUpgrade_NotAdmin() public {
        PrediXHookV2 newImpl = new PrediXHookV2(IPoolManager(POOL_MANAGER), address(0xC0FFEE), 0x800000, int24(60));
        vm.expectRevert(IPrediXHookProxy.HookProxy_OnlyAdmin.selector);
        proxy.proposeUpgrade(address(newImpl));
    }

    function test_Revert_ProposeUpgrade_ZeroAddress() public {
        vm.prank(proxyAdmin);
        vm.expectRevert(IPrediXHookProxy.HookProxy_ZeroAddress.selector);
        proxy.proposeUpgrade(address(0));
    }

    function test_Revert_ProposeUpgrade_NotAContract() public {
        vm.prank(proxyAdmin);
        vm.expectRevert(IPrediXHookProxy.HookProxy_NotAContract.selector);
        proxy.proposeUpgrade(makeAddr("eoa"));
    }

    function test_ExecuteUpgrade_AfterTimelockSucceeds() public {
        PrediXHookV2 newImpl = new PrediXHookV2(IPoolManager(POOL_MANAGER), address(0xC0FFEE), 0x800000, int24(60));
        vm.prank(proxyAdmin);
        proxy.proposeUpgrade(address(newImpl));
        vm.warp(block.timestamp + 48 hours);
        vm.prank(proxyAdmin);
        proxy.executeUpgrade();
        assertEq(proxy.implementation(), address(newImpl));
        assertEq(proxy.pendingImplementation(), address(0));
        assertEq(proxy.upgradeReadyAt(), 0);
    }

    function test_Revert_ExecuteUpgrade_TooEarly() public {
        PrediXHookV2 newImpl = new PrediXHookV2(IPoolManager(POOL_MANAGER), address(0xC0FFEE), 0x800000, int24(60));
        vm.prank(proxyAdmin);
        proxy.proposeUpgrade(address(newImpl));
        vm.prank(proxyAdmin);
        vm.expectRevert(IPrediXHookProxy.HookProxy_UpgradeNotReady.selector);
        proxy.executeUpgrade();
    }

    function test_Revert_ExecuteUpgrade_NoPending() public {
        vm.prank(proxyAdmin);
        vm.expectRevert(IPrediXHookProxy.HookProxy_NoPendingUpgrade.selector);
        proxy.executeUpgrade();
    }

    function test_CancelUpgrade_ClearsPending() public {
        PrediXHookV2 newImpl = new PrediXHookV2(IPoolManager(POOL_MANAGER), address(0xC0FFEE), 0x800000, int24(60));
        vm.prank(proxyAdmin);
        proxy.proposeUpgrade(address(newImpl));
        vm.prank(proxyAdmin);
        proxy.cancelUpgrade();
        assertEq(proxy.pendingImplementation(), address(0));
        assertEq(proxy.upgradeReadyAt(), 0);
    }

    function test_Revert_CancelUpgrade_NoPending() public {
        vm.prank(proxyAdmin);
        vm.expectRevert(IPrediXHookProxy.HookProxy_NoPendingUpgrade.selector);
        proxy.cancelUpgrade();
    }

    function test_Revert_ExecuteUpgrade_AfterCancel() public {
        PrediXHookV2 newImpl = new PrediXHookV2(IPoolManager(POOL_MANAGER), address(0xC0FFEE), 0x800000, int24(60));
        vm.prank(proxyAdmin);
        proxy.proposeUpgrade(address(newImpl));
        vm.prank(proxyAdmin);
        proxy.cancelUpgrade();
        vm.warp(block.timestamp + 48 hours);
        vm.prank(proxyAdmin);
        vm.expectRevert(IPrediXHookProxy.HookProxy_NoPendingUpgrade.selector);
        proxy.executeUpgrade();
    }

    // setTimelockDuration single-step removed by SPEC-04. Propose/execute flow
    // (plus FINAL-M06 48h floor, SPEC-05 monotonic guard) is exercised by
    // `test/repro/Spec04_TimelockSelfGated.t.sol`.

    // -----------------------------------------------------------------
    // Two-step proxy admin rotation
    // -----------------------------------------------------------------

    function test_ChangeProxyAdmin_TwoStep() public {
        vm.prank(proxyAdmin);
        proxy.changeProxyAdmin(otherAdmin);
        assertEq(proxy.pendingProxyAdmin(), otherAdmin);
        assertEq(proxy.proxyAdmin(), proxyAdmin);

        // M-03 (Pass 2.1): 48h timelock now applies to proxy admin rotation.
        vm.warp(block.timestamp + proxy.ADMIN_ROTATION_DELAY() + 1);
        vm.prank(otherAdmin);
        proxy.acceptProxyAdmin();
        assertEq(proxy.proxyAdmin(), otherAdmin);
        assertEq(proxy.pendingProxyAdmin(), address(0));
    }

    function test_Revert_AcceptProxyAdmin_WrongCaller() public {
        vm.prank(proxyAdmin);
        proxy.changeProxyAdmin(otherAdmin);
        vm.prank(makeAddr("intruder"));
        vm.expectRevert(IPrediXHookProxy.HookProxy_OnlyPendingAdmin.selector);
        proxy.acceptProxyAdmin();
    }

    function test_Revert_ChangeProxyAdmin_NotAdmin() public {
        vm.expectRevert(IPrediXHookProxy.HookProxy_OnlyAdmin.selector);
        proxy.changeProxyAdmin(otherAdmin);
    }

    function test_Revert_ChangeProxyAdmin_Zero() public {
        vm.prank(proxyAdmin);
        vm.expectRevert(IPrediXHookProxy.HookProxy_ZeroAddress.selector);
        proxy.changeProxyAdmin(address(0));
    }

    // -----------------------------------------------------------------
    // Fallback delegation — admin functions on impl flow through
    // -----------------------------------------------------------------

    function test_Fallback_DelegatesAdminCalls() public {
        // Hook admin (NOT proxy admin) calls setPaused via fallback → impl runs
        // in proxy storage context.
        vm.prank(hookAdmin);
        IPrediXHook(address(proxy)).setPaused(true);
        assertTrue(IPrediXHook(address(proxy)).paused());
    }

    function test_Fallback_BubblesRevert() public {
        // Calling setPaused as the wrong account should bubble Hook_OnlyAdmin
        // through the fallback delegation.
        vm.expectRevert(IPrediXHook.Hook_OnlyAdmin.selector);
        IPrediXHook(address(proxy)).setPaused(true);
    }

    // -----------------------------------------------------------------
    // ETH rejection
    // -----------------------------------------------------------------

    function test_Revert_RejectsEthViaFallback() public {
        vm.deal(address(this), 1 ether);
        (bool ok,) = address(proxy).call{value: 1 ether}("");
        assertFalse(ok);
        assertEq(address(proxy).balance, 0);
    }
}
