// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {HookMiner} from "@uniswap/v4-periphery/src/utils/HookMiner.sol";

import {IPrediXHook} from "../../src/interfaces/IPrediXHook.sol";
import {IPrediXHookProxy} from "../../src/interfaces/IPrediXHookProxy.sol";
import {PrediXHookV2} from "../../src/hooks/PrediXHookV2.sol";
import {PrediXHookProxyV2} from "../../src/proxy/PrediXHookProxyV2.sol";

import {MockDiamond} from "../utils/MockDiamond.sol";
import {TestHookHarness} from "../utils/TestHookHarness.sol";

/// @notice M-01 audit fix lock — `Hook_AlreadyPendingDiamondChange`,
///         `HookProxy_AlreadyPendingUpgrade`, and
///         `HookProxy_AlreadyPendingTimelockChange` reject re-propose-while-
///         pending in the three flows that previously silently overwrote
///         pending state. Mirrors H4's `proposeTrustedRouter` guard so all
///         four propose flows in the codebase share one threat model: admin
///         must explicitly `cancel*` before re-proposing, and the audit
///         trail records every intent change.
contract M01_AlreadyPendingGuards is Test {
    address constant POOL_MANAGER = address(0xCAFE);
    address constant USDC = address(0x10000);

    uint160 constant FLAGS = uint160(
        Hooks.BEFORE_INITIALIZE_FLAG | Hooks.BEFORE_ADD_LIQUIDITY_FLAG | Hooks.BEFORE_REMOVE_LIQUIDITY_FLAG
            | Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_SWAP_FLAG | Hooks.BEFORE_DONATE_FLAG
    );

    TestHookHarness internal hook;
    MockDiamond internal hookDiamond;

    PrediXHookProxyV2 internal proxy;
    address internal proxyAdmin = makeAddr("proxyAdmin");
    address internal hookAdmin = makeAddr("hookAdmin");

    function setUp() public {
        hookDiamond = new MockDiamond();
        hook = new TestHookHarness(IPoolManager(POOL_MANAGER), address(0xC0FFEE));
        hook.initialize(address(hookDiamond), hookAdmin, USDC);

        // Spin up a proxy for the proxy-side guards. Compute the proxy's
        // diamond address ONCE before mining so the constructorArgs hash
        // matches between the mining call and the actual deploy.
        PrediXHookV2 impl = new PrediXHookV2(IPoolManager(POOL_MANAGER), address(0xC0FFEE), 0x800000, int24(60));
        MockDiamond proxyDiamond = new MockDiamond();
        bytes memory ctorArgs =
            abi.encode(IPoolManager(POOL_MANAGER), address(impl), proxyAdmin, hookAdmin, address(proxyDiamond), USDC);
        (address expected, bytes32 salt) =
            HookMiner.find(address(this), FLAGS, type(PrediXHookProxyV2).creationCode, ctorArgs);
        proxy = new PrediXHookProxyV2{salt: salt}(
            IPoolManager(POOL_MANAGER), address(impl), proxyAdmin, hookAdmin, address(proxyDiamond), USDC
        );
        require(address(proxy) == expected, "proxy addr mismatch");
    }

    // ---------- proposeDiamond ----------

    function test_M01_ProposeDiamond_RePropose_Reverts() public {
        address d1 = address(new MockDiamond());
        address d2 = address(new MockDiamond());

        vm.prank(hookAdmin);
        hook.proposeDiamond(d1);

        vm.prank(hookAdmin);
        vm.expectRevert(IPrediXHook.Hook_AlreadyPendingDiamondChange.selector);
        hook.proposeDiamond(d2);
    }

    function test_M01_ProposeDiamond_CancelThenRePropose_Succeeds() public {
        address d1 = address(new MockDiamond());
        address d2 = address(new MockDiamond());

        vm.prank(hookAdmin);
        hook.proposeDiamond(d1);

        vm.prank(hookAdmin);
        hook.cancelDiamondRotation();

        vm.prank(hookAdmin);
        hook.proposeDiamond(d2);
        (address pending,) = hook.pendingDiamond();
        assertEq(pending, d2, "fresh proposal recorded after cancel");
    }

    // ---------- proposeUpgrade ----------

    function test_M01_ProposeUpgrade_RePropose_Reverts() public {
        PrediXHookV2 impl1 = new PrediXHookV2(IPoolManager(POOL_MANAGER), address(0xC0FFEE), 0x800000, int24(60));
        PrediXHookV2 impl2 = new PrediXHookV2(IPoolManager(POOL_MANAGER), address(0xC0FFEE), 0x800000, int24(60));

        vm.prank(proxyAdmin);
        proxy.proposeUpgrade(address(impl1));

        vm.prank(proxyAdmin);
        vm.expectRevert(IPrediXHookProxy.HookProxy_AlreadyPendingUpgrade.selector);
        proxy.proposeUpgrade(address(impl2));
    }

    function test_M01_ProposeUpgrade_CancelThenRePropose_Succeeds() public {
        PrediXHookV2 impl1 = new PrediXHookV2(IPoolManager(POOL_MANAGER), address(0xC0FFEE), 0x800000, int24(60));
        PrediXHookV2 impl2 = new PrediXHookV2(IPoolManager(POOL_MANAGER), address(0xC0FFEE), 0x800000, int24(60));

        vm.prank(proxyAdmin);
        proxy.proposeUpgrade(address(impl1));

        vm.prank(proxyAdmin);
        proxy.cancelUpgrade();

        vm.prank(proxyAdmin);
        proxy.proposeUpgrade(address(impl2));
        assertEq(proxy.pendingImplementation(), address(impl2), "fresh proposal after cancel");
    }

    // ---------- proposeTimelockDuration ----------

    function test_M01_ProposeTimelockDuration_RePropose_Reverts() public {
        vm.prank(proxyAdmin);
        proxy.proposeTimelockDuration(72 hours);

        vm.prank(proxyAdmin);
        vm.expectRevert(IPrediXHookProxy.HookProxy_AlreadyPendingTimelockChange.selector);
        proxy.proposeTimelockDuration(96 hours);
    }

    function test_M01_ProposeTimelockDuration_CancelThenRePropose_Succeeds() public {
        vm.prank(proxyAdmin);
        proxy.proposeTimelockDuration(72 hours);

        vm.prank(proxyAdmin);
        proxy.cancelTimelockDuration();

        vm.prank(proxyAdmin);
        proxy.proposeTimelockDuration(96 hours);
        (uint256 pending,) = proxy.pendingTimelockDuration();
        assertEq(pending, 96 hours, "fresh proposal after cancel");
    }

    // ---------- proposeUnregisterMarketPool (H-01 + M-01 follow-up) ----------

    function test_M01_ProposeUnregister_RePropose_Reverts() public {
        // Register a market on hook so unregister has a target.
        address yes1 = address(0x10000 - 1);
        address noToken = makeAddr("no");
        uint256 marketId = 7;
        hookDiamond.setMarket(marketId, yes1, noToken, block.timestamp + 30 days, false, false);

        // Build a canonical PoolKey for hook.registerMarketPool.
        // (Same shape as TestHookHarness's defaults: fee 0x800000, tickSpacing 60.)
        // Inline to avoid pulling more imports.
        // forgefmt: disable-next-item
        hook.registerMarketPool(
            marketId,
            _canonicalKey(yes1)
        );

        vm.prank(hookAdmin);
        hook.proposeUnregisterMarketPool(marketId);

        vm.prank(hookAdmin);
        vm.expectRevert(IPrediXHook.Hook_AlreadyPendingUnregister.selector);
        hook.proposeUnregisterMarketPool(marketId);
    }

    function _canonicalKey(address yesToken) internal view returns (PoolKey memory) {
        return PoolKey({
            currency0: Currency.wrap(yesToken),
            currency1: Currency.wrap(USDC),
            fee: 0x800000,
            tickSpacing: int24(60),
            hooks: hook
        });
    }

    // ---------- Cross-flow consistency ----------

    function test_M01_AllFiveProposeFlowsHaveGuards() public pure {
        // Symbol-level lock: each guard error must be declared in the matching
        // interface. Failure here = a future refactor dropped one of the five
        // guards without updating the interface — drift signal. The
        // interfaces are imported above, so a successful selector-access
        // compilation proves each symbol exists.
        bytes4 a = IPrediXHook.Hook_AlreadyPendingRouter.selector; // H4 (existing)
        bytes4 b = IPrediXHook.Hook_AlreadyPendingDiamondChange.selector; // M-01
        bytes4 c = IPrediXHookProxy.HookProxy_AlreadyPendingUpgrade.selector; // M-01
        bytes4 d = IPrediXHookProxy.HookProxy_AlreadyPendingTimelockChange.selector; // M-01
        bytes4 e = IPrediXHook.Hook_AlreadyPendingUnregister.selector; // M-01 follow-up (H-01 flow)

        // Pairwise distinct — keccak256 collision would be catastrophic but
        // also functionally impossible; this is mostly a typo / shadow-import
        // catch.
        assertTrue(a != b && a != c && a != d && a != e, "selector a unique");
        assertTrue(b != c && b != d && b != e, "selector b unique");
        assertTrue(c != d && c != e, "selector c unique");
        assertTrue(d != e, "selector d unique");
    }
}
