// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";

import {IPrediXHook} from "../../src/interfaces/IPrediXHook.sol";

import {MockDiamond} from "../utils/MockDiamond.sol";
import {TestHookHarness} from "../utils/TestHookHarness.sol";

/// @notice Repro for H-H03 / NEW-M6: `commitSwapIdentityFor(caller, user, poolId)`
///         must only accept self-commit (`caller == msg.sender`) or writes under
///         the canonical quoter's slot. A trusted router must NOT be able to
///         plant identity under another trusted router's slot.
contract NEW_M6_CommitIdentitySelfCheck is Test {
    using PoolIdLibrary for PoolKey;

    TestHookHarness internal hook;
    MockDiamond internal diamond;

    address internal constant POOL_MANAGER = address(0xCAFE);
    address internal admin = makeAddr("admin");
    address internal routerA = makeAddr("routerA");
    address internal routerB = makeAddr("routerB");
    address internal quoter = makeAddr("quoter");
    address internal usdc = address(0x10000);
    address internal yesLow = address(0x10000 - 1);
    address internal noToken = makeAddr("no");

    uint256 internal constant MARKET_ID = 1;

    PoolKey internal poolKey;
    PoolId internal poolId;

    function setUp() public {
        diamond = new MockDiamond();
        hook = new TestHookHarness(IPoolManager(POOL_MANAGER), quoter);
        hook.initialize(address(diamond), admin, usdc);
        diamond.setMarket(MARKET_ID, yesLow, noToken, block.timestamp + 30 days, false, false);

        poolKey = PoolKey({
            currency0: Currency.wrap(yesLow),
            currency1: Currency.wrap(usdc),
            fee: 0x800000,
            tickSpacing: 60,
            hooks: hook
        });
        poolId = poolKey.toId();
        hook.registerMarketPool(MARKET_ID, poolKey);

        // Trust both routers + quoter (bootstrap-window setter OK).
        vm.prank(admin);
        hook.setTrustedRouter(routerA, true);
        vm.prank(admin);
        hook.setTrustedRouter(routerB, true);
        vm.prank(admin);
        hook.setTrustedRouter(quoter, true);
    }

    function test_NEW_M6_quoterIsImmutable() public view {
        assertEq(hook.quoter(), quoter);
    }

    function test_NEW_M6_selfCommitAllowed() public {
        // routerA commits under its own slot — OK.
        vm.prank(routerA);
        hook.commitSwapIdentityFor(routerA, address(0xBEEF), poolId);
        assertEq(hook.committedIdentity(routerA, poolId), address(0xBEEF));
    }

    function test_NEW_M6_quoterPreCommitAllowed() public {
        // routerA pre-commits under quoter's slot — canonical simulate-and-revert
        // pattern, MUST still work.
        vm.prank(routerA);
        hook.commitSwapIdentityFor(quoter, address(0xBEEF), poolId);
        assertEq(hook.committedIdentity(quoter, poolId), address(0xBEEF));
    }

    function test_Revert_NEW_M6_crossRouterCommitBlocked() public {
        // routerA writes under routerB's slot — the latent attack. MUST revert.
        vm.prank(routerA);
        vm.expectRevert(IPrediXHook.Hook_InvalidCommitTarget.selector);
        hook.commitSwapIdentityFor(routerB, address(0xBEEF), poolId);
    }

    function test_Revert_NEW_M6_nonTrustedCallerStillRejected() public {
        // Existing trusted check still primary. An untrusted caller reverts
        // with Hook_OnlyTrustedRouter BEFORE the new self/quoter check fires.
        address stranger = makeAddr("stranger");
        vm.prank(stranger);
        vm.expectRevert(IPrediXHook.Hook_OnlyTrustedRouter.selector);
        hook.commitSwapIdentityFor(stranger, address(0xBEEF), poolId);
    }
}
