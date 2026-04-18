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

/// @notice PoolModifyLiquidityTest shape (subset) — periphery helper on Unichain Sepolia
///         at `0x5fa728c0a5cfd51bee4b060773f50554c0c8a7ab`. Return is v4-core's
///         `BalanceDelta` (int256 under the hood); we discard the value.
interface IPoolModifyLiquidityTest {
    function modifyLiquidity(PoolKey memory key, ModifyLiquidityParams memory params, bytes memory hookData)
        external
        payable
        returns (int256 delta);
}

/// @notice Phase 7 — end-to-end new-market bootstrap script.
/// @dev    Runs a single broadcast that:
///           1. createMarket(question, endTime, oracle)
///           2. hook.registerMarketPool(marketId, poolKey)
///           3. poolManager.initialize(poolKey, sqrtPriceX96 @ midpoint)
///           4. splitPosition to mint LP-funding YES + NO
///           5. Approve YES + USDC to PoolModifyLiquidityTest
///           6. addLiquidity around current tick
///         Emits all addresses + marketId on stdout for downstream indexing.
///
///         Required env vars (read via vm.envX):
///           - DEPLOYER_PRIVATE_KEY
///           - NEW_DIAMOND
///           - NEW_HOOK_PROXY
///           - NEW_MANUAL_ORACLE  (default oracle)
///           - POOL_MANAGER_ADDRESS
///           - USDC_ADDRESS
///
///         Optional env vars (with defaults):
///           - MARKET_QUESTION            default: "Phase 7 auto-created market"
///           - MARKET_END_OFFSET_SECONDS  default: 86400 (1 day)
///           - MARKET_ORACLE              default: NEW_MANUAL_ORACLE
///           - LP_USDC_AMOUNT             default: 10_000_000 (10 USDC, raw 6-dec)
///           - LP_LIQUIDITY_DELTA         default: 100_000_000 (1e8 raw liquidity)
///           - LP_TICK_RANGE              default: 600 (ticks either side of current)
contract Phase7CreateMarketFull is Script {
    // Periphery helper on Unichain Sepolia (shared by all v4 deployments there)
    address internal constant POOL_MODIFY_LIQUIDITY_TEST = 0x5fa728C0A5cfd51BEe4B060773f50554c0C8A7AB;

    // Hook's price window per FINAL-H11 is [_INIT_PRICE_MIN=475000, _INIT_PRICE_MAX=525000]
    // Exact midpoint yesPrice = 500_000 (= $0.50). sqrtPriceX96 values that produce yesPrice
    // exactly 500_000 for each currency ordering.
    //
    // Derivation (yesIsCurrency0 = true):
    //   yesPrice = priceToken1PerToken0
    //   priceToken1PerToken0 = 500_000
    //   priceX96 = 500_000 * 2^96 / 1e6 = 2^96 / 2 = 2^95
    //   sqrtPriceX96 = sqrt(2^95 * 2^96) = sqrt(2^191) = sqrt(2) * 2^95
    //                ≈ 56022770974786139918731938227
    uint160 internal constant SQRT_PRICE_MID_YES_CURRENCY0 = 56022770974786139918731938227;

    // Derivation (yesIsCurrency0 = false):
    //   yesPrice = PRICE_UNIT² / priceToken1PerToken0 = 500_000
    //   priceToken1PerToken0 = 2_000_000
    //   priceX96 = 2_000_000 * 2^96 / 1e6 = 2 * 2^96
    //   sqrtPriceX96 = sqrt(2 * 2^192) = sqrt(2) * 2^96
    //                ≈ 112045541949572279837463876454
    uint160 internal constant SQRT_PRICE_MID_YES_CURRENCY1 = 112045541949572279837463876454;

    // Market creation (proto) fee + dynamic-fee flag constants
    uint24 internal constant DYNAMIC_FEE_FLAG = LPFeeLibrary.DYNAMIC_FEE_FLAG; // 0x800000
    int24 internal constant TICK_SPACING = 60;

    // Current-tick approximation for midpoint price (log_{1.0001}(2) ≈ 6931 ticks)
    // Round to tickSpacing multiples of 60 on either side.
    int24 internal constant MIDPOINT_TICK_YES_CURRENCY1 = 6931; // rounded: 6900..6960 bracket
    int24 internal constant MIDPOINT_TICK_YES_CURRENCY0 = -6931; // mirror

    function run() external {
        Inputs memory i = _loadInputs();

        vm.startBroadcast(i.pk);

        // Step 1: create market
        uint256 marketId = IMarketFacet(i.diamond).createMarket(i.question, i.endTime, i.oracle);
        console2.log("Created market:", marketId);

        // Step 2: fetch YES/NO tokens + build PoolKey with canonical ordering
        IMarketFacet.MarketView memory mkt = IMarketFacet(i.diamond).getMarket(marketId);
        console2.log("YES token:", mkt.yesToken);
        console2.log("NO  token:", mkt.noToken);

        bool yesIsCurrency0 = mkt.yesToken < i.usdc;
        (address c0, address c1) = yesIsCurrency0 ? (mkt.yesToken, i.usdc) : (i.usdc, mkt.yesToken);

        PoolKey memory key = PoolKey({
            currency0: Currency.wrap(c0),
            currency1: Currency.wrap(c1),
            fee: DYNAMIC_FEE_FLAG,
            tickSpacing: TICK_SPACING,
            hooks: IHooks(i.hook)
        });

        // Step 3: register pool binding on hook (idempotent-guarded by hook)
        IPrediXHook(i.hook).registerMarketPool(marketId, key);
        console2.log("Pool registered with hook");

        // Step 4: initialize v4 pool at midpoint
        uint160 sqrtPriceX96 = yesIsCurrency0 ? SQRT_PRICE_MID_YES_CURRENCY0 : SQRT_PRICE_MID_YES_CURRENCY1;
        IPoolManager(i.poolManager).initialize(key, sqrtPriceX96);
        console2.log("Pool initialized at sqrtPriceX96 =", sqrtPriceX96);

        // Step 5: split USDC to get YES + NO for LP
        //   We need (roughly) LP_USDC_AMOUNT USDC + 2×LP_USDC_AMOUNT YES at midpoint 0.5
        //   Easier: split 2×LP_USDC_AMOUNT USDC → mints 2×LP_USDC_AMOUNT YES + 2×LP_USDC_AMOUNT NO,
        //   then keep LP_USDC_AMOUNT USDC + LP_USDC_AMOUNT YES for the position.
        //   (NO balance stays with deployer for future trading.)
        uint256 splitAmount = i.lpUsdcAmount * 2;
        IERC20(i.usdc).approve(i.diamond, splitAmount);
        IMarketFacet(i.diamond).splitPosition(marketId, splitAmount);
        console2.log("Split", splitAmount, "USDC to fund LP");

        // Step 6: approve tokens to PoolModifyLiquidityTest
        IERC20(mkt.yesToken).approve(POOL_MODIFY_LIQUIDITY_TEST, splitAmount);
        IERC20(i.usdc).approve(POOL_MODIFY_LIQUIDITY_TEST, i.lpUsdcAmount * 2);

        // Step 7: add liquidity around current tick
        int24 midTick = yesIsCurrency0 ? MIDPOINT_TICK_YES_CURRENCY0 : MIDPOINT_TICK_YES_CURRENCY1;
        int24 tickLower = _roundDownToSpacing(midTick - i.lpTickRange);
        int24 tickUpper = _roundUpToSpacing(midTick + i.lpTickRange);

        ModifyLiquidityParams memory params = ModifyLiquidityParams({
            tickLower: tickLower, tickUpper: tickUpper, liquidityDelta: int256(i.lpLiquidityDelta), salt: bytes32(0)
        });
        IPoolModifyLiquidityTest(POOL_MODIFY_LIQUIDITY_TEST).modifyLiquidity(key, params, "");
        console2.log("Liquidity added: L =", i.lpLiquidityDelta);
        console2.log("tickLower:", int256(tickLower));
        console2.log("tickUpper:", int256(tickUpper));

        vm.stopBroadcast();

        // Final summary
        console2.log("=========================================================");
        console2.log("PHASE 7 MARKET BOOTSTRAP COMPLETE");
        console2.log("=========================================================");
        console2.log("marketId:     ", marketId);
        console2.log("yesToken:     ", mkt.yesToken);
        console2.log("noToken:      ", mkt.noToken);
        console2.log("yesIsCurrency0:", yesIsCurrency0);
        console2.log("sqrtPriceX96: ", sqrtPriceX96);
        console2.log("tickLower:    ", int256(tickLower));
        console2.log("tickUpper:    ", int256(tickUpper));
        console2.log("=========================================================");
    }

    struct Inputs {
        uint256 pk;
        address diamond;
        address hook;
        address oracle;
        address poolManager;
        address usdc;
        string question;
        uint256 endTime;
        uint256 lpUsdcAmount;
        uint256 lpLiquidityDelta;
        int24 lpTickRange;
    }

    function _loadInputs() internal view returns (Inputs memory i) {
        i.pk = vm.envUint("DEPLOYER_PRIVATE_KEY");
        i.diamond = vm.envAddress("NEW_DIAMOND");
        i.hook = vm.envAddress("NEW_HOOK_PROXY");
        i.poolManager = vm.envAddress("POOL_MANAGER_ADDRESS");
        i.usdc = vm.envAddress("USDC_ADDRESS");
        i.oracle = vm.envOr("MARKET_ORACLE", vm.envAddress("NEW_MANUAL_ORACLE"));
        i.question = vm.envOr("MARKET_QUESTION", string("Phase 7 auto-created market"));
        uint256 offsetSec = vm.envOr("MARKET_END_OFFSET_SECONDS", uint256(86400));
        i.endTime = block.timestamp + offsetSec;
        i.lpUsdcAmount = vm.envOr("LP_USDC_AMOUNT", uint256(10_000_000)); // 10 USDC default
        i.lpLiquidityDelta = vm.envOr("LP_LIQUIDITY_DELTA", uint256(100_000_000)); // 1e8 default
        i.lpTickRange = int24(int256(vm.envOr("LP_TICK_RANGE", uint256(600)))); // ±600 ticks default
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
