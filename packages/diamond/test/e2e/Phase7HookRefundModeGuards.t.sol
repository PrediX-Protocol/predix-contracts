// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {LPFeeLibrary} from "@uniswap/v4-core/src/libraries/LPFeeLibrary.sol";
import {SwapParams, ModifyLiquidityParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";

import {IMarketFacet} from "@predix/shared/interfaces/IMarketFacet.sol";
import {IPrediXHook} from "@predix/hook/interfaces/IPrediXHook.sol";

import {Phase7ForkBase} from "./Phase7ForkBase.t.sol";

/// @notice Regression guards for H-H01 / A4: refund-mode blocks swap,
///         addLiquidity, and donate through the Hook. `removeLiquidity`
///         remains open so LPs always have an exit (not tested here since
///         it's a negative of the fix — covered in packages/hook unit suite).
contract Phase7HookRefundModeGuards is Phase7ForkBase {
    IMarketFacet internal market;
    IPrediXHook internal hook;

    function setUp() public virtual override {
        super.setUp();
        market = IMarketFacet(DIAMOND);
        hook = IPrediXHook(HOOK_PROXY);
    }

    // -----------------------------------------------------------------
    // Shared setup — create market, register pool binding, enable refund
    // -----------------------------------------------------------------

    function _primeMarketInRefundMode() internal returns (PoolKey memory key) {
        // Create a market and register its YES/USDC pool binding on the hook.
        vm.prank(MULTISIG);
        uint256 marketId = market.createMarket("refund mode guard", block.timestamp + 1 days, MANUAL_ORACLE);

        IMarketFacet.MarketView memory mkt = market.getMarket(marketId);
        address yesToken = mkt.yesToken;

        // Canonical ordering: currency0 < currency1 in v4.
        (address c0, address c1) = yesToken < USDC ? (yesToken, USDC) : (USDC, yesToken);
        key = PoolKey({
            currency0: Currency.wrap(c0),
            currency1: Currency.wrap(c1),
            fee: LPFeeLibrary.DYNAMIC_FEE_FLAG,
            tickSpacing: 60,
            hooks: IHooks(HOOK_PROXY)
        });

        hook.registerMarketPool(marketId, key);

        // Market must be past endTime for enableRefundMode to pass its gate.
        vm.warp(mkt.endTime + 1);
        vm.prank(MULTISIG);
        market.enableRefundMode(marketId);
    }

    // =================================================================
    // H-H01 — refund mode blocks swap
    // =================================================================

    function test_HH01_BeforeSwap_RefundMode_Reverts() public {
        PoolKey memory key = _primeMarketInRefundMode();

        SwapParams memory params = SwapParams({zeroForOne: true, amountSpecified: -1e6, sqrtPriceLimitX96: 4295128740});

        vm.prank(POOL_MANAGER);
        vm.expectRevert(IPrediXHook.Hook_MarketInRefundMode.selector);
        IHooks(HOOK_PROXY).beforeSwap(address(this), key, params, hex"");
    }

    // =================================================================
    // H-H01 — refund mode blocks addLiquidity
    // =================================================================

    function test_HH01_BeforeAddLiquidity_RefundMode_Reverts() public {
        PoolKey memory key = _primeMarketInRefundMode();

        ModifyLiquidityParams memory params =
            ModifyLiquidityParams({tickLower: -60, tickUpper: 60, liquidityDelta: 1e18, salt: bytes32(0)});

        vm.prank(POOL_MANAGER);
        vm.expectRevert(IPrediXHook.Hook_MarketInRefundMode.selector);
        IHooks(HOOK_PROXY).beforeAddLiquidity(address(this), key, params, hex"");
    }

    // =================================================================
    // H-H01 — refund mode blocks donate
    // =================================================================

    function test_HH01_BeforeDonate_RefundMode_Reverts() public {
        PoolKey memory key = _primeMarketInRefundMode();

        vm.prank(POOL_MANAGER);
        vm.expectRevert(IPrediXHook.Hook_MarketInRefundMode.selector);
        IHooks(HOOK_PROXY).beforeDonate(address(this), key, 1e6, 1e6, hex"");
    }
}
