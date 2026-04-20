// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Script, console2} from "forge-std/Script.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {IMarketFacet} from "@predix/shared/interfaces/IMarketFacet.sol";
import {IPrediXHook} from "@predix/hook/interfaces/IPrediXHook.sol";

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {LPFeeLibrary} from "@uniswap/v4-core/src/libraries/LPFeeLibrary.sol";
import {ModifyLiquidityParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";

interface IPoolModifyLiquidityTest {
    function modifyLiquidity(PoolKey memory key, ModifyLiquidityParams memory params, bytes memory hookData)
        external
        payable
        returns (int256 delta);
}

interface ITestUSDC {
    function mint(address to, uint256 amount) external;
}

/// @notice Phase 7 — add AMM liquidity to a single existing market (binary
///         or event-child) that was created CLOB-only.
///
/// @dev    Shares the same seed flow as Phase7CreateMarketFull but skips
///         market creation. Safe to re-run: `registerMarketPool` is guarded
///         idempotent by the hook, and `poolManager.initialize` is wrapped
///         in try/catch so running twice just appends LP at the existing
///         midpoint instead of reverting.
///
///         Required env vars:
///           - DEPLOYER_PRIVATE_KEY
///           - NEW_DIAMOND, NEW_HOOK_PROXY, POOL_MANAGER_ADDRESS, USDC_ADDRESS
///           - MARKET_ID (uint — the id you want to seed)
///
///         Optional env vars (same semantics as Phase7CreateMarketFull):
///           - LP_USDC_AMOUNT            default: 10_000_000 (10 USDC raw)
///           - LP_LIQUIDITY_DELTA        default: 100_000_000 (1e8)
///           - LP_TICK_RANGE             default: 600
///           - LP_FULL_RANGE             default: false (set true for the
///                                        10k USDC / 20k YES / p=0.5 preset)
contract Phase7BootstrapChildPool is Script {
    address internal constant POOL_MODIFY_LIQUIDITY_TEST = 0x5fa728C0A5cfd51BEe4B060773f50554c0C8A7AB;

    uint160 internal constant SQRT_PRICE_MID_YES_CURRENCY0 = 56022770974786139918731938227;
    uint160 internal constant SQRT_PRICE_MID_YES_CURRENCY1 = 112045541949572279837463876454;

    uint24 internal constant DYNAMIC_FEE_FLAG = LPFeeLibrary.DYNAMIC_FEE_FLAG;
    int24 internal constant TICK_SPACING = 60;

    int24 internal constant MIDPOINT_TICK_YES_CURRENCY1 = 6931;
    int24 internal constant MIDPOINT_TICK_YES_CURRENCY0 = -6931;

    int24 internal constant MIN_TICK_ALIGNED = -887220;
    int24 internal constant MAX_TICK_ALIGNED = 887220;

    struct Inputs {
        uint256 pk;
        address diamond;
        address hook;
        address poolManager;
        address usdc;
        uint256 marketId;
        uint256 lpUsdcAmount;
        uint256 lpLiquidityDelta;
        int24 lpTickRange;
        bool lpFullRange;
    }

    function run() external {
        Inputs memory i = _loadInputs();

        IMarketFacet.MarketView memory mkt = IMarketFacet(i.diamond).getMarket(i.marketId);
        require(mkt.yesToken != address(0), "marketId does not exist");

        bool yesIsCurrency0 = mkt.yesToken < i.usdc;
        (address c0, address c1) = yesIsCurrency0 ? (mkt.yesToken, i.usdc) : (i.usdc, mkt.yesToken);
        PoolKey memory key = PoolKey({
            currency0: Currency.wrap(c0),
            currency1: Currency.wrap(c1),
            fee: DYNAMIC_FEE_FLAG,
            tickSpacing: TICK_SPACING,
            hooks: IHooks(i.hook)
        });

        address deployer = vm.addr(i.pk);

        vm.startBroadcast(i.pk);

        // Auto-mint USDC shortfall (TestUSDC open faucet — same rationale as
        // the create scripts). 3×LP_USDC_AMOUNT covers 2× split + 1× LP, plus
        // slack for v4 full-range dust.
        uint256 needed = i.lpUsdcAmount * 3 + i.lpUsdcAmount / 1000 + 1;
        uint256 bal = IERC20(i.usdc).balanceOf(deployer);
        if (bal < needed) {
            uint256 shortfall = needed - bal;
            console2.log("Deployer USDC short by:", shortfall, "-- auto-minting from TestUSDC");
            ITestUSDC(i.usdc).mint(deployer, shortfall);
        }

        // Register pool on hook. Idempotent — hook guards duplicate binding.
        try IPrediXHook(i.hook).registerMarketPool(i.marketId, key) {
            console2.log("Pool registered on hook");
        } catch {
            console2.log("Pool already registered on hook - continuing");
        }

        // Initialize v4 pool at midpoint. Wrapped in try/catch so re-runs on
        // an already-initialized pool don't abort; we just append liquidity
        // at the current price in that case.
        uint160 sqrtPriceX96 = yesIsCurrency0 ? SQRT_PRICE_MID_YES_CURRENCY0 : SQRT_PRICE_MID_YES_CURRENCY1;
        try IPoolManager(i.poolManager).initialize(key, sqrtPriceX96) {
            console2.log("Pool initialized at sqrtPriceX96 =", sqrtPriceX96);
        } catch {
            console2.log("Pool already initialized - appending liquidity at current price");
        }

        // Split USDC to mint YES + NO for LP funding. +slack for v4's "round
        // against LP" dust at full-range seeds (see Phase7CreateMarketFull).
        uint256 slack = i.lpUsdcAmount / 1000;
        if (slack == 0) slack = 1;
        uint256 splitAmount = i.lpUsdcAmount * 2 + slack;
        IERC20(i.usdc).approve(i.diamond, splitAmount);
        IMarketFacet(i.diamond).splitPosition(i.marketId, splitAmount);

        // Approve tokens to PoolModifyLiquidityTest. Max avoids v4 "round
        // against LP" dust reverting on an off-by-one allowance at
        // full-range seeds.
        IERC20(mkt.yesToken).approve(POOL_MODIFY_LIQUIDITY_TEST, type(uint256).max);
        IERC20(i.usdc).approve(POOL_MODIFY_LIQUIDITY_TEST, type(uint256).max);

        // Resolve ticks.
        int24 tickLower;
        int24 tickUpper;
        if (i.lpFullRange) {
            tickLower = MIN_TICK_ALIGNED;
            tickUpper = MAX_TICK_ALIGNED;
        } else {
            int24 midTick = yesIsCurrency0 ? MIDPOINT_TICK_YES_CURRENCY0 : MIDPOINT_TICK_YES_CURRENCY1;
            tickLower = _roundDownToSpacing(midTick - i.lpTickRange);
            tickUpper = _roundUpToSpacing(midTick + i.lpTickRange);
        }

        ModifyLiquidityParams memory params = ModifyLiquidityParams({
            tickLower: tickLower,
            tickUpper: tickUpper,
            liquidityDelta: int256(i.lpLiquidityDelta),
            salt: bytes32(0)
        });
        IPoolModifyLiquidityTest(POOL_MODIFY_LIQUIDITY_TEST).modifyLiquidity(key, params, "");

        vm.stopBroadcast();

        console2.log("=========================================================");
        console2.log("PHASE 7 POOL BOOTSTRAP COMPLETE (existing market)");
        console2.log("=========================================================");
        console2.log("marketId:      ", i.marketId);
        console2.log("yesToken:      ", mkt.yesToken);
        console2.log("noToken:       ", mkt.noToken);
        console2.log("tickLower:     ", int256(tickLower));
        console2.log("tickUpper:     ", int256(tickUpper));
        console2.log("liquidity:     ", i.lpLiquidityDelta);
        console2.log("=========================================================");

        console2.log(
            string.concat(
                "RESULT_JSON={\"marketId\":",
                vm.toString(i.marketId),
                ",\"yesToken\":\"",
                vm.toString(mkt.yesToken),
                "\",\"noToken\":\"",
                vm.toString(mkt.noToken),
                "\",\"tickLower\":",
                vm.toString(int256(tickLower)),
                ",\"tickUpper\":",
                vm.toString(int256(tickUpper)),
                ",\"liquidity\":",
                vm.toString(i.lpLiquidityDelta),
                ",\"fullRange\":",
                i.lpFullRange ? "true" : "false",
                "}"
            )
        );
    }

    function _loadInputs() internal view returns (Inputs memory i) {
        i.pk = vm.envUint("DEPLOYER_PRIVATE_KEY");
        i.diamond = vm.envAddress("NEW_DIAMOND");
        i.hook = vm.envAddress("NEW_HOOK_PROXY");
        i.poolManager = vm.envAddress("POOL_MANAGER_ADDRESS");
        i.usdc = vm.envAddress("USDC_ADDRESS");
        i.marketId = vm.envUint("MARKET_ID");
        i.lpUsdcAmount = vm.envOr("LP_USDC_AMOUNT", uint256(10_000_000));
        i.lpLiquidityDelta = vm.envOr("LP_LIQUIDITY_DELTA", uint256(100_000_000));
        i.lpTickRange = int24(int256(vm.envOr("LP_TICK_RANGE", uint256(600))));
        i.lpFullRange = vm.envOr("LP_FULL_RANGE", false);
    }

    function _roundDownToSpacing(int24 tick) internal pure returns (int24) {
        int24 rem = tick % TICK_SPACING;
        if (rem == 0) return tick;
        return tick > 0 ? tick - rem : tick - rem - TICK_SPACING;
    }

    function _roundUpToSpacing(int24 tick) internal pure returns (int24) {
        int24 rem = tick % TICK_SPACING;
        if (rem == 0) return tick;
        return tick > 0 ? tick - rem + TICK_SPACING : tick - rem;
    }
}
