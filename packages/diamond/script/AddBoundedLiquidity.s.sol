// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import {Script, console2} from "forge-std/Script.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {IMarketFacet} from "@predix/shared/interfaces/IMarketFacet.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {LPFeeLibrary} from "@uniswap/v4-core/src/libraries/LPFeeLibrary.sol";
import {ModifyLiquidityParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {LiquidityAmounts} from "@uniswap/v4-core/test/utils/LiquidityAmounts.sol";

interface IPoolModifyLiquidityTest {
    function modifyLiquidity(PoolKey memory key, ModifyLiquidityParams memory params, bytes memory hookData)
        external
        payable
        returns (int256 delta);
}

/// @notice Seed bounded YES/USDC liquidity in the price band [0.1, 0.9] for an explicit list of OPEN markets,
///         targeting USDC_RAW (= 20k) on the USDC leg of each position. For each pool: read the current
///         price, derive L from the USDC leg over the in-range sub-band (orientation-aware), mint the YES leg
///         via `splitPosition` (USDC -> YES + NO; the NO stays with the deployer), and add the position via a
///         `PoolModifyLiquidityTest` router. Read-only unless DO_BROADCAST=true. Ticks: YES-as-currency0 ->
///         [-23040, -1080]; YES-as-currency1 -> [1080, 23040] (mirror, price inverts).
/// @dev Required env: POOL_MANAGER_ADDRESS, HOOK_PROXY_ADDRESS, USDC_ADDRESS, DIAMOND_ADDRESS, LP_ADD_ROUTER,
///      LP_MARKETS (uint[]), LP_YESES (address[]), MNEMONIC (HD-0). Optional: DO_BROADCAST (default false).
contract AddBoundedLiquidity is Script {
    using StateLibrary for IPoolManager;
    using PoolIdLibrary for PoolKey;

    // USDC leg per pool is read per-run from env (USDC_LEG); defaults to 20k.
    int24 internal constant TICK_SPACING = 60;
    // Tick band per orientation is read per-run from env (TICK_C0_LOWER/UPPER, TICK_C1_LOWER/UPPER);
    // defaults = price [0.1, 0.9].

    function run() external {
        IPoolManager pm = IPoolManager(vm.envAddress("POOL_MANAGER_ADDRESS"));
        address hook = vm.envAddress("HOOK_PROXY_ADDRESS");
        address usdc = vm.envAddress("USDC_ADDRESS");
        address diamond = vm.envAddress("DIAMOND_ADDRESS");
        address router = vm.envAddress("LP_ADD_ROUTER");
        uint256[] memory mkts = vm.envUint("LP_MARKETS", ",");
        address[] memory yeses = vm.envAddress("LP_YESES", ",");
        require(mkts.length == yeses.length && mkts.length > 0, "bad arrays");
        bool doBroadcast = vm.envOr("DO_BROADCAST", false);
        uint256 USDC_RAW = vm.envOr("USDC_LEG", uint256(20_000e6));
        uint256 pk = vm.deriveKey(vm.envString("MNEMONIC"), uint32(vm.envOr("ADD_HD_INDEX", uint256(0))));
        address deployer = vm.addr(pk);
        int24 c0L = int24(vm.envOr("TICK_C0_LOWER", int256(-23040)));
        int24 c0U = int24(vm.envOr("TICK_C0_UPPER", int256(-1080)));
        int24 c1L = int24(vm.envOr("TICK_C1_LOWER", int256(1080)));
        int24 c1U = int24(vm.envOr("TICK_C1_UPPER", int256(23040)));

        uint256 usdcBefore = IERC20(usdc).balanceOf(deployer);
        uint256 added;
        uint256 skipped;
        uint256 totalYesMint;

        if (doBroadcast) {
            vm.startBroadcast(pk);
            IERC20(usdc).approve(diamond, type(uint256).max); // splitPosition pulls USDC
            IERC20(usdc).approve(router, type(uint256).max); // modifyLiquidity pulls USDC leg
        }

        for (uint256 i; i < mkts.length; ++i) {
            address yes = yeses[i];
            bool yesC0 = yes < usdc;
            (int24 tickLower, int24 tickUpper) = yesC0 ? (c0L, c0U) : (c1L, c1U);
            (address c0, address c1) = yesC0 ? (yes, usdc) : (usdc, yes);
            PoolKey memory key = PoolKey({
                currency0: Currency.wrap(c0),
                currency1: Currency.wrap(c1),
                fee: LPFeeLibrary.DYNAMIC_FEE_FLAG,
                tickSpacing: TICK_SPACING,
                hooks: IHooks(hook)
            });

            // Idempotency: if this router already holds a bounded position here, skip so a retried chunk
            // never double-mints/double-adds (unlike removal, add is not self-cancelling).
            (uint128 existing,,) = pm.getPositionInfo(key.toId(), router, tickLower, tickUpper, bytes32(0));
            if (existing > 0) {
                ++skipped;
                console2.log("  SKIP already-seeded market", mkts[i]);
                continue;
            }

            (uint160 sqrtCur,,,) = pm.getSlot0(key.toId());
            if (sqrtCur == 0) {
                ++skipped;
                console2.log("  SKIP uninit market", mkts[i]);
                continue;
            }
            uint160 sqrtA = TickMath.getSqrtPriceAtTick(tickLower);
            uint160 sqrtB = TickMath.getSqrtPriceAtTick(tickUpper);
            uint160 sqrtClamped = sqrtCur < sqrtA ? sqrtA : (sqrtCur > sqrtB ? sqrtB : sqrtCur);

            uint128 liq;
            uint256 yesLeg;
            if (yesC0) {
                // USDC (token1) occupies [sqrtA, sqrtClamped]; needs a non-degenerate sub-band (price > 0.1).
                if (sqrtClamped <= sqrtA) {
                    ++skipped;
                    console2.log("  SKIP price<=0.1 all-YES market", mkts[i]);
                    continue;
                }
                liq = LiquidityAmounts.getLiquidityForAmount1(sqrtA, sqrtClamped, USDC_RAW);
                yesLeg = sqrtClamped < sqrtB ? LiquidityAmounts.getAmount0ForLiquidity(sqrtClamped, sqrtB, liq) : 0;
            } else {
                // USDC (token0) occupies [sqrtClamped, sqrtB]; needs a non-degenerate sub-band.
                if (sqrtClamped >= sqrtB) {
                    ++skipped;
                    console2.log("  SKIP price out-of-band all-YES market", mkts[i]);
                    continue;
                }
                liq = LiquidityAmounts.getLiquidityForAmount0(sqrtClamped, sqrtB, USDC_RAW);
                yesLeg = sqrtClamped > sqrtA ? LiquidityAmounts.getAmount1ForLiquidity(sqrtA, sqrtClamped, liq) : 0;
            }
            if (liq == 0) {
                ++skipped;
                console2.log("  SKIP zero-liquidity market", mkts[i]);
                continue;
            }
            // +1% +1 USDC buffer so the router never reverts on a 1-wei rounding shortfall; leftover stays.
            uint256 yesMint = yesLeg + (yesLeg / 100) + 1e6;

            if (doBroadcast) {
                IMarketFacet(diamond).splitPosition(mkts[i], yesMint);
                IERC20(yes).approve(router, type(uint256).max);
                IPoolModifyLiquidityTest(router)
                    .modifyLiquidity(
                        key,
                        ModifyLiquidityParams({
                            tickLower: tickLower,
                            tickUpper: tickUpper,
                            liquidityDelta: int256(uint256(liq)),
                            salt: bytes32(0)
                        }),
                        ""
                    );
            }
            ++added;
            totalYesMint += yesMint;
            console2.log("  ADD market", mkts[i]);
            console2.log("     L / yesLeg / yesMint:", uint256(liq), yesLeg, yesMint);
        }

        if (doBroadcast) vm.stopBroadcast();

        console2.log("=== positions added:", added, "skipped:", skipped);
        console2.log("=== USDC-leg total (20k each):", added * USDC_RAW);
        console2.log("=== YES minted total (raw):", totalYesMint);
        console2.log("=== deployer USDC delta:", usdcBefore - IERC20(usdc).balanceOf(deployer));
    }
}
