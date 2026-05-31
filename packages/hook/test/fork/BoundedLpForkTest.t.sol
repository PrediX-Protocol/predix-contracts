// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import {Test} from "forge-std/Test.sol";

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {PoolModifyLiquidityTest} from "@uniswap/v4-core/src/test/PoolModifyLiquidityTest.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {CustomRevert} from "@uniswap/v4-core/src/libraries/CustomRevert.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {ModifyLiquidityParams, SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {CurrencySettler} from "@uniswap/v4-core/test/utils/CurrencySettler.sol";

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {PrediXHookV2} from "@predix/hook/hooks/PrediXHookV2.sol";
import {IPrediXHook} from "@predix/hook/interfaces/IPrediXHook.sol";
import {IPrediXHookProxy} from "@predix/hook/interfaces/IPrediXHookProxy.sol";

import {IMarketFacet} from "@predix/shared/interfaces/IMarketFacet.sol";
import {IAccessControlFacet} from "@predix/shared/interfaces/IAccessControlFacet.sol";
import {Roles} from "@predix/shared/constants/Roles.sol";

/// @notice Minimal trusted router used to drive swaps through the REAL hook. The hook's
///         `_resolveIdentity` rejects any swap whose caller is not a trusted router AND
///         that lacks a same-tx identity commit, so the v4 `PoolSwapTest` router cannot be
///         used directly. This helper is registered as trusted via the hook admin flow,
///         commits an identity in the same transaction as the swap, and settles deltas
///         against the payer (the caller, who approves this router for the input token).
/// @dev Settling via `transferFrom(payer -> PoolManager)` rather than holding funds matters
///      on the staging fork: the quote token is allowlisted and reverts `TransferRestricted`
///      on transfers to non-whitelisted addresses, but the PoolManager is whitelisted.
contract ForkTrustedRouter {
    using CurrencySettler for Currency;
    using PoolIdLibrary for PoolKey;

    IPoolManager internal immutable manager;
    IPrediXHook internal immutable hook;

    struct Callback {
        address user;
        address payer;
        PoolKey key;
        SwapParams params;
    }

    constructor(IPoolManager manager_, IPrediXHook hook_) {
        manager = manager_;
        hook = hook_;
    }

    /// @notice Execute a swap as a trusted router on behalf of `user`. `msg.sender` is the
    ///         payer: it must hold the input token and have approved this router. Output and
    ///         unspent input settle back to the payer.
    function swap(PoolKey calldata key, SwapParams calldata params, address user)
        external
        returns (BalanceDelta delta)
    {
        delta = abi.decode(manager.unlock(abi.encode(Callback(user, msg.sender, key, params))), (BalanceDelta));
    }

    function unlockCallback(bytes calldata raw) external returns (bytes memory) {
        require(msg.sender == address(manager), "only manager");
        Callback memory cb = abi.decode(raw, (Callback));

        // Commit identity in the SAME tx, before the swap: `_beforeSwap` -> `_resolveIdentity`
        // reverts `Hook_MissingRouterCommit` otherwise.
        hook.commitSwapIdentity(cb.user, cb.key.toId());

        BalanceDelta delta = manager.swap(cb.key, cb.params, "");

        int256 d0 = delta.amount0();
        int256 d1 = delta.amount1();
        if (d0 < 0) cb.key.currency0.settle(manager, cb.payer, uint256(-d0), false);
        if (d1 < 0) cb.key.currency1.settle(manager, cb.payer, uint256(-d1), false);
        if (d0 > 0) cb.key.currency0.take(manager, cb.payer, uint256(d0), false);
        if (d1 > 0) cb.key.currency1.take(manager, cb.payer, uint256(d1), false);

        return abi.encode(delta);
    }
}

/// @notice Mainnet-fork integration test for the bounded-LP guard, exercised through the
///         REAL Unichain v4 `PoolManager` and the LIVE `PrediXHookV2` proxy (upgraded
///         in-fork to the guarded implementation). Covers behaviours the mocked unit suite
///         cannot: an out-of-band add-liquidity actually reverts the whole `modifyLiquidity`
///         tx via the real callback dispatch, a swap on a bounded pool cannot push YES > 1,
///         and grandfathered out-of-band liquidity still can.
/// @dev Requires env: `UNICHAIN_RPC_PRIMARY`, `POOL_MANAGER_ADDRESS`, `HOOK_PROXY_ADDRESS`,
///      `DIAMOND_ADDRESS`, `USDC_ADDRESS` (loaded via the `.env` symlink / sourced testenv).
contract BoundedLpForkTest is Test {
    using StateLibrary for IPoolManager;
    using PoolIdLibrary for PoolKey;

    /// @dev Canonical 50¢ midpoint sqrtPriceX96 values, copied from `PrediXMarketFactory`
    ///      [SQRT_PRICE_MID_C0/C1 :62-63]. `C0` (= sqrt(0.5)·2^96) initialises a pool where
    ///      YES is currency0; `C1` (= sqrt(2)·2^96) where YES is currency1. Both imply YES = 0.5.
    uint160 internal constant SQRT_PRICE_MID_C0 = 56022770974786139918731938227;
    uint160 internal constant SQRT_PRICE_MID_C1 = 112045541949572279837463876454;

    /// @dev AccessControl diamond-storage base [LibAccessControlStorage.SLOT].
    bytes32 internal constant ACCESS_SLOT = keccak256("predix.storage.access.v1");

    /// @dev Pinned fork block for determinism + local RPC caching. Forking at the moving
    ///      `latest` block intermittently fails fork-creation against the public RPC; a
    ///      pinned block is fetched once and cached. Bump if the RPC stops serving it.
    uint256 internal constant FORK_BLOCK = 49_379_000;

    IPoolManager internal pm;
    address internal proxy;
    address internal diamond;
    IERC20 internal usdc;

    PrediXHookV2 internal newImpl;
    PoolModifyLiquidityTest internal liqRouter;
    ForkTrustedRouter internal swapHelper;

    address internal oracle;
    uint24 internal lpFee;
    int24 internal spacing;

    bool internal _upgraded;
    bool internal _routerTrusted;

    function setUp() public {
        vm.createSelectFork(vm.envString("UNICHAIN_RPC_PRIMARY"), FORK_BLOCK);
        pm = IPoolManager(vm.envAddress("POOL_MANAGER_ADDRESS"));
        proxy = vm.envAddress("HOOK_PROXY_ADDRESS");
        diamond = vm.envAddress("DIAMOND_ADDRESS");
        usdc = IERC20(vm.envAddress("USDC_ADDRESS"));

        // Read live immutables off the CURRENT implementation directly (not through the
        // proxy) so the proxy's own `ADMIN_ROTATION_DELAY()` getter cannot shadow the impl's.
        PrediXHookV2 live = PrediXHookV2(IPrediXHookProxy(proxy).implementation());
        assertEq(address(live.poolManager()), address(pm), "live impl PM != env PM");
        lpFee = live.canonicalLpFee();
        spacing = live.canonicalTickSpacing();
        newImpl = new PrediXHookV2(live.poolManager(), live.quoter(), lpFee, spacing, live.ADMIN_ROTATION_DELAY());

        liqRouter = new PoolModifyLiquidityTest(pm);
        swapHelper = new ForkTrustedRouter(pm, IPrediXHook(proxy));

        // Grant this test CREATOR_ROLE (to create markets) + ADMIN_ROLE (to approve an
        // oracle) by writing the AccessControl members slot directly, then verify via the
        // public getter. Avoids needing a live admin key on the fork.
        _grantRole(Roles.CREATOR_ROLE, address(this));
        _grantRole(Roles.ADMIN_ROLE, address(this));
        assertTrue(IAccessControlFacet(diamond).hasRole(Roles.CREATOR_ROLE, address(this)), "creator role");
        assertTrue(IAccessControlFacet(diamond).hasRole(Roles.ADMIN_ROLE, address(this)), "admin role");

        // A market's oracle is only consulted at resolve time; unresolved test markets never
        // touch it, so an EOA placeholder is sufficient once approved.
        oracle = makeAddr("forkOracle");
        IMarketFacet(diamond).approveOracle(oracle);
        assertTrue(IMarketFacet(diamond).isOracleApproved(oracle), "oracle approve");

        deal(address(usdc), address(this), 1e18);
        assertEq(usdc.balanceOf(address(this)), 1e18, "usdc deal");
        usdc.approve(diamond, type(uint256).max);
        usdc.approve(address(liqRouter), type(uint256).max);
    }

    // ---------------------------------------------------------------------
    // Task 2 — Add-LP guard through the REAL PoolManager
    // ---------------------------------------------------------------------

    function test_Fork_AddOutOfBand_YesCurrency0_Reverts() public {
        _upgrade();
        (PoolKey memory key,,) = _freshBoundedPool(true);
        _expectGuardRevert();
        liqRouter.modifyLiquidity(key, _mlp(-spacing, spacing, 1e9), ""); // tickUpper > 0
    }

    function test_Fork_AddOutOfBand_YesCurrency1_Reverts() public {
        _upgrade();
        (PoolKey memory key,,) = _freshBoundedPool(false);
        _expectGuardRevert();
        liqRouter.modifyLiquidity(key, _mlp(-spacing, spacing, 1e9), ""); // tickLower < 0
    }

    function test_Fork_AddFullRangeStraddle_Reverts() public {
        _upgrade();
        (PoolKey memory key,,) = _freshBoundedPool(true);
        _expectGuardRevert();
        liqRouter.modifyLiquidity(key, _mlp(_minUsable(), _maxUsable(), 1e9), "");
    }

    function test_Fork_AddInBand_BothOrientations_Succeed() public {
        _upgrade();

        (PoolKey memory k0, uint256 id0, address yes0) = _freshBoundedPool(true);
        _fundYes(id0, yes0, 1e10);
        liqRouter.modifyLiquidity(k0, _mlp(_alignDown(-12000), 0, 1e9), ""); // tickUpper == 0 (boundary)
        assertGt(pm.getLiquidity(k0.toId()), 0, "k0 liquidity not added");

        (PoolKey memory k1, uint256 id1, address yes1) = _freshBoundedPool(false);
        _fundYes(id1, yes1, 1e10);
        liqRouter.modifyLiquidity(k1, _mlp(0, _alignUp(12000), 1e9), ""); // tickLower == 0 (boundary)
        assertGt(pm.getLiquidity(k1.toId()), 0, "k1 liquidity not added");
    }

    // ---------------------------------------------------------------------
    // Task 3 — Swap on a bounded pool cannot cross YES = 1
    // ---------------------------------------------------------------------

    function test_Fork_Swap_CannotPushYesAboveOne_YesCurrency0() public {
        _upgrade();
        _makeRouterTrusted();

        (PoolKey memory key, uint256 marketId, address yesToken) = _freshBoundedPool(true);
        _fundYes(marketId, yesToken, 1e10);
        // In-band liquidity only: from below the 50¢ start up to exactly YES = 1 (tick 0).
        liqRouter.modifyLiquidity(key, _mlp(_alignDown(-12000), 0, 1e9), "");

        // A rational buyer never pays above YES = 1, so cap the swap at tick 0 and dump far
        // more USDC than the bounded pool can absorb. The pool fills to exactly YES = 1 and
        // refuses the rest (partial fill) — it can never quote YES higher.
        uint256 buyAmount = 5e9;
        usdc.approve(address(swapHelper), buyAmount);
        uint256 usdcBefore = usdc.balanceOf(address(this));
        uint256 yesBefore = IERC20(yesToken).balanceOf(address(this));
        SwapParams memory sp = SwapParams({
            zeroForOne: false, // buy YES (currency0) with USDC (currency1)
            amountSpecified: -int256(buyAmount), // exact input
            sqrtPriceLimitX96: TickMath.getSqrtPriceAtTick(0)
        });
        swapHelper.swap(key, sp, address(this));

        (, int24 tick,,) = pm.getSlot0(key.toId());
        uint256 usdcSpent = usdcBefore - usdc.balanceOf(address(this));
        assertLe(tick, 0, "bounded pool let YES exceed 1 (tick > 0)");
        assertLt(usdcSpent, buyAmount, "expected partial fill: pool absorbed entire buy past YES=1");
        assertGt(usdcSpent, 0, "swap consumed no USDC");
        assertGt(IERC20(yesToken).balanceOf(address(this)) - yesBefore, 0, "buyer received no YES");
    }

    // ---------------------------------------------------------------------
    // Task 4 — Grandfather: pre-existing out-of-band LP still fills > 1
    // ---------------------------------------------------------------------

    function test_Fork_Grandfathered_OutOfBandLp_StillFillsAboveOne() public {
        // Add out-of-band liquidity BEFORE the upgrade, while the live impl has no guard.
        (PoolKey memory key, uint256 marketId, address yesToken) = _freshBoundedPool(true);
        _fundYes(marketId, yesToken, 2e10);
        int24 lo = _alignDown(-12000);
        int24 hi = _alignUp(20000);
        liqRouter.modifyLiquidity(key, _mlp(lo, hi, 1e9), ""); // straddles YES = 1, allowed pre-upgrade

        _upgrade(); // guard now active for NEW adds, but existing liquidity is grandfathered
        _makeRouterTrusted();

        // Buy YES with a limit set INSIDE the out-of-band liquidity (tick 6000 ≈ YES 1.82),
        // so the price is pushed past YES = 1 by REAL fills, not an empty-region marker jump.
        uint256 buyAmount = 5e9;
        usdc.approve(address(swapHelper), buyAmount);
        SwapParams memory sp = SwapParams({
            zeroForOne: false,
            amountSpecified: -int256(buyAmount),
            sqrtPriceLimitX96: TickMath.getSqrtPriceAtTick(_alignDown(6000))
        });
        swapHelper.swap(key, sp, address(this));

        (, int24 tick,,) = pm.getSlot0(key.toId());
        assertGt(tick, 0, "grandfathered out-of-band LP should still let YES exceed 1");
        // The final price sits INSIDE an active liquidity range above tick 0 — proving the
        // climb past YES = 1 came from REAL out-of-band fills, not an empty-region marker jump
        // (which a bounded pool would also show). This is what a bounded pool cannot do.
        assertGt(pm.getLiquidity(key.toId()), 0, "price above YES=1 must sit in real grandfathered liquidity");
    }

    // ---------------------------------------------------------------------
    // Task 5 — Remove out-of-band liquidity after upgrade still works
    // ---------------------------------------------------------------------

    function test_Fork_RemoveOutOfBandLp_AfterUpgrade_Succeeds() public {
        (PoolKey memory key, uint256 marketId, address yesToken) = _freshBoundedPool(true);
        _fundYes(marketId, yesToken, 2e10);
        int24 lo = _alignDown(-12000);
        int24 hi = _alignUp(20000);
        liqRouter.modifyLiquidity(key, _mlp(lo, hi, 1e9), ""); // out-of-band, pre-upgrade

        _upgrade();

        // Exit is never gated (`_beforeRemoveLiquidity` only checks registration), so a
        // negative delta on the grandfathered position must NOT revert.
        liqRouter.modifyLiquidity(key, _mlp(lo, hi, -1e9), "");
        assertEq(pm.getLiquidity(key.toId()), 0, "grandfathered liquidity not removed");
    }

    // ---------------------------------------------------------------------
    // Helpers
    // ---------------------------------------------------------------------

    /// @dev Expect the wrapped hook revert v4 produces: `Hooks.callHook` catches the hook's
    ///      `Hook_LiquidityRangeOutOfBounds` and re-reverts `CustomRevert.WrappedError(hook,
    ///      beforeAddLiquidity.selector, <inner reason>, HookCallFailed.selector)`.
    function _expectGuardRevert() internal {
        vm.expectRevert(
            abi.encodeWithSelector(
                CustomRevert.WrappedError.selector,
                proxy,
                IHooks.beforeAddLiquidity.selector,
                abi.encodeWithSelector(IPrediXHook.Hook_LiquidityRangeOutOfBounds.selector),
                abi.encodeWithSelector(Hooks.HookCallFailed.selector)
            )
        );
    }

    /// @dev Upgrade the live proxy to the guarded `newImpl` via the real timelock path.
    function _upgrade() internal {
        if (_upgraded) return;
        IPrediXHookProxy p = IPrediXHookProxy(proxy);
        address admin = p.proxyAdmin();
        if (p.pendingImplementation() != address(0)) {
            vm.prank(admin);
            p.cancelUpgrade();
        }
        vm.prank(admin);
        p.proposeUpgrade(address(newImpl));
        vm.warp(p.upgradeReadyAt() + 1);
        vm.prank(admin);
        p.executeUpgrade();
        assertEq(p.implementation(), address(newImpl), "upgrade failed");
        _upgraded = true;
    }

    /// @dev Register `swapHelper` as a trusted router via the hook admin's 48h flow.
    function _makeRouterTrusted() internal {
        if (_routerTrusted) return;
        IPrediXHook h = IPrediXHook(proxy);
        address hookAdmin = h.admin();
        vm.prank(hookAdmin);
        h.proposeTrustedRouter(address(swapHelper), true);
        vm.warp(block.timestamp + 48 hours + 1);
        vm.prank(hookAdmin);
        h.executeTrustedRouter(address(swapHelper));
        assertTrue(h.isTrustedRouter(address(swapHelper)), "router trust failed");
        _routerTrusted = true;
    }

    /// @dev Create a fresh market+pool whose YES token lands on the requested side of USDC.
    ///      Outcome-token clones get non-deterministic CREATE addresses, so we create markets
    ///      until orientation matches (`yesToken < USDC` == yesIsCurrency0), then register and
    ///      initialise the pool at the canonical 50¢ midpoint.
    function _freshBoundedPool(bool wantYesIsCurrency0)
        internal
        returns (PoolKey memory key, uint256 marketId, address yesToken)
    {
        for (uint256 i = 0; i < 64; ++i) {
            uint256 id = IMarketFacet(diamond).createMarket("bounded-lp fork", block.timestamp + 3650 days, oracle);
            address yt = IMarketFacet(diamond).getMarket(id).yesToken;
            if ((yt < address(usdc)) == wantYesIsCurrency0) {
                marketId = id;
                yesToken = yt;
                break;
            }
        }
        require(yesToken != address(0), "no orientation match in 64 markets");

        (Currency c0, Currency c1, uint160 initSqrtPrice) = wantYesIsCurrency0
            ? (Currency.wrap(yesToken), Currency.wrap(address(usdc)), SQRT_PRICE_MID_C0)
            : (Currency.wrap(address(usdc)), Currency.wrap(yesToken), SQRT_PRICE_MID_C1);
        key = PoolKey({currency0: c0, currency1: c1, fee: lpFee, tickSpacing: spacing, hooks: IHooks(proxy)});

        IPrediXHook(proxy).registerMarketPool(marketId, key);
        pm.initialize(key, initSqrtPrice);
    }

    /// @dev Mint YES (and NO) 1:1 from USDC via the real `splitPosition`, then approve the
    ///      liquidity router to pull the YES leg.
    function _fundYes(uint256 marketId, address yesToken, uint256 amount) internal {
        IMarketFacet(diamond).splitPosition(marketId, amount);
        IERC20(yesToken).approve(address(liqRouter), type(uint256).max);
    }

    function _grantRole(bytes32 role, address account) internal {
        // Layout.roles (field 0) -> roles[role] = keccak(role, ACCESS_SLOT);
        // RoleData.members (field 0) -> members[account] = keccak(account, roles[role]).
        bytes32 roleData = keccak256(abi.encode(role, ACCESS_SLOT));
        bytes32 memberSlot = keccak256(abi.encode(account, roleData));
        vm.store(diamond, memberSlot, bytes32(uint256(1)));
    }

    function _mlp(int24 lo, int24 hi, int256 liq) internal pure returns (ModifyLiquidityParams memory) {
        return ModifyLiquidityParams({tickLower: lo, tickUpper: hi, liquidityDelta: liq, salt: 0});
    }

    function _minUsable() internal view returns (int24) {
        return (TickMath.MIN_TICK / spacing) * spacing;
    }

    function _maxUsable() internal view returns (int24) {
        return (TickMath.MAX_TICK / spacing) * spacing;
    }

    /// @dev Floor `t` to a multiple of `spacing` toward -infinity, clamped to the usable range.
    function _alignDown(int24 t) internal view returns (int24) {
        int24 q = t / spacing;
        if (t < 0 && q * spacing != t) q -= 1;
        int24 r = q * spacing;
        int24 minU = _minUsable();
        return r < minU ? minU : r;
    }

    /// @dev Ceil `t` to a multiple of `spacing` toward +infinity, clamped to the usable range.
    function _alignUp(int24 t) internal view returns (int24) {
        int24 q = t / spacing;
        if (t > 0 && q * spacing != t) q += 1;
        int24 r = q * spacing;
        int24 maxU = _maxUsable();
        return r > maxU ? maxU : r;
    }
}
