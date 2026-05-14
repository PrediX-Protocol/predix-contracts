// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import {Test} from "forge-std/Test.sol";

import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";

import {IPrediXHook} from "../../src/interfaces/IPrediXHook.sol";

import {MockDiamond} from "../utils/MockDiamond.sol";
import {TestHookHarness} from "../utils/TestHookHarness.sol";

/// @title N07_RegisterPoolFuzz
/// @notice Audit N-07 — broad fuzz coverage over `registerMarketPool` inputs.
///         The existing NEW-M4 suite covers each canonical dimension as a
///         single-axis happy/sad case. This file fuzzes the joint input space
///         to confirm no exotic combination slips past the canonical-key
///         guard and re-opens the front-run brick attack.
contract N07_RegisterPoolFuzz is Test {
    TestHookHarness internal hook;
    MockDiamond internal diamond;

    address internal constant POOL_MANAGER = address(0xCAFE);
    address internal admin = makeAddr("admin");
    address internal usdc = address(0x10000);
    address internal yesLow = address(0x10000 - 1);
    address internal noToken = makeAddr("no");
    address internal otherToken = makeAddr("other");

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

    /// @notice Any fee != CANONICAL_FEE must revert.
    function testFuzz_NonCanonicalFee_Reverts(uint24 fee) public {
        vm.assume(fee != CANONICAL_FEE);
        PoolKey memory key = _canonicalKey();
        key.fee = fee;
        vm.expectRevert(IPrediXHook.Hook_NonCanonicalFee.selector);
        hook.registerMarketPool(MARKET_ID, key);
    }

    /// @notice Any tick spacing != CANONICAL_TICK_SPACING must revert.
    function testFuzz_NonCanonicalTickSpacing_Reverts(int24 tickSpacing) public {
        vm.assume(tickSpacing != CANONICAL_TICK_SPACING);
        PoolKey memory key = _canonicalKey();
        key.tickSpacing = tickSpacing;
        vm.expectRevert(IPrediXHook.Hook_NonCanonicalTickSpacing.selector);
        hook.registerMarketPool(MARKET_ID, key);
    }

    /// @notice Any hooks address != this hook must revert.
    function testFuzz_WrongHookAddress_Reverts(address impostor) public {
        vm.assume(impostor != address(hook));
        PoolKey memory key = _canonicalKey();
        key.hooks = IHooks(impostor);
        vm.expectRevert(IPrediXHook.Hook_WrongHookAddress.selector);
        hook.registerMarketPool(MARKET_ID, key);
    }

    /// @notice Any currency pair that does not consist of the market's
    ///         (yesToken, quoteToken) must revert. Covers both single-side
    ///         mismatches (one token wrong) and double-side mismatches.
    function testFuzz_InvalidCurrencies_Reverts(address curr0, address curr1) public {
        // Exclude the two legitimate orderings to keep this test focused on
        // the failure surface. The canonical-orderings test below covers the
        // accepting branch.
        bool legitA = (curr0 == yesLow && curr1 == usdc);
        bool legitB = (curr0 == usdc && curr1 == yesLow);
        vm.assume(!legitA && !legitB);

        PoolKey memory key = _canonicalKey();
        key.currency0 = Currency.wrap(curr0);
        key.currency1 = Currency.wrap(curr1);
        vm.expectRevert(IPrediXHook.Hook_InvalidPoolCurrencies.selector);
        hook.registerMarketPool(MARKET_ID, key);
    }

    /// @notice Fuzz the marketId — any id without a deployed market on the
    ///         diamond must revert with `Hook_MarketNotFound`. Canonical keys
    ///         alone are not enough; the diamond must have minted the market.
    function testFuzz_UnknownMarketId_Reverts(uint256 marketId) public {
        vm.assume(marketId != MARKET_ID);
        vm.assume(marketId != 0); // marketId 0 is the "unregistered" sentinel
        PoolKey memory key = _canonicalKey();
        vm.expectRevert(IPrediXHook.Hook_MarketNotFound.selector);
        hook.registerMarketPool(marketId, key);
    }

    /// @notice Joint fuzz over (fee, tickSpacing, hookAddr). At least one
    ///         dimension departs from canonical → must revert. The selector
    ///         depends on which dimension is checked first, so this test
    ///         asserts only that SOME revert fires.
    function testFuzz_JointNonCanonical_Reverts(uint24 fee, int24 tickSpacing, address impostor) public {
        vm.assume(fee != CANONICAL_FEE || tickSpacing != CANONICAL_TICK_SPACING || impostor != address(hook));
        PoolKey memory key = _canonicalKey();
        key.fee = fee;
        key.tickSpacing = tickSpacing;
        key.hooks = IHooks(impostor);
        vm.expectRevert();
        hook.registerMarketPool(MARKET_ID, key);
    }

    /// @notice The accepting branch: only the two canonical orderings
    ///         (yes-as-currency0 or yes-as-currency1) succeed. Documents the
    ///         exact accept set so any future relaxation is caught by CI.
    function test_OnlyCanonicalOrderings_Succeed() public {
        // currency0 < currency1 is required by v4; we picked yesLow / usdc so
        // yesLow is currency0 in the canonical key.
        PoolKey memory key = _canonicalKey();
        hook.registerMarketPool(MARKET_ID, key);
        // Cannot re-register the same marketId, so spawn a second one.
        diamond.setMarket(2, otherToken, noToken, block.timestamp + 30 days, false, false);
        key = PoolKey({
            currency0: usdc < otherToken ? Currency.wrap(usdc) : Currency.wrap(otherToken),
            currency1: usdc < otherToken ? Currency.wrap(otherToken) : Currency.wrap(usdc),
            fee: CANONICAL_FEE,
            tickSpacing: CANONICAL_TICK_SPACING,
            hooks: hook
        });
        hook.registerMarketPool(2, key);
    }
}
