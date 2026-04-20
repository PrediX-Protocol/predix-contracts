// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Script, console2} from "forge-std/Script.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {IMarketFacet} from "@predix/shared/interfaces/IMarketFacet.sol";
import {IEventFacet} from "@predix/shared/interfaces/IEventFacet.sol";
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

/// @notice TestUSDC open-faucet shape — testnet-only USDC with public mint.
interface ITestUSDC {
    function mint(address to, uint256 amount) external;
}

/// @notice Phase 7 — end-to-end multi-outcome event bootstrap.
/// @dev    Extends `Phase7CreateMarketFull` to the event layer:
///           1. Diamond.createEvent(name, candidateQuestions[], endTime)
///           2. For each child marketId in [0..BOOTSTRAP_POOL_COUNT): bootstrap pool
///              (register + initialize + split + seed LP).
///
///         Pool bootstrap is OPT-IN per child. Common pattern for multi-outcome
///         events: 3-5 viable candidates get pools, long-tail candidates stay
///         CLOB-only. Set BOOTSTRAP_POOL_COUNT=0 to skip pools entirely
///         (event + CLOB-only trading).
///
///         Required env vars:
///           - DEPLOYER_PRIVATE_KEY
///           - NEW_DIAMOND, NEW_HOOK_PROXY, POOL_MANAGER_ADDRESS, USDC_ADDRESS
///           - CANDIDATE_QUESTIONS         — comma-delimited list, e.g.
///                                            "Will A win?,Will B win?,Will C win?"
///
///         Optional env vars:
///           - EVENT_NAME                  default: "Phase 7 auto-created event"
///           - EVENT_END_OFFSET_SECONDS    default: 86400 (1 day — applied to all children)
///           - BOOTSTRAP_POOL_COUNT        default: 0 (no per-child pools)
///                                         Set to N to bootstrap pools for first N children.
///                                         If N > candidates.length, clamped.
///           - LP_USDC_AMOUNT              default: 10_000_000 (10 USDC per bootstrapped pool)
///           - LP_LIQUIDITY_DELTA          default: 100_000_000 (1e8 per pool)
///           - LP_TICK_RANGE               default: 600
///           - LP_FULL_RANGE               default: false. When true, each
///                                         bootstrapped child uses ticks
///                                         (MIN_TICK_ALIGNED, MAX_TICK_ALIGNED)
///                                         for always-available liquidity.
contract Phase7CreateEventFull is Script {
    address internal constant POOL_MODIFY_LIQUIDITY_TEST = 0x5fa728C0A5cfd51BEe4B060773f50554c0C8A7AB;

    // Hook FINAL-H11 window: yesPrice must land in [475_000, 525_000]. Exactly 500_000 at each ordering.
    uint160 internal constant SQRT_PRICE_MID_YES_CURRENCY0 = 56022770974786139918731938227;
    uint160 internal constant SQRT_PRICE_MID_YES_CURRENCY1 = 112045541949572279837463876454;

    uint24 internal constant DYNAMIC_FEE_FLAG = LPFeeLibrary.DYNAMIC_FEE_FLAG;
    int24 internal constant TICK_SPACING = 60;

    // log_{1.0001}(2) ≈ 6931 ticks — midpoint in each ordering
    int24 internal constant MIDPOINT_TICK_YES_CURRENCY1 = 6931;
    int24 internal constant MIDPOINT_TICK_YES_CURRENCY0 = -6931;

    // Canonical full-range bounds for tickSpacing=60 (v4 TickMath ±887272
    // aligned down to 887220).
    int24 internal constant MIN_TICK_ALIGNED = -887220;
    int24 internal constant MAX_TICK_ALIGNED = 887220;

    struct Inputs {
        uint256 pk;
        address diamond;
        address hook;
        address poolManager;
        address usdc;
        string eventName;
        string[] questions;
        uint256 endTime;
        uint256 bootstrapPoolCount;
        uint256 lpUsdcAmount;
        uint256 lpLiquidityDelta;
        int24 lpTickRange;
        bool lpFullRange;
    }

    function run() external {
        Inputs memory i = _loadInputs();

        // Each bootstrapped child consumes ~3×LP_USDC_AMOUNT USDC (2× split,
        // 1× LP). Children past BOOTSTRAP_POOL_COUNT are CLOB-only and cost
        // nothing extra. We top the deployer up via TestUSDC.mint when short
        // — same open faucet rationale as Phase7CreateMarketFull.
        uint256 pools = i.bootstrapPoolCount > i.questions.length ? i.questions.length : i.bootstrapPoolCount;
        address deployer = vm.addr(i.pk);

        vm.startBroadcast(i.pk);

        if (pools > 0) {
            // 3× for split+LP, +slack per pool for v4 full-range dust.
            uint256 needed = (i.lpUsdcAmount * 3 + i.lpUsdcAmount / 1000 + 1) * pools;
            uint256 bal = IERC20(i.usdc).balanceOf(deployer);
            if (bal < needed) {
                uint256 shortfall = needed - bal;
                console2.log("Deployer USDC short by:", shortfall, "-- auto-minting from TestUSDC");
                ITestUSDC(i.usdc).mint(deployer, shortfall);
            }
        }

        // Step 1: create event (creates N child markets atomically)
        (uint256 eventId, uint256[] memory marketIds) =
            IEventFacet(i.diamond).createEvent(i.eventName, i.questions, i.endTime);
        console2.log("Created eventId:", eventId);
        console2.log("Child market count:", marketIds.length);
        for (uint256 k = 0; k < marketIds.length; k++) {
            console2.log("  child", k, "marketId:", marketIds[k]);
        }

        // Step 2: bootstrap pools for first N children (opt-in via BOOTSTRAP_POOL_COUNT)
        uint256 poolsToBootstrap = i.bootstrapPoolCount > marketIds.length ? marketIds.length : i.bootstrapPoolCount;
        if (poolsToBootstrap > 0) {
            console2.log("Bootstrapping pools for first N children:", poolsToBootstrap);
            for (uint256 k = 0; k < poolsToBootstrap; k++) {
                _bootstrapChildPool(i, marketIds[k], k);
            }
        } else {
            console2.log("No per-child pools bootstrapped (CLOB-only mode)");
        }

        vm.stopBroadcast();

        // Final summary
        console2.log("=========================================================");
        console2.log("PHASE 7 EVENT BOOTSTRAP COMPLETE");
        console2.log("=========================================================");
        console2.log("eventId:            ", eventId);
        console2.log("candidates:         ", marketIds.length);
        console2.log("pools bootstrapped: ", poolsToBootstrap);
        console2.log("=========================================================");

        // Machine-parseable one-liner for bots/CI.
        console2.log(
            string.concat(
                "RESULT_JSON={\"eventId\":",
                vm.toString(eventId),
                ",\"marketIds\":",
                _uintArrayToJson(marketIds),
                ",\"bootstrappedPools\":",
                vm.toString(poolsToBootstrap),
                ",\"fullRange\":",
                i.lpFullRange ? "true" : "false",
                "}"
            )
        );
    }

    function _uintArrayToJson(uint256[] memory arr) internal pure returns (string memory) {
        if (arr.length == 0) return "[]";
        string memory out = "[";
        for (uint256 k = 0; k < arr.length; k++) {
            out = string.concat(out, vm.toString(arr[k]));
            if (k + 1 < arr.length) out = string.concat(out, ",");
        }
        return string.concat(out, "]");
    }

    function _bootstrapChildPool(Inputs memory i, uint256 marketId, uint256 childIndex) internal {
        console2.log("--- bootstrap child index", childIndex, "marketId:", marketId);

        IMarketFacet.MarketView memory mkt = IMarketFacet(i.diamond).getMarket(marketId);

        bool yesIsCurrency0 = mkt.yesToken < i.usdc;
        (address c0, address c1) = yesIsCurrency0 ? (mkt.yesToken, i.usdc) : (i.usdc, mkt.yesToken);
        PoolKey memory key = PoolKey({
            currency0: Currency.wrap(c0),
            currency1: Currency.wrap(c1),
            fee: DYNAMIC_FEE_FLAG,
            tickSpacing: TICK_SPACING,
            hooks: IHooks(i.hook)
        });

        // Register pool on hook
        IPrediXHook(i.hook).registerMarketPool(marketId, key);

        // Initialize pool at midpoint
        uint160 sqrtPriceX96 = yesIsCurrency0 ? SQRT_PRICE_MID_YES_CURRENCY0 : SQRT_PRICE_MID_YES_CURRENCY1;
        IPoolManager(i.poolManager).initialize(key, sqrtPriceX96);

        // Split to fund LP. 2× for midpoint balance + small slack for v4's
        // "round against LP" full-range dust (see Phase7CreateMarketFull).
        uint256 slack = i.lpUsdcAmount / 1000;
        if (slack == 0) slack = 1;
        uint256 splitAmount = i.lpUsdcAmount * 2 + slack;
        IERC20(i.usdc).approve(i.diamond, splitAmount);
        IMarketFacet(i.diamond).splitPosition(marketId, splitAmount);

        // Approve YES + USDC to LP helper. Max avoids v4 "round against LP"
        // dust reverting on an off-by-one allowance at full-range seeds.
        IERC20(mkt.yesToken).approve(POOL_MODIFY_LIQUIDITY_TEST, type(uint256).max);
        IERC20(i.usdc).approve(POOL_MODIFY_LIQUIDITY_TEST, type(uint256).max);

        // Add liquidity. Full-range mode uses v4's canonical min/max ticks so
        // the pool serves trades at any price; windowed mode keeps the
        // midpoint-centered concentrated LP used by smoke tests.
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
    }

    function _loadInputs() internal view returns (Inputs memory i) {
        i.pk = vm.envUint("DEPLOYER_PRIVATE_KEY");
        i.diamond = vm.envAddress("NEW_DIAMOND");
        i.hook = vm.envAddress("NEW_HOOK_PROXY");
        i.poolManager = vm.envAddress("POOL_MANAGER_ADDRESS");
        i.usdc = vm.envAddress("USDC_ADDRESS");
        i.eventName = vm.envOr("EVENT_NAME", string("Phase 7 auto-created event"));
        // CANDIDATE_QUESTIONS is required — comma-delimited list
        i.questions = vm.envString("CANDIDATE_QUESTIONS", ",");
        require(i.questions.length >= 2, "need >= 2 candidates for event");

        uint256 offsetSec = vm.envOr("EVENT_END_OFFSET_SECONDS", uint256(86400));
        i.endTime = block.timestamp + offsetSec;

        i.bootstrapPoolCount = vm.envOr("BOOTSTRAP_POOL_COUNT", uint256(0));
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
