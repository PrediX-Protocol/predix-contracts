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

/// @notice TestUSDC open-faucet shape — testnet-only. `USDC_ADDRESS` on
///         Unichain Sepolia points at a `TestUSDC` deployed under
///         packages/shared/src/tokens/TestUSDC (see DeployTestUSDC.s.sol)
///         which exposes `mint(address,uint256)` with no access control.
interface ITestUSDC {
    function mint(address to, uint256 amount) external;
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
///           - LP_FULL_RANGE              default: false. When true, ignores
///                                        LP_TICK_RANGE and seeds ticks to
///                                        (MIN_TICK_ALIGNED, MAX_TICK_ALIGNED)
///                                        for a v4 canonical full-range LP
///                                        (always-available liquidity, unbounded
///                                        price impact). Pair with a larger
///                                        LP_USDC_AMOUNT + LP_LIQUIDITY_DELTA.
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

    // v4 TickMath MIN/MAX are ±887272; aligned to tickSpacing=60 becomes
    // ±887220. These are the canonical full-range bounds for a 60-spacing
    // pool — using anything wider reverts inside PoolManager.
    int24 internal constant MIN_TICK_ALIGNED = -887220;
    int24 internal constant MAX_TICK_ALIGNED = 887220;

    function run() external {
        Inputs memory i = _loadInputs();

        // Preflight: deployer must hold enough USDC to split (2×LP_USDC_AMOUNT
        // + slack) + fund the LP side (up to LP_USDC_AMOUNT). USDC_ADDRESS on
        // Unichain Sepolia is a TestUSDC with an open `mint(address,uint256)`,
        // so we top the deployer up automatically instead of forcing a manual
        // step. Matches the `slack = lpUsdcAmount / 1000` used in step 5.
        uint256 needed = i.lpUsdcAmount * 3 + i.lpUsdcAmount / 1000 + 1;
        address deployer = vm.addr(i.pk);

        vm.startBroadcast(i.pk);

        uint256 bal = IERC20(i.usdc).balanceOf(deployer);
        if (bal < needed) {
            uint256 shortfall = needed - bal;
            console2.log("Deployer USDC short by:", shortfall, "-- auto-minting from TestUSDC");
            ITestUSDC(i.usdc).mint(deployer, shortfall);
        }

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
        //   Target LP at midpoint p=0.5 (full-range preset): ~LP_USDC_AMOUNT
        //   USDC + ~2×LP_USDC_AMOUNT YES. Split 2×LP_USDC_AMOUNT USDC →
        //   mints 2×LP_USDC_AMOUNT YES + 2×LP_USDC_AMOUNT NO. NO stays with
        //   deployer for future trading.
        //   Slack of LP_USDC_AMOUNT/1000 absorbs v4's "round against LP" dust
        //   at full-range seeds where the pool demands splitAmount + 1 raw.
        uint256 slack = i.lpUsdcAmount / 1000;
        if (slack == 0) slack = 1;
        uint256 splitAmount = i.lpUsdcAmount * 2 + slack;
        IERC20(i.usdc).approve(i.diamond, splitAmount);
        IMarketFacet(i.diamond).splitPosition(marketId, splitAmount);
        console2.log("Split", splitAmount, "USDC to fund LP");

        // Step 6: approve tokens to PoolModifyLiquidityTest. Use max so v4's
        // "round against LP" dust (e.g. pool pulls splitAmount + 1 for a
        // full-range seed at L = sqrt(x*y)) doesn't trip an off-by-one
        // ERC20InsufficientAllowance. Testnet helper, protocol-controlled
        // tokens — no counterparty risk to max approval.
        IERC20(mkt.yesToken).approve(POOL_MODIFY_LIQUIDITY_TEST, type(uint256).max);
        IERC20(i.usdc).approve(POOL_MODIFY_LIQUIDITY_TEST, type(uint256).max);

        // Step 7: add liquidity. Full-range mode bypasses the narrow
        // midpoint-centered window and uses v4's canonical min/max ticks so
        // the pool has liquidity at every reachable price — trades of any
        // size will fill (with proportional slippage) instead of reverting
        // on QuoteOutsideSafetyMargin when price drifts past the window.
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

        // Machine-parseable one-liner for bots/CI (grep on `RESULT_JSON=`).
        // Keep keys stable — downstream tooling parses them.
        console2.log(
            string.concat(
                "RESULT_JSON={\"marketId\":",
                vm.toString(marketId),
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
        bool lpFullRange;
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
