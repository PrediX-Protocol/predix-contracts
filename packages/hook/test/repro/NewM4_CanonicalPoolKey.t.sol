// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";

import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";

import {PrediXHookV2} from "../../src/hooks/PrediXHookV2.sol";
import {IPrediXHook} from "../../src/interfaces/IPrediXHook.sol";

import {MockDiamond} from "../utils/MockDiamond.sol";
import {TestHookHarness} from "../utils/TestHookHarness.sol";

/// @notice Repro for NEW-M4: `registerMarketPool` must reject non-canonical
///         fee / tickSpacing / hook address. Pre-fix, any caller could
///         front-run a legitimate deploy and bind `marketId` to a junk
///         `PoolKey`; because the hook's `_marketToPoolId` uniqueness check
///         then refused the real pool, the market was bricked. Canonical
///         enforcement closes the front-run-brick attack surface.
contract NewM4_CanonicalPoolKey is Test {
    TestHookHarness internal hook;
    MockDiamond internal diamond;

    address internal constant POOL_MANAGER = address(0xCAFE);
    address internal admin = makeAddr("admin");
    address internal usdc = address(0x10000);
    address internal yesLow = address(0x10000 - 1);
    address internal noToken = makeAddr("no");

    uint256 internal constant MARKET_ID = 1;
    uint24 internal constant CANONICAL_FEE = 0x800000;
    int24 internal constant CANONICAL_TICK_SPACING = int24(60);

    function setUp() public {
        diamond = new MockDiamond();
        hook = new TestHookHarness(IPoolManager(POOL_MANAGER), address(0xC0FFEE));
        hook.initialize(address(diamond), admin, usdc);
        diamond.setMarket(MARKET_ID, yesLow, noToken, block.timestamp + 30 days, false, false);
    }

    function _canonicalKey() internal view returns (PoolKey memory) {
        return PoolKey({
            currency0: Currency.wrap(yesLow),
            currency1: Currency.wrap(usdc),
            fee: CANONICAL_FEE,
            tickSpacing: CANONICAL_TICK_SPACING,
            hooks: hook
        });
    }

    function test_NewM4_RegisterWithNonCanonicalFee_Reverts() public {
        PoolKey memory key = _canonicalKey();
        key.fee = 0x900000; // non-canonical

        vm.expectRevert(IPrediXHook.Hook_NonCanonicalFee.selector);
        hook.registerMarketPool(MARKET_ID, key);
    }

    function test_NewM4_RegisterWithNonCanonicalTickSpacing_Reverts() public {
        PoolKey memory key = _canonicalKey();
        key.tickSpacing = int24(120);

        vm.expectRevert(IPrediXHook.Hook_NonCanonicalTickSpacing.selector);
        hook.registerMarketPool(MARKET_ID, key);
    }

    function test_NewM4_RegisterWithWrongHook_Reverts() public {
        PoolKey memory key = _canonicalKey();
        key.hooks = IHooks(makeAddr("impostorHook"));

        vm.expectRevert(IPrediXHook.Hook_WrongHookAddress.selector);
        hook.registerMarketPool(MARKET_ID, key);
    }

    function test_NewM4_RegisterWithCanonicalKey_Success() public {
        PoolKey memory key = _canonicalKey();
        hook.registerMarketPool(MARKET_ID, key);
        assertEq(hook.poolMarketId(key.toId()), MARKET_ID, "canonical registration succeeds");
    }

    function test_NewM4_ConstructorRejectsZeroFee() public {
        vm.expectRevert(IPrediXHook.Hook_InvalidCanonicalFee.selector);
        new PrediXHookV2(IPoolManager(POOL_MANAGER), address(0xC0FFEE), 0, CANONICAL_TICK_SPACING);
    }

    function test_NewM4_ConstructorRejectsZeroTickSpacing() public {
        vm.expectRevert(IPrediXHook.Hook_InvalidCanonicalTickSpacing.selector);
        new PrediXHookV2(IPoolManager(POOL_MANAGER), address(0xC0FFEE), CANONICAL_FEE, int24(0));
    }

    function test_NewM4_GriefAttack_Blocked() public {
        // Attacker attempts a front-run registration with junk fee — pre-fix
        // this would have succeeded and locked `MARKET_ID` to the junk PoolId
        // via `_marketToPoolId`. Post-fix, attacker's first call reverts, so
        // the legitimate deploy proceeds with the canonical key.
        PoolKey memory junk = _canonicalKey();
        junk.fee = 0x123456;

        vm.expectRevert(IPrediXHook.Hook_NonCanonicalFee.selector);
        hook.registerMarketPool(MARKET_ID, junk);

        // Legit flow proceeds unblocked because the attacker's attempt did
        // not write any state.
        PoolKey memory canonical = _canonicalKey();
        hook.registerMarketPool(MARKET_ID, canonical);
        assertEq(hook.poolMarketId(canonical.toId()), MARKET_ID, "legit deploy unblocked");
    }
}
