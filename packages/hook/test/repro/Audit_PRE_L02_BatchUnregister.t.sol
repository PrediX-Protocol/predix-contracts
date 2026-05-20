// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import {Test} from "forge-std/Test.sol";

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";

import {IPrediXHook} from "../../src/interfaces/IPrediXHook.sol";

import {MockDiamond} from "../utils/MockDiamond.sol";
import {TestHookHarness} from "../utils/TestHookHarness.sol";

/// @title Audit_PRE_L02_BatchUnregister
/// @notice Fix-lock for PRE-L02: the singleton
///         `proposeUnregisterMarketPool` / `executeUnregisterMarketPool` /
///         `cancelUnregisterMarketPool` entry points scaled linearly with
///         the active market count — a diamond rotation against 50 markets
///         required 100 admin transactions over 48h+. The new batch variants
///         collapse that into 2 transactions (one propose, one execute after
///         the timelock).
contract Audit_PRE_L02_BatchUnregister is Test {
    TestHookHarness internal hook;
    MockDiamond internal diamond;

    address internal constant POOL_MANAGER = address(0xCAFE);
    address internal admin = makeAddr("admin");
    address internal rando = makeAddr("rando");
    address internal usdc = address(0x10000);
    address internal noToken = makeAddr("no");

    uint256 internal constant BATCH = 5;

    uint256[] internal marketIds;
    address[] internal yesTokens;

    function setUp() public {
        diamond = new MockDiamond();
        hook = new TestHookHarness(IPoolManager(POOL_MANAGER), address(0xC0FFEE));
        hook.initialize(address(diamond), admin, usdc);

        for (uint256 i; i < BATCH; ++i) {
            uint256 marketId = i + 1;
            address yes = address(uint160(0x10000 - 1 - i));
            diamond.setMarket(marketId, yes, noToken, block.timestamp + 30 days, false, false);
            hook.registerMarketPool(marketId, _canonicalKey(yes));
            marketIds.push(marketId);
            yesTokens.push(yes);
        }
    }

    function _canonicalKey(address yesToken_) internal view returns (PoolKey memory) {
        return PoolKey({
            currency0: Currency.wrap(yesToken_),
            currency1: Currency.wrap(usdc),
            fee: 0x800000,
            tickSpacing: int24(60),
            hooks: hook
        });
    }

    // ===================== Propose batch =====================

    function test_L02_ProposeBatch_QueuesAllReadyAts() public {
        uint256 expectedReadyAt = block.timestamp + hook.MARKET_UNREGISTER_DELAY();

        vm.prank(admin);
        hook.proposeUnregisterMarketPools(marketIds);

        for (uint256 i; i < marketIds.length; ++i) {
            assertEq(
                hook.pendingUnregisterMarketPool(marketIds[i]), expectedReadyAt, "readyAt persisted per id"
            );
        }
    }

    function test_L02_ProposeBatch_RevertsOnAlreadyPending() public {
        vm.prank(admin);
        hook.proposeUnregisterMarketPool(marketIds[2]);

        vm.prank(admin);
        vm.expectRevert(IPrediXHook.Hook_AlreadyPendingUnregister.selector);
        hook.proposeUnregisterMarketPools(marketIds);

        // None of the others were queued — propose is atomic.
        for (uint256 i; i < marketIds.length; ++i) {
            if (i == 2) continue;
            assertEq(hook.pendingUnregisterMarketPool(marketIds[i]), 0, "not queued");
        }
    }

    function test_L02_ProposeBatch_RevertsOnMarketNotFound() public {
        uint256[] memory withGhost = new uint256[](marketIds.length + 1);
        for (uint256 i; i < marketIds.length; ++i) {
            withGhost[i] = marketIds[i];
        }
        withGhost[marketIds.length] = 999;

        vm.prank(admin);
        vm.expectRevert(IPrediXHook.Hook_MarketNotFound.selector);
        hook.proposeUnregisterMarketPools(withGhost);
    }

    function test_L02_ProposeBatch_RevertsOnOverCap() public {
        uint256 cap = hook.MAX_BATCH_UNREGISTER();
        uint256[] memory overCap = new uint256[](cap + 1);
        for (uint256 i; i < overCap.length; ++i) {
            overCap[i] = i;
        }
        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(IPrediXHook.Hook_BatchTooLarge.selector, cap + 1, cap));
        hook.proposeUnregisterMarketPools(overCap);
    }

    function test_L02_ProposeBatch_RevertsForNonAdmin() public {
        vm.prank(rando);
        vm.expectRevert(IPrediXHook.Hook_OnlyAdmin.selector);
        hook.proposeUnregisterMarketPools(marketIds);
    }

    // ===================== Execute batch =====================

    function test_L02_ExecuteBatch_HappyPath_ClearsAllBindings() public {
        vm.prank(admin);
        hook.proposeUnregisterMarketPools(marketIds);

        vm.warp(block.timestamp + hook.MARKET_UNREGISTER_DELAY() + 1);

        vm.prank(admin);
        hook.executeUnregisterMarketPools(marketIds);

        for (uint256 i; i < marketIds.length; ++i) {
            assertEq(hook.pendingUnregisterMarketPool(marketIds[i]), 0, "pending cleared");
            // Once unregistered, re-registering succeeds (the L-02 motivation
            // was unblocking re-register post-diamond-rotation).
            diamond.setMarket(marketIds[i], yesTokens[i], noToken, block.timestamp + 30 days, false, false);
            hook.registerMarketPool(marketIds[i], _canonicalKey(yesTokens[i]));
        }
    }

    function test_L02_ExecuteBatch_RevertsBeforeDelay() public {
        vm.prank(admin);
        hook.proposeUnregisterMarketPools(marketIds);

        // 1 second short of the delay.
        vm.warp(block.timestamp + hook.MARKET_UNREGISTER_DELAY() - 1);

        vm.prank(admin);
        vm.expectRevert(IPrediXHook.Hook_UnregisterDelayNotElapsed.selector);
        hook.executeUnregisterMarketPools(marketIds);
    }

    function test_L02_ExecuteBatch_RevertsOnNoPending() public {
        vm.warp(block.timestamp + hook.MARKET_UNREGISTER_DELAY() + 1);

        vm.prank(admin);
        vm.expectRevert(IPrediXHook.Hook_NoPendingUnregister.selector);
        hook.executeUnregisterMarketPools(marketIds);
    }

    function test_L02_ExecuteBatch_RevertsOnOverCap() public {
        uint256 cap = hook.MAX_BATCH_UNREGISTER();
        uint256[] memory overCap = new uint256[](cap + 1);
        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(IPrediXHook.Hook_BatchTooLarge.selector, cap + 1, cap));
        hook.executeUnregisterMarketPools(overCap);
    }

    // ===================== Cancel batch =====================

    function test_L02_CancelBatch_ClearsAllPending() public {
        vm.prank(admin);
        hook.proposeUnregisterMarketPools(marketIds);

        vm.prank(admin);
        hook.cancelUnregisterMarketPools(marketIds);

        for (uint256 i; i < marketIds.length; ++i) {
            assertEq(hook.pendingUnregisterMarketPool(marketIds[i]), 0, "pending cleared");
        }
    }

    function test_L02_CancelBatch_RevertsOnNoPending() public {
        vm.prank(admin);
        vm.expectRevert(IPrediXHook.Hook_NoPendingUnregister.selector);
        hook.cancelUnregisterMarketPools(marketIds);
    }

    function test_L02_CancelBatch_RevertsOnOverCap() public {
        uint256 cap = hook.MAX_BATCH_UNREGISTER();
        uint256[] memory overCap = new uint256[](cap + 1);
        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(IPrediXHook.Hook_BatchTooLarge.selector, cap + 1, cap));
        hook.cancelUnregisterMarketPools(overCap);
    }

    // ===================== Singleton + batch coexist =====================

    /// @dev The batch entry points share their bodies with the singleton via
    ///      internal helpers. A regression that touches one MUST be observable
    ///      from the other; this test pins that property by interleaving the
    ///      two forms.
    function test_L02_Singleton_And_Batch_ShareSemantics() public {
        // Mix: singleton on id 1, batch on the rest.
        vm.prank(admin);
        hook.proposeUnregisterMarketPool(marketIds[0]);

        uint256[] memory rest = new uint256[](marketIds.length - 1);
        for (uint256 i = 1; i < marketIds.length; ++i) {
            rest[i - 1] = marketIds[i];
        }
        vm.prank(admin);
        hook.proposeUnregisterMarketPools(rest);

        vm.warp(block.timestamp + hook.MARKET_UNREGISTER_DELAY() + 1);

        // Mix the execute side too: batch first, then singleton.
        vm.prank(admin);
        hook.executeUnregisterMarketPools(rest);

        vm.prank(admin);
        hook.executeUnregisterMarketPool(marketIds[0]);

        for (uint256 i; i < marketIds.length; ++i) {
            assertEq(hook.pendingUnregisterMarketPool(marketIds[i]), 0, "all cleared");
        }
    }
}
