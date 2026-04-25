// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {ModifyLiquidityParams, SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";

import {IPrediXHook} from "../../src/interfaces/IPrediXHook.sol";

import {MockDiamond} from "../utils/MockDiamond.sol";
import {TestHookHarness} from "../utils/TestHookHarness.sol";

/// @notice M-02 audit fix lock — `_beforeSwap`, `_beforeAddLiquidity`, and
///         `_beforeDonate` now revert with `Hook_StaleBinding` when the
///         binding's recorded yesToken position no longer matches the
///         diamond's current marketView for the bound marketId. This is
///         defence-in-depth against H-01's stale-binding scenario: even if
///         a diamond rotation lands on a diamond with a different yesToken
///         for the same marketId, callbacks fail loudly instead of routing
///         swaps under the wrong-token assumption.
contract M02_StaleBindingDetection is Test {
    TestHookHarness internal hook;
    MockDiamond internal oldDiamond;
    MockDiamond internal newDiamond;

    address internal constant POOL_MANAGER = address(0xCAFE);
    address internal admin = makeAddr("admin");
    address internal usdc = address(0x10000);
    address internal yesOriginal = address(0x10000 - 1);
    address internal yesAttacker = address(0x10000 - 2);
    address internal noToken = makeAddr("no");

    uint256 internal constant MARKET_ID = 1;

    function setUp() public {
        oldDiamond = new MockDiamond();
        newDiamond = new MockDiamond();
        hook = new TestHookHarness(IPoolManager(POOL_MANAGER), address(0xC0FFEE));
        hook.initialize(address(oldDiamond), admin, usdc);

        oldDiamond.setMarket(MARKET_ID, yesOriginal, noToken, block.timestamp + 30 days, false, false);

        PoolKey memory key = _key(yesOriginal);
        hook.registerMarketPool(MARKET_ID, key);

        // Make trader trusted to satisfy the FINAL-H06 identity gate.
        vm.prank(admin);
        hook.setTrustedRouter(address(this), true);
        vm.prank(admin);
        hook.completeBootstrap();
    }

    function _key(address yesToken) internal view returns (PoolKey memory) {
        return PoolKey({
            currency0: Currency.wrap(yesToken),
            currency1: Currency.wrap(usdc),
            fee: 0x800000,
            tickSpacing: int24(60),
            hooks: hook
        });
    }

    function _rotateToMaliciousDiamond() internal {
        // Rotate to new diamond where MARKET_ID resolves to attackerYes
        // (different from the binding's recorded yesOriginal).
        newDiamond.setMarket(MARKET_ID, yesAttacker, noToken, block.timestamp + 30 days, false, false);

        vm.prank(admin);
        hook.proposeDiamond(address(newDiamond));
        vm.warp(block.timestamp + hook.DIAMOND_ROTATION_DELAY() + 1);
        vm.prank(admin);
        hook.executeDiamondRotation();
    }

    function test_M02_BeforeSwap_StaleBinding_Reverts() public {
        _rotateToMaliciousDiamond();

        PoolKey memory key = _key(yesOriginal);
        SwapParams memory params = SwapParams({zeroForOne: true, amountSpecified: -1e6, sqrtPriceLimitX96: 0});

        // Pre-commit identity so the FINAL-H06 gate is satisfied; the failure
        // we want to surface is the stale-binding check, not the identity check.
        hook.commitSwapIdentity(address(this), key.toId());

        vm.prank(POOL_MANAGER);
        vm.expectRevert(IPrediXHook.Hook_StaleBinding.selector);
        hook.beforeSwap(address(this), key, params, "");
    }

    function test_M02_BeforeAddLiquidity_StaleBinding_Reverts() public {
        _rotateToMaliciousDiamond();

        PoolKey memory key = _key(yesOriginal);
        ModifyLiquidityParams memory params =
            ModifyLiquidityParams({tickLower: -60, tickUpper: 60, liquidityDelta: 1e18, salt: bytes32(0)});

        vm.prank(POOL_MANAGER);
        vm.expectRevert(IPrediXHook.Hook_StaleBinding.selector);
        hook.beforeAddLiquidity(address(this), key, params, "");
    }

    function test_M02_BeforeDonate_StaleBinding_Reverts() public {
        _rotateToMaliciousDiamond();

        PoolKey memory key = _key(yesOriginal);

        vm.prank(POOL_MANAGER);
        vm.expectRevert(IPrediXHook.Hook_StaleBinding.selector);
        hook.beforeDonate(address(this), key, 1e6, 0, "");
    }

    function test_M02_HappyPath_MatchingYesToken_StillWorks() public {
        // Sanity: when the yesToken matches (legitimate compatible rotation
        // to a diamond with identical marketId map), all three callbacks
        // proceed as normal.
        newDiamond.setMarket(MARKET_ID, yesOriginal, noToken, block.timestamp + 30 days, false, false);
        vm.prank(admin);
        hook.proposeDiamond(address(newDiamond));
        vm.warp(block.timestamp + hook.DIAMOND_ROTATION_DELAY() + 1);
        vm.prank(admin);
        hook.executeDiamondRotation();

        PoolKey memory key = _key(yesOriginal);

        ModifyLiquidityParams memory addParams =
            ModifyLiquidityParams({tickLower: -60, tickUpper: 60, liquidityDelta: 1e18, salt: bytes32(0)});
        vm.prank(POOL_MANAGER);
        bytes4 sel = hook.beforeAddLiquidity(address(this), key, addParams, "");
        assertEq(sel, hook.beforeAddLiquidity.selector);

        vm.prank(POOL_MANAGER);
        sel = hook.beforeDonate(address(this), key, 1e6, 0, "");
        assertEq(sel, hook.beforeDonate.selector);
    }

    function test_M02_AfterUnregisterAndReRegister_NoStaleRevert() public {
        // Full recovery path: rotate → unregister stale binding → re-register
        // under new diamond's correct yesToken → callbacks succeed.
        _rotateToMaliciousDiamond(); // sets MARKET_ID -> yesAttacker on newDiamond

        // Unregister stale binding via H-01 flow.
        vm.prank(admin);
        hook.proposeUnregisterMarketPool(MARKET_ID);
        vm.warp(block.timestamp + hook.MARKET_UNREGISTER_DELAY() + 1);
        vm.prank(admin);
        hook.executeUnregisterMarketPool(MARKET_ID);

        // Re-register under new diamond with the new yesToken.
        PoolKey memory newKey = _key(yesAttacker);
        hook.registerMarketPool(MARKET_ID, newKey);

        ModifyLiquidityParams memory addParams =
            ModifyLiquidityParams({tickLower: -60, tickUpper: 60, liquidityDelta: 1e18, salt: bytes32(0)});
        vm.prank(POOL_MANAGER);
        bytes4 sel = hook.beforeAddLiquidity(address(this), newKey, addParams, "");
        assertEq(sel, hook.beforeAddLiquidity.selector, "post-recovery callbacks succeed");
    }
}
