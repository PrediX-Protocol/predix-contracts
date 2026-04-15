// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";

import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {LPFeeLibrary} from "@uniswap/v4-core/src/libraries/LPFeeLibrary.sol";

import {IPrediXHook} from "../../src/interfaces/IPrediXHook.sol";

import {MockDiamond} from "../utils/MockDiamond.sol";
import {TestHookHarness} from "../utils/TestHookHarness.sol";

/// @dev FINAL-H06 repro: pre-fix, `_resolveIdentity` silently falls back to `sender`
///      when the caller is not a trusted router, so direct swaps through PoolManager
///      from attacker-deployed contracts would pass INV-5. Post-fix, untrusted callers
///      MUST revert with `Hook_UntrustedCaller`, and trusted callers without a commit
///      MUST revert with `Hook_MissingRouterCommit`.
contract FinalH06Test is Test {
    using PoolIdLibrary for PoolKey;

    TestHookHarness internal hook;
    MockDiamond internal diamond;

    address internal constant POOL_MANAGER = address(0xCAFE);
    address internal admin = makeAddr("admin");
    address internal attacker = makeAddr("attacker");
    address internal router = makeAddr("router");
    address internal usdc = address(0x10000);
    address internal yesLow = address(0x10000 - 1);
    address internal noToken = makeAddr("no");

    PoolKey internal key0;
    PoolId internal poolId0;

    SwapParams internal swap = SwapParams({zeroForOne: true, amountSpecified: -1e6, sqrtPriceLimitX96: 0});

    function setUp() public {
        diamond = new MockDiamond();
        hook = new TestHookHarness(IPoolManager(POOL_MANAGER));
        hook.initialize(address(diamond), admin, usdc);
        diamond.setMarket(1, yesLow, noToken, block.timestamp + 30 days, false, false);

        key0 = PoolKey({
            currency0: Currency.wrap(yesLow),
            currency1: Currency.wrap(usdc),
            fee: LPFeeLibrary.DYNAMIC_FEE_FLAG,
            tickSpacing: 60,
            hooks: IHooks(address(hook))
        });
        poolId0 = key0.toId();

        vm.prank(address(diamond));
        hook.registerMarketPool(1, key0);
    }

    function test_Revert_BeforeSwap_UntrustedCallerIsHardRejected() public {
        vm.expectRevert(abi.encodeWithSelector(IPrediXHook.Hook_UntrustedCaller.selector, attacker));
        hook.exposed_beforeSwap(attacker, key0, swap, "");
    }

    function test_Revert_BeforeSwap_TrustedRouterWithoutCommitIsHardRejected() public {
        vm.prank(admin);
        hook.setTrustedRouter(router, true);
        vm.expectRevert(IPrediXHook.Hook_MissingRouterCommit.selector);
        hook.exposed_beforeSwap(router, key0, swap, "");
    }

    function test_BeforeSwap_TrustedRouterWithCommit_Allowed() public {
        vm.prank(admin);
        hook.setTrustedRouter(router, true);
        vm.prank(router);
        hook.commitSwapIdentity(attacker, poolId0);
        // No revert; resolves to committed identity.
        hook.exposed_beforeSwap(router, key0, swap, "");
    }
}
