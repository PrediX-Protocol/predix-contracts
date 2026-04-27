// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";

import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {BalanceDelta, toBalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {SwapParams, ModifyLiquidityParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {LPFeeLibrary} from "@uniswap/v4-core/src/libraries/LPFeeLibrary.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";

import {PrediXHookV2} from "../src/hooks/PrediXHookV2.sol";
import {IPrediXHook} from "../src/interfaces/IPrediXHook.sol";
import {FeeTiers} from "../src/constants/FeeTiers.sol";

import {MockDiamond} from "./utils/MockDiamond.sol";
import {TestHookHarness} from "./utils/TestHookHarness.sol";

contract PrediXHookV2Test is Test {
    using PoolIdLibrary for PoolKey;

    TestHookHarness internal hook;
    MockDiamond internal diamond;

    address internal constant POOL_MANAGER = address(0xCAFE);
    address internal admin = makeAddr("admin");
    address internal trader = makeAddr("trader");
    address internal router = makeAddr("router");
    address internal usdc = address(0x10000);
    address internal yesLow = address(0x10000 - 1); // < usdc → YES is currency0
    address internal yesHigh = address(0x10000 + 1); // > usdc → YES is currency1
    address internal noToken = makeAddr("no");

    uint256 internal constant MARKET_ID = 1;
    uint256 internal endTime;

    PoolKey internal key0; // YES = currency0
    PoolKey internal key1; // YES = currency1
    PoolId internal poolId0;
    PoolId internal poolId1;

    SwapParams internal swapZeroForOne = SwapParams({zeroForOne: true, amountSpecified: -1e6, sqrtPriceLimitX96: 0});
    SwapParams internal swapOneForZero = SwapParams({zeroForOne: false, amountSpecified: -1e6, sqrtPriceLimitX96: 0});

    function setUp() public {
        diamond = new MockDiamond();
        hook = new TestHookHarness(IPoolManager(POOL_MANAGER), address(0xC0FFEE));
        hook.initialize(address(diamond), admin, usdc);

        endTime = block.timestamp + 30 days;
        diamond.setMarket(MARKET_ID, yesLow, noToken, endTime, false, false);
        diamond.setMarket(MARKET_ID + 1, yesHigh, noToken, endTime, false, false);

        key0 = PoolKey({
            currency0: Currency.wrap(yesLow),
            currency1: Currency.wrap(usdc),
            fee: LPFeeLibrary.DYNAMIC_FEE_FLAG,
            tickSpacing: 60,
            hooks: IHooks(address(hook))
        });
        key1 = PoolKey({
            currency0: Currency.wrap(usdc),
            currency1: Currency.wrap(yesHigh),
            fee: LPFeeLibrary.DYNAMIC_FEE_FLAG,
            tickSpacing: 60,
            hooks: IHooks(address(hook))
        });
        poolId0 = key0.toId();
        poolId1 = key1.toId();

        vm.prank(address(diamond));
        hook.registerMarketPool(MARKET_ID, key0);
        vm.prank(address(diamond));
        hook.registerMarketPool(MARKET_ID + 1, key1);

        // FINAL-H06: after the `_resolveIdentity` hard-gate, every caller that `_beforeSwap`
        // or `_afterSwap` sees MUST be a trusted router with a same-tx commit. The test
        // convention is that `trader` self-swaps as a trusted router; individual tests that
        // cross pool boundaries call `_commitTraderSelf(poolId)` at the top to refresh the
        // per-pool transient slot inside the test's tx frame.
        vm.prank(admin);
        hook.setTrustedRouter(trader, true);
    }

    /// @dev Commits `trader` as its own identity for `pid`. Transient storage resets each
    ///      test function, so every affected test must call this inside its own frame.
    function _commitTraderSelf(PoolId pid) internal {
        vm.prank(trader);
        hook.commitSwapIdentity(trader, pid);
    }

    // -----------------------------------------------------------------
    // initialize
    // -----------------------------------------------------------------

    function test_Initialize_HappyPath_SetsState() public view {
        assertEq(hook.diamond(), address(diamond));
        assertEq(hook.admin(), admin);
        assertEq(hook.quoteToken(), usdc);
        assertFalse(hook.paused());
    }

    function test_Revert_Initialize_TwiceReverts() public {
        vm.expectRevert(IPrediXHook.Hook_AlreadyInitialized.selector);
        hook.initialize(address(diamond), admin, usdc);
    }

    /// @notice F10 regression — bare implementation contract cannot be initialized
    ///         because the constructor sets _initialized = true on the impl storage.
    function test_Revert_InitializeImplementationDirectly() public {
        // Deploy a bare PrediXHookV2 (not via proxy, not via TestHookHarness which resets _initialized).
        PrediXHookV2 bareImpl = new PrediXHookV2(IPoolManager(POOL_MANAGER), address(0xC0FFEE), 0x800000, int24(60));
        vm.expectRevert(IPrediXHook.Hook_AlreadyInitialized.selector);
        bareImpl.initialize(address(diamond), admin, usdc);
    }

    function test_Revert_Initialize_ZeroDiamond() public {
        TestHookHarness h = new TestHookHarness(IPoolManager(POOL_MANAGER), address(0xC0FFEE));
        vm.expectRevert(IPrediXHook.Hook_ZeroAddress.selector);
        h.initialize(address(0), admin, usdc);
    }

    function test_Revert_Initialize_ZeroAdmin() public {
        TestHookHarness h = new TestHookHarness(IPoolManager(POOL_MANAGER), address(0xC0FFEE));
        vm.expectRevert(IPrediXHook.Hook_ZeroAddress.selector);
        h.initialize(address(diamond), address(0), usdc);
    }

    function test_Revert_Initialize_ZeroQuote() public {
        TestHookHarness h = new TestHookHarness(IPoolManager(POOL_MANAGER), address(0xC0FFEE));
        vm.expectRevert(IPrediXHook.Hook_ZeroAddress.selector);
        h.initialize(address(diamond), admin, address(0));
    }

    // -----------------------------------------------------------------
    // Admin functions
    // -----------------------------------------------------------------

    // setDiamond single-step removed by F-X-02. Replacement propose/execute/
    // cancel flow is exercised by `test/repro/FXX02_SetDiamond2Step.t.sol`.

    function test_SetAdmin_TwoStep_RotatesAdmin() public {
        address newAdmin = makeAddr("newAdmin");
        vm.prank(admin);
        hook.setAdmin(newAdmin);
        // FINAL-H09: propose leg must not rotate yet.
        assertEq(hook.admin(), admin);
        // M-03 (Pass 2.1): admin rotation now carries a 48h timelock.
        vm.warp(block.timestamp + hook.ADMIN_ROTATION_DELAY() + 1);
        vm.prank(newAdmin);
        hook.acceptAdmin();
        assertEq(hook.admin(), newAdmin);
        // Old admin no longer authorised
        vm.prank(admin);
        vm.expectRevert(IPrediXHook.Hook_OnlyAdmin.selector);
        hook.setPaused(true);
    }

    function test_SetPaused_TogglesFlag() public {
        vm.prank(admin);
        hook.setPaused(true);
        assertTrue(hook.paused());
        vm.prank(admin);
        hook.setPaused(false);
        assertFalse(hook.paused());
    }

    function test_Revert_SetPaused_NotAdmin() public {
        vm.expectRevert(IPrediXHook.Hook_OnlyAdmin.selector);
        hook.setPaused(true);
    }

    function test_SetTrustedRouter_TogglesFlag() public {
        vm.prank(admin);
        hook.setTrustedRouter(router, true);
        assertTrue(hook.isTrustedRouter(router));
        vm.prank(admin);
        hook.setTrustedRouter(router, false);
        assertFalse(hook.isTrustedRouter(router));
    }

    function test_Revert_SetTrustedRouter_NotAdmin() public {
        vm.expectRevert(IPrediXHook.Hook_OnlyAdmin.selector);
        hook.setTrustedRouter(router, true);
    }

    function test_Revert_SetTrustedRouter_Zero() public {
        vm.prank(admin);
        vm.expectRevert(IPrediXHook.Hook_ZeroAddress.selector);
        hook.setTrustedRouter(address(0), true);
    }

    // -----------------------------------------------------------------
    // registerMarketPool
    // -----------------------------------------------------------------

    function test_RegisterMarketPool_YesCurrency0() public view {
        assertEq(hook.poolMarketId(poolId0), MARKET_ID);
    }

    function test_RegisterMarketPool_YesCurrency1() public view {
        assertEq(hook.poolMarketId(poolId1), MARKET_ID + 1);
    }

    function test_RegisterMarketPool_PermissionlessFromAnyAddress() public {
        // Fresh market + fresh YES token so the canonical PoolKey produces a
        // distinct PoolId from the two pre-registered in setUp. NEW-M4 fixes
        // fee + tickSpacing at canonical values, so PoolId uniqueness must come
        // from a different currency pair, not a different tickSpacing.
        uint256 newMarketId = 42;
        address newYes = address(0x10000 - 2);
        diamond.setMarket(newMarketId, newYes, noToken, endTime, false, false);
        PoolKey memory k = PoolKey({
            currency0: Currency.wrap(newYes),
            currency1: Currency.wrap(usdc),
            fee: LPFeeLibrary.DYNAMIC_FEE_FLAG,
            tickSpacing: 60,
            hooks: IHooks(address(hook))
        });
        PoolId newPoolId = k.toId();

        address randomCaller = makeAddr("randomCaller");
        vm.expectEmit(true, true, false, true);
        emit IPrediXHook.Hook_PoolRegistered(newMarketId, newPoolId, newYes, usdc, true);
        vm.prank(randomCaller);
        hook.registerMarketPool(newMarketId, k);

        assertEq(hook.poolMarketId(newPoolId), newMarketId);
    }

    function test_RegisterMarketPool_PermissionlessFromRouter() public {
        // Same permissionless path, but using a router-shaped caller to document the
        // production deploy flow: the router (or its deploy script) is the expected
        // registrar, not the diamond.
        uint256 newMarketId = 43;
        address newYes = address(0x10000 - 3);
        diamond.setMarket(newMarketId, newYes, noToken, endTime, false, false);
        PoolKey memory k = PoolKey({
            currency0: Currency.wrap(newYes),
            currency1: Currency.wrap(usdc),
            fee: LPFeeLibrary.DYNAMIC_FEE_FLAG,
            tickSpacing: 60,
            hooks: IHooks(address(hook))
        });
        vm.prank(router);
        hook.registerMarketPool(newMarketId, k);
        assertEq(hook.poolMarketId(k.toId()), newMarketId);
    }

    function test_Revert_RegisterMarketPool_AlreadyRegistered() public {
        vm.prank(address(diamond));
        vm.expectRevert(IPrediXHook.Hook_PoolAlreadyRegistered.selector);
        hook.registerMarketPool(MARKET_ID, key0);
    }

    /// @notice F9 regression — same marketId cannot register a second pool.
    function test_Revert_RegisterMarketPool_DuplicateMarket() public {
        // MARKET_ID already has key0 registered in setUp. Try registering a
        // different canonical pool (different YES token → different PoolId)
        // for the same marketId. NEW-M4 locks fee + tickSpacing, so PoolId
        // uniqueness comes from the currency pair.
        address altYes = address(0x10000 - 4);
        PoolKey memory k2 = PoolKey({
            currency0: Currency.wrap(altYes),
            currency1: Currency.wrap(usdc),
            fee: LPFeeLibrary.DYNAMIC_FEE_FLAG,
            tickSpacing: 60,
            hooks: IHooks(address(hook))
        });
        vm.expectRevert(IPrediXHook.Hook_MarketAlreadyHasPool.selector);
        hook.registerMarketPool(MARKET_ID, k2);
    }

    function test_Revert_RegisterMarketPool_UnknownMarket() public {
        // Canonical key targeting a marketId the mock diamond has never seen.
        address unknownYes = address(0x10000 - 5);
        PoolKey memory k = PoolKey({
            currency0: Currency.wrap(unknownYes),
            currency1: Currency.wrap(usdc),
            fee: LPFeeLibrary.DYNAMIC_FEE_FLAG,
            tickSpacing: 60,
            hooks: IHooks(address(hook))
        });
        vm.prank(address(diamond));
        vm.expectRevert(IPrediXHook.Hook_MarketNotFound.selector);
        hook.registerMarketPool(9999, k);
    }

    function test_Revert_RegisterMarketPool_InvalidCurrencies() public {
        // Set up market 7 with `randomYes`. The caller hands in a canonical-
        // shaped key whose currency0 is `bogusYes` (not market 7's YES, and
        // not tied to any existing pool — PoolId is fresh). Canonical check
        // passes, currency check rejects with `Hook_InvalidPoolCurrencies`.
        diamond.setMarket(7, makeAddr("randomYes"), noToken, endTime, false, false);
        address bogusYes = address(0x10000 - 6);
        PoolKey memory k = PoolKey({
            currency0: Currency.wrap(bogusYes),
            currency1: Currency.wrap(usdc),
            fee: LPFeeLibrary.DYNAMIC_FEE_FLAG,
            tickSpacing: 60,
            hooks: IHooks(address(hook))
        });
        vm.prank(address(diamond));
        vm.expectRevert(IPrediXHook.Hook_InvalidPoolCurrencies.selector);
        hook.registerMarketPool(7, k);
    }

    // -----------------------------------------------------------------
    // _beforeInitialize
    // -----------------------------------------------------------------

    function test_BeforeInitialize_HappyPath() public view {
        // FINAL-H11: use the 50¢ midpoint sqrtPriceX96 (yesIs0 → sqrt(0.5) * 2^96).
        // Any value in [475_000, 525_000] pips would do; midpoint is the canonical init.
        uint160 midpoint = 56022770974786143748341366784; // sqrt(0.5) * 2^96, rounded
        bytes4 sel = hook.exposed_beforeInitialize(address(0), key0, midpoint);
        assertEq(sel, IHooks.beforeInitialize.selector);
    }

    function test_Revert_BeforeInitialize_PoolNotRegistered() public {
        PoolKey memory k = key0;
        k.tickSpacing = 999;
        vm.expectRevert(IPrediXHook.Hook_PoolNotRegistered.selector);
        hook.exposed_beforeInitialize(address(0), k, 0);
    }

    function test_Revert_BeforeInitialize_NotDynamicFee() public {
        PoolKey memory k = key0;
        k.fee = 3000; // static
        vm.expectRevert(IPrediXHook.Hook_PoolFeeNotDynamic.selector);
        hook.exposed_beforeInitialize(address(0), k, 0);
    }

    // -----------------------------------------------------------------
    // _beforeAddLiquidity
    // -----------------------------------------------------------------

    ModifyLiquidityParams internal addParams =
        ModifyLiquidityParams({tickLower: -60, tickUpper: 60, liquidityDelta: 1e18, salt: bytes32(0)});

    function test_BeforeAddLiquidity_HappyPath() public view {
        bytes4 sel = hook.exposed_beforeAddLiquidity(trader, key0, addParams, "");
        assertEq(sel, IHooks.beforeAddLiquidity.selector);
    }

    function test_Revert_BeforeAddLiquidity_Resolved() public {
        diamond.setMarket(MARKET_ID, yesLow, noToken, endTime, true, false);
        vm.expectRevert(IPrediXHook.Hook_MarketResolved.selector);
        hook.exposed_beforeAddLiquidity(trader, key0, addParams, "");
    }

    function test_Revert_BeforeAddLiquidity_Expired() public {
        vm.warp(endTime + 1);
        vm.expectRevert(IPrediXHook.Hook_MarketExpired.selector);
        hook.exposed_beforeAddLiquidity(trader, key0, addParams, "");
    }

    function test_Revert_BeforeAddLiquidity_PoolNotRegistered() public {
        PoolKey memory k = key0;
        k.tickSpacing = 1234;
        vm.expectRevert(IPrediXHook.Hook_PoolNotRegistered.selector);
        hook.exposed_beforeAddLiquidity(trader, k, addParams, "");
    }

    // -----------------------------------------------------------------
    // _beforeRemoveLiquidity — exit MUST always work
    // -----------------------------------------------------------------

    function test_BeforeRemoveLiquidity_AllowsResolved() public {
        diamond.setMarket(MARKET_ID, yesLow, noToken, endTime, true, false);
        bytes4 sel = hook.exposed_beforeRemoveLiquidity(trader, key0, addParams, "");
        assertEq(sel, IHooks.beforeRemoveLiquidity.selector);
    }

    function test_BeforeRemoveLiquidity_AllowsExpired() public {
        vm.warp(endTime + 1);
        bytes4 sel = hook.exposed_beforeRemoveLiquidity(trader, key0, addParams, "");
        assertEq(sel, IHooks.beforeRemoveLiquidity.selector);
    }

    function test_BeforeRemoveLiquidity_AllowsPaused() public {
        // Pause at the WRAPPER level — call internal directly since the
        // wrapper for remove-liquidity does not check pause state anyway.
        vm.prank(admin);
        hook.setPaused(true);
        bytes4 sel = hook.exposed_beforeRemoveLiquidity(trader, key0, addParams, "");
        assertEq(sel, IHooks.beforeRemoveLiquidity.selector);
    }

    function test_Revert_BeforeRemoveLiquidity_PoolNotRegistered() public {
        PoolKey memory k = key0;
        k.tickSpacing = 1234;
        vm.expectRevert(IPrediXHook.Hook_PoolNotRegistered.selector);
        hook.exposed_beforeRemoveLiquidity(trader, k, addParams, "");
    }

    // -----------------------------------------------------------------
    // _beforeDonate
    // -----------------------------------------------------------------

    function test_BeforeDonate_HappyPath() public view {
        bytes4 sel = hook.exposed_beforeDonate(trader, key0, 1e6, 1e6, "");
        assertEq(sel, IHooks.beforeDonate.selector);
    }

    function test_Revert_BeforeDonate_Resolved() public {
        diamond.setMarket(MARKET_ID, yesLow, noToken, endTime, true, false);
        vm.expectRevert(IPrediXHook.Hook_MarketResolved.selector);
        hook.exposed_beforeDonate(trader, key0, 0, 0, "");
    }

    // -----------------------------------------------------------------
    // _beforeSwap — anti-sandwich + dynamic fee
    // -----------------------------------------------------------------

    function test_BeforeSwap_HappyPath_ReturnsDynamicFee() public {
        _commitTraderSelf(poolId0);
        (bytes4 sel,, uint24 fee) = hook.exposed_beforeSwap(trader, key0, swapZeroForOne, "");
        assertEq(sel, IHooks.beforeSwap.selector);
        // > 7 days → FEE_NORMAL
        assertEq(fee & ~LPFeeLibrary.OVERRIDE_FEE_FLAG, FeeTiers.FEE_NORMAL);
        assertTrue(fee & LPFeeLibrary.OVERRIDE_FEE_FLAG != 0);
    }

    function test_Revert_BeforeSwap_PoolNotRegistered() public {
        PoolKey memory k = key0;
        k.tickSpacing = 9999;
        vm.expectRevert(IPrediXHook.Hook_PoolNotRegistered.selector);
        hook.exposed_beforeSwap(trader, k, swapZeroForOne, "");
    }

    function test_Revert_BeforeSwap_Resolved() public {
        diamond.setMarket(MARKET_ID, yesLow, noToken, endTime, true, false);
        vm.expectRevert(IPrediXHook.Hook_MarketResolved.selector);
        hook.exposed_beforeSwap(trader, key0, swapZeroForOne, "");
    }

    function test_Revert_BeforeSwap_Expired() public {
        vm.warp(endTime + 1);
        vm.expectRevert(IPrediXHook.Hook_MarketExpired.selector);
        hook.exposed_beforeSwap(trader, key0, swapZeroForOne, "");
    }

    function test_AntiSandwich_SameDirectionSameBlock_Allowed() public {
        _commitTraderSelf(poolId0);
        hook.exposed_beforeSwap(trader, key0, swapZeroForOne, "");
        hook.exposed_beforeSwap(trader, key0, swapZeroForOne, "");
    }

    function test_Revert_AntiSandwich_OppositeDirectionSameBlock() public {
        _commitTraderSelf(poolId0);
        hook.exposed_beforeSwap(trader, key0, swapZeroForOne, "");
        vm.expectRevert(IPrediXHook.Hook_SandwichDetected.selector);
        hook.exposed_beforeSwap(trader, key0, swapOneForZero, "");
    }

    function test_AntiSandwich_OppositeDirectionDifferentBlock_Allowed() public {
        _commitTraderSelf(poolId0);
        hook.exposed_beforeSwap(trader, key0, swapZeroForOne, "");
        vm.roll(block.number + 1);
        hook.exposed_beforeSwap(trader, key0, swapOneForZero, "");
    }

    /// @dev FINAL-H06: a trusted router that swaps without first committing now reverts
    ///      hard with `Hook_MissingRouterCommit`. Pre-fix this silently fell back to the
    ///      router as identity, which made INV-5 advisory.
    function test_Revert_AntiSandwich_RouterNoCommit_HardRejected() public {
        vm.prank(admin);
        hook.setTrustedRouter(router, true);
        vm.expectRevert(IPrediXHook.Hook_MissingRouterCommit.selector);
        hook.exposed_beforeSwap(router, key0, swapZeroForOne, "");
    }

    function test_AntiSandwich_RouterCommittedIdentity_DetectsSandwich() public {
        vm.prank(admin);
        hook.setTrustedRouter(router, true);
        // Router commits trader as identity, then swaps.
        // A second opposite swap (by the same trader) must revert even though
        // msg.sender at the hook is the router both times.
        vm.prank(router);
        hook.commitSwapIdentity(trader, poolId0);
        hook.exposed_beforeSwap(router, key0, swapZeroForOne, "");
        vm.expectRevert(IPrediXHook.Hook_SandwichDetected.selector);
        hook.exposed_beforeSwap(router, key0, swapOneForZero, "");
    }

    function test_DynamicFee_Tier_GreaterThan7Days() public {
        _commitTraderSelf(poolId0);
        // endTime is +30 days → > 7 days → FEE_NORMAL
        (,, uint24 fee) = hook.exposed_beforeSwap(trader, key0, swapZeroForOne, "");
        assertEq(fee & ~LPFeeLibrary.OVERRIDE_FEE_FLAG, FeeTiers.FEE_NORMAL);
    }

    function test_DynamicFee_Tier_Between3And7Days() public {
        _commitTraderSelf(poolId0);
        vm.warp(endTime - 5 days);
        (,, uint24 fee) = hook.exposed_beforeSwap(trader, key0, swapZeroForOne, "");
        assertEq(fee & ~LPFeeLibrary.OVERRIDE_FEE_FLAG, FeeTiers.FEE_MEDIUM);
    }

    function test_DynamicFee_Tier_Between1And3Days() public {
        _commitTraderSelf(poolId0);
        vm.warp(endTime - 2 days);
        (,, uint24 fee) = hook.exposed_beforeSwap(trader, key0, swapZeroForOne, "");
        assertEq(fee & ~LPFeeLibrary.OVERRIDE_FEE_FLAG, FeeTiers.FEE_HIGH);
    }

    function test_DynamicFee_Tier_LessThan1Day() public {
        _commitTraderSelf(poolId0);
        vm.warp(endTime - 12 hours);
        (,, uint24 fee) = hook.exposed_beforeSwap(trader, key0, swapZeroForOne, "");
        assertEq(fee & ~LPFeeLibrary.OVERRIDE_FEE_FLAG, FeeTiers.FEE_VERY_HIGH);
    }

    // -----------------------------------------------------------------
    // Pause behaviour (via wrapper externals — internals do not check)
    // -----------------------------------------------------------------

    function test_Revert_BeforeSwap_Paused_ViaExternal() public {
        vm.prank(admin);
        hook.setPaused(true);
        vm.prank(POOL_MANAGER);
        vm.expectRevert(IPrediXHook.Hook_Paused.selector);
        hook.beforeSwap(trader, key0, swapZeroForOne, "");
    }

    function test_Revert_BeforeAddLiquidity_Paused_ViaExternal() public {
        vm.prank(admin);
        hook.setPaused(true);
        vm.prank(POOL_MANAGER);
        vm.expectRevert(IPrediXHook.Hook_Paused.selector);
        hook.beforeAddLiquidity(trader, key0, addParams, "");
    }

    function test_Revert_BeforeDonate_Paused_ViaExternal() public {
        vm.prank(admin);
        hook.setPaused(true);
        vm.prank(POOL_MANAGER);
        vm.expectRevert(IPrediXHook.Hook_Paused.selector);
        hook.beforeDonate(trader, key0, 0, 0, "");
    }

    function test_BeforeRemoveLiquidity_Paused_StillAllowed_ViaExternal() public {
        vm.prank(admin);
        hook.setPaused(true);
        vm.prank(POOL_MANAGER);
        bytes4 sel = hook.beforeRemoveLiquidity(trader, key0, addParams, "");
        assertEq(sel, IHooks.beforeRemoveLiquidity.selector);
    }

    function test_Revert_External_NotPoolManager() public {
        vm.expectRevert(IPrediXHook.Hook_NotPoolManager.selector);
        hook.beforeSwap(trader, key0, swapZeroForOne, "");
    }

    // -----------------------------------------------------------------
    // commitSwapIdentity (transient storage scoping)
    // -----------------------------------------------------------------

    function test_CommitSwapIdentity_HappyPath() public {
        vm.prank(admin);
        hook.setTrustedRouter(router, true);
        // Fresh test → transient slot is empty.
        assertEq(hook.committedIdentity(router, poolId0), address(0));
        vm.prank(router);
        hook.commitSwapIdentity(trader, poolId0);
        // Same Foundry test == single tx → transient slot persists for the rest of
        // the test and the read returns the committed user.
        assertEq(hook.committedIdentity(router, poolId0), trader);
    }

    function test_CommitSwapIdentity_TransientIsolatedPerRouterPool() public {
        vm.prank(admin);
        hook.setTrustedRouter(router, true);
        vm.prank(router);
        hook.commitSwapIdentity(trader, poolId0);
        // A different (router, poolId) tuple is unaffected.
        assertEq(hook.committedIdentity(router, poolId1), address(0));
        address otherRouter = makeAddr("otherRouter");
        assertEq(hook.committedIdentity(otherRouter, poolId0), address(0));
    }

    function test_Revert_CommitSwapIdentity_NotTrusted() public {
        vm.expectRevert(IPrediXHook.Hook_OnlyTrustedRouter.selector);
        hook.commitSwapIdentity(trader, poolId0);
    }

    function test_Revert_CommitSwapIdentity_ZeroUser() public {
        vm.prank(admin);
        hook.setTrustedRouter(router, true);
        vm.prank(router);
        vm.expectRevert(IPrediXHook.Hook_ZeroAddress.selector);
        hook.commitSwapIdentity(address(0), poolId0);
    }

    // -----------------------------------------------------------------
    // _afterSwap — events, slippage, volume orientation
    // -----------------------------------------------------------------

    /// @dev `StateLibrary.getSlot0` reads via `extsload(bytes32)`. Mock the underlying
    ///      extsload call so the helper returns the synthetic `sqrtPriceX96` (lower 160 bits
    ///      of the packed slot0 word) and zeroes for tick / fees.
    function _mockSlot0(PoolId pid, uint160 sqrtPriceX96) internal {
        bytes32 stateSlot = keccak256(abi.encodePacked(PoolId.unwrap(pid), StateLibrary.POOLS_SLOT));
        bytes memory call = abi.encodeWithSignature("extsload(bytes32)", stateSlot);
        vm.mockCall(POOL_MANAGER, call, abi.encode(bytes32(uint256(sqrtPriceX96))));
    }

    function test_AfterSwap_EmitsMarketTraded_YesIsCurrency0() public {
        _commitTraderSelf(poolId0);
        _mockSlot0(poolId0, 79228162514264337593543950336); // 1<<96 → price 1.0
        BalanceDelta delta = toBalanceDelta(int128(1_000_000), int128(-2_000_000));
        vm.expectEmit(true, true, false, true);
        emit IPrediXHook.Hook_MarketTraded(MARKET_ID, trader, false, 2_000_000, 1_000_000, FeeTiers.PRICE_UNIT);
        hook.exposed_afterSwap(trader, key0, swapZeroForOne, delta, "");
    }

    function test_AfterSwap_VolumeOrientation_YesIsCurrency1() public {
        _commitTraderSelf(poolId1);
        _mockSlot0(poolId1, 79228162514264337593543950336);
        BalanceDelta delta = toBalanceDelta(int128(-3_000_000), int128(1_500_000));
        vm.expectEmit(true, true, false, true);
        // YES = currency1 → yesVolume = |amt1| = 1_500_000, usdcVolume = |amt0| = 3_000_000
        emit IPrediXHook.Hook_MarketTraded(MARKET_ID + 1, trader, true, 3_000_000, 1_500_000, FeeTiers.PRICE_UNIT);
        hook.exposed_afterSwap(trader, key1, swapZeroForOne, delta, "");
    }

    function test_AfterSwap_ReferralEvent_OnlyWhenNonZero() public {
        _commitTraderSelf(poolId0);
        _mockSlot0(poolId0, 79228162514264337593543950336);
        BalanceDelta delta = toBalanceDelta(int128(1_000_000), int128(-2_000_000));
        address referrer = makeAddr("referrer");
        bytes memory hookData = abi.encodePacked(referrer, uint160(0));

        vm.expectEmit(true, true, true, true);
        emit IPrediXHook.Hook_ReferralRecorded(MARKET_ID, referrer, trader, 2_000_000);
        hook.exposed_afterSwap(trader, key0, swapZeroForOne, delta, hookData);
    }

    function test_AfterSwap_NoReferralEvent_WhenReferrerIsZero() public {
        _commitTraderSelf(poolId0);
        _mockSlot0(poolId0, 79228162514264337593543950336);
        BalanceDelta delta = toBalanceDelta(int128(1_000_000), int128(-2_000_000));
        bytes memory hookData = abi.encodePacked(address(0));
        vm.recordLogs();
        hook.exposed_afterSwap(trader, key0, swapZeroForOne, delta, hookData);
        // Only Hook_MarketTraded — no Hook_ReferralRecorded for address(0)
        assertEq(vm.getRecordedLogs().length, 1);
    }

    function test_AfterSwap_NoReferralEvent_WhenReferrerIsTrader() public {
        _commitTraderSelf(poolId0);
        _mockSlot0(poolId0, 79228162514264337593543950336);
        BalanceDelta delta = toBalanceDelta(int128(1_000_000), int128(-2_000_000));
        bytes memory hookData = abi.encodePacked(trader, uint160(0));
        vm.recordLogs();
        hook.exposed_afterSwap(trader, key0, swapZeroForOne, delta, hookData);
        // Only one log expected (Hook_MarketTraded), no Hook_ReferralRecorded
        assertEq(vm.getRecordedLogs().length, 1);
    }

    function test_AfterSwap_Slippage_RevertsWhenZeroForOnePriceTooLow() public {
        _commitTraderSelf(poolId0);
        // post-swap price = 1.0 (1<<96); maxSqrtPriceX96 set higher → expect revert
        uint160 post = uint160(1 << 96);
        uint160 maxFloor = post + 1;
        _mockSlot0(poolId0, post);
        BalanceDelta delta = toBalanceDelta(int128(1), int128(-1));
        bytes memory hookData = abi.encodePacked(address(0), maxFloor);
        vm.expectRevert(IPrediXHook.Hook_MaxSlippageExceeded.selector);
        hook.exposed_afterSwap(trader, key0, swapZeroForOne, delta, hookData);
    }

    function test_AfterSwap_Slippage_RevertsWhenOneForZeroPriceTooHigh() public {
        _commitTraderSelf(poolId0);
        // For !zeroForOne: post-swap sqrtPrice must NOT exceed maxSqrtPriceX96.
        // post = 2<<96, ceiling = 1<<96 (lower than post) → revert.
        uint160 post = uint160(2 << 96);
        uint160 maxCeiling = uint160(1 << 96);
        _mockSlot0(poolId0, post);
        BalanceDelta delta = toBalanceDelta(int128(-1), int128(1));
        bytes memory hookData = abi.encodePacked(address(0), maxCeiling);
        vm.expectRevert(IPrediXHook.Hook_MaxSlippageExceeded.selector);
        hook.exposed_afterSwap(trader, key0, swapOneForZero, delta, hookData);
    }

    function test_AfterSwap_Slippage_NoCheck_MaxIsZero() public {
        _commitTraderSelf(poolId0);
        // Full 40-byte hookData but maxSqrtPriceX96 = 0 → slippage check opts out.
        _mockSlot0(poolId0, 1);
        BalanceDelta delta = toBalanceDelta(int128(1), int128(-1));
        bytes memory hookData = abi.encodePacked(address(0), uint160(0));
        hook.exposed_afterSwap(trader, key0, swapZeroForOne, delta, hookData);
    }

    function test_AfterSwap_Slippage_PassesWhenWithinTolerance() public {
        _commitTraderSelf(poolId0);
        uint160 post = uint160(1 << 96);
        _mockSlot0(poolId0, post);
        BalanceDelta delta = toBalanceDelta(int128(1), int128(-1));
        bytes memory hookData = abi.encodePacked(address(0), post); // floor == post → equal, OK
        hook.exposed_afterSwap(trader, key0, swapZeroForOne, delta, hookData);
    }

    function test_AfterSwap_Slippage_NoCheck_WhenHookDataShort() public {
        _commitTraderSelf(poolId0);
        _mockSlot0(poolId0, 1);
        BalanceDelta delta = toBalanceDelta(int128(1), int128(-1));
        // hookData length 20 → only referrer slice present, no slippage check
        bytes memory hookData = abi.encodePacked(address(0));
        hook.exposed_afterSwap(trader, key0, swapZeroForOne, delta, hookData);
    }

    // -----------------------------------------------------------------
    // Fuzz tests
    // -----------------------------------------------------------------

    function testFuzz_DynamicFee_Monotonic(uint256 secondsToExpiry) public {
        _commitTraderSelf(poolId0);
        // Bound to the actual lifetime: setUp sets endTime = block.timestamp + 30 days.
        secondsToExpiry = bound(secondsToExpiry, 1, 30 days - 1);
        vm.warp(endTime - secondsToExpiry);
        (,, uint24 fee) = hook.exposed_beforeSwap(trader, key0, swapZeroForOne, "");
        uint24 raw = fee & ~LPFeeLibrary.OVERRIDE_FEE_FLAG;
        if (secondsToExpiry > 7 days) assertEq(raw, FeeTiers.FEE_NORMAL);
        else if (secondsToExpiry > 3 days) assertEq(raw, FeeTiers.FEE_MEDIUM);
        else if (secondsToExpiry > 1 days) assertEq(raw, FeeTiers.FEE_HIGH);
        else assertEq(raw, FeeTiers.FEE_VERY_HIGH);
    }

    function testFuzz_AfterSwap_VolumeSymmetry_YesIsCurrency0(int128 amt0, int128 amt1) public {
        _commitTraderSelf(poolId0);
        amt0 = int128(bound(int256(amt0), -1e30, 1e30));
        amt1 = int128(bound(int256(amt1), -1e30, 1e30));
        _mockSlot0(poolId0, uint160(1 << 96));
        BalanceDelta delta = toBalanceDelta(amt0, amt1);

        vm.recordLogs();
        hook.exposed_afterSwap(trader, key0, swapZeroForOne, delta, "");
        (, uint256 usdcVolume, uint256 yesVolume, uint256 yesPrice) = _decodeMarketTraded(vm.getRecordedLogs()[0].data);
        // YES = currency0 → yesVolume must be |amt0|, usdcVolume must be |amt1|
        uint256 abs0 = amt0 >= 0 ? uint256(int256(amt0)) : uint256(-int256(amt0));
        uint256 abs1 = amt1 >= 0 ? uint256(int256(amt1)) : uint256(-int256(amt1));
        assertEq(yesVolume, abs0, "yesVolume == |amt0| when YES is currency0");
        assertEq(usdcVolume, abs1, "usdcVolume == |amt1| when YES is currency0");
        assertLe(yesPrice, FeeTiers.PRICE_UNIT);
    }

    function testFuzz_PriceClamp_NeverExceedsUnit(uint160 sqrtPriceX96) public {
        _commitTraderSelf(poolId0);
        sqrtPriceX96 = uint160(bound(uint256(sqrtPriceX96), 1, type(uint160).max));
        _mockSlot0(poolId0, sqrtPriceX96);
        BalanceDelta delta = toBalanceDelta(int128(1), int128(-1));
        vm.recordLogs();
        hook.exposed_afterSwap(trader, key0, swapZeroForOne, delta, "");
        (,,, uint256 yesPrice) = _decodeMarketTraded(vm.getRecordedLogs()[0].data);
        assertLe(yesPrice, FeeTiers.PRICE_UNIT);
    }

    /// @dev Decode the non-indexed fields of `Hook_MarketTraded`:
    ///      `(bool isBuy, uint256 usdcVolume, uint256 yesVolume, uint256 yesPrice)`.
    function _decodeMarketTraded(bytes memory data)
        private
        pure
        returns (bool isBuy, uint256 usdcVolume, uint256 yesVolume, uint256 yesPrice)
    {
        return abi.decode(data, (bool, uint256, uint256, uint256));
    }
}
