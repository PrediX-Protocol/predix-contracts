// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Script, console2} from "forge-std/Script.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {IMarketFacet} from "@predix/shared/interfaces/IMarketFacet.sol";
import {IPrediXHook} from "@predix/hook/interfaces/IPrediXHook.sol";

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {LPFeeLibrary} from "@uniswap/v4-core/src/libraries/LPFeeLibrary.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";

import {IPositionManager} from "v4-periphery/src/interfaces/IPositionManager.sol";
import {IPoolInitializer_v4} from "v4-periphery/src/interfaces/IPoolInitializer_v4.sol";
import {Actions} from "v4-periphery/src/libraries/Actions.sol";
import {LiquidityAmounts} from "v4-periphery/src/libraries/LiquidityAmounts.sol";

import {IAllowanceTransfer} from "permit2/src/interfaces/IAllowanceTransfer.sol";

/// @notice Phase 7 Unichain Sepolia — seed the first prediction market, register its
///         v4 pool, initialize the pool, and mint a full-range AMM position. Executes
///         the four steps atomically in a single broadcast. Fails fast on any revert.
contract SeedFirstMarket is Script {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;
    using SafeERC20 for IERC20;

    uint24 internal constant POOL_FEE = LPFeeLibrary.DYNAMIC_FEE_FLAG;
    int24 internal constant TICK_SPACING = 60;
    // Full-range ticks aligned to spacing=60. MIN_TICK=-887272, MAX_TICK=887272.
    // Nearest usable bounds that are multiples of 60: ±887220.
    int24 internal constant TICK_LOWER = -887220;
    int24 internal constant TICK_UPPER = 887220;

    // Initial price tick. The hook enforces FINAL-H11: implied YES price must
    // land in [475_000, 525_000] (±5% around 0.5 in 1e6 pip). When USDC sorts as
    // currency0 and yesToken as currency1 (this deploy: USDC=0x2D56… <
    // yesToken), the hook computes yesPrice = 1e12 / (p_real * 1e6), so we need
    // p_real ≈ 2 → sqrtPrice at tick ≈ 6931. The nearest multiple of 60 that
    // keeps yesPrice inside the window is 6960 (yesPrice ≈ 498_593, ~0.28%
    // below the midpoint). A symmetric 1:1 pool (tick 0) would trip the window
    // because it implies a "100% YES" starting price.
    int24 internal constant INIT_TICK_YES_CURRENCY1 = 6960;
    // If instead yesToken sorts as currency0, tick must be negative so the
    // currency1/currency0 price is ~0.5 → p_real ≈ 0.5 → tick ≈ -6931.
    // Nearest multiple of 60 inside the window: -6960.
    int24 internal constant INIT_TICK_YES_CURRENCY0 = -6960;

    // Market seed parameters.
    string internal constant QUESTION = "Will ETH close above $3,500 on 2026-05-01 UTC?";
    // 2026-05-01 00:00:00 UTC unix seconds (verified via Python datetime).
    uint256 internal constant MARKET_END_TIME = 1777593600;

    // Collateral budget split between the protocol and the AMM seed.
    // The AMM seed ratio is asymmetric because the initial pool price is 0.5
    // USDC per YES (i.e. 2 raw yesToken per 1 raw USDC). A balanced full-range
    // deposit at this price takes 2× as much yesToken as USDC.
    uint256 internal constant SPLIT_AMOUNT = 400e6; // 400 USDC → 400 YES + 400 NO
    uint256 internal constant AMM_USDC_AMOUNT = 100e6; // 100 USDC into AMM
    uint256 internal constant AMM_YES_AMOUNT = 200e6; // 200 YES into AMM (= 2 × USDC side)

    struct Env {
        address deployer;
        uint256 pk;
        address diamond;
        address hook;
        address manualOracle;
        address usdc;
        address poolManager;
        address permit2;
        address positionManager;
    }

    function run() external {
        Env memory e = _loadEnv();

        require(block.timestamp < MARKET_END_TIME, "market endTime already in the past");
        uint256 preUsdc = IERC20(e.usdc).balanceOf(e.deployer);
        console2.log("deployer             =", e.deployer);
        console2.log("USDC balance pre     =", preUsdc);
        require(preUsdc >= SPLIT_AMOUNT, "deployer USDC balance insufficient for 400 USDC split");

        vm.startBroadcast(e.pk);
        (uint256 marketId, address yesToken) = _step1CreateMarket(e);
        _step2Split(e, marketId);
        PoolKey memory key = _step3RegisterPool(e, marketId, yesToken);
        uint256 expectedTokenId = _step4InitAndMint(e, key, yesToken);
        vm.stopBroadcast();

        _postAssertions(e, marketId, key, expectedTokenId);
        console2.log("done: marketId       =", marketId);
    }

    function _loadEnv() internal view returns (Env memory e) {
        e.pk = vm.envUint("DEPLOYER_PRIVATE_KEY");
        e.deployer = vm.addr(e.pk);
        e.diamond = vm.envAddress("NEW_DIAMOND");
        e.hook = vm.envAddress("NEW_HOOK_PROXY");
        e.manualOracle = vm.envAddress("NEW_MANUAL_ORACLE");
        e.usdc = vm.envAddress("USDC_ADDRESS");
        e.poolManager = vm.envAddress("POOL_MANAGER_ADDRESS");
        e.permit2 = vm.envAddress("PERMIT2_ADDRESS");
        e.positionManager = vm.envAddress("POSITION_MANAGER_ADDRESS");
    }

    function _step1CreateMarket(Env memory e) internal returns (uint256 marketId, address yesToken) {
        marketId = IMarketFacet(e.diamond).createMarket(QUESTION, MARKET_END_TIME, e.manualOracle);
        IMarketFacet.MarketView memory mkt = IMarketFacet(e.diamond).getMarket(marketId);
        require(mkt.yesToken != address(0) && mkt.noToken != address(0), "market creation returned zero tokens");
        yesToken = mkt.yesToken;
        console2.log("step1: marketId      =", marketId);
        console2.log("step1: yesToken      =", mkt.yesToken);
        console2.log("step1: noToken       =", mkt.noToken);
    }

    function _step2Split(Env memory e, uint256 marketId) internal {
        IERC20(e.usdc).forceApprove(e.diamond, SPLIT_AMOUNT);
        IMarketFacet(e.diamond).splitPosition(marketId, SPLIT_AMOUNT);
        console2.log("step2: split amount  =", SPLIT_AMOUNT);
    }

    function _step3RegisterPool(Env memory e, uint256 marketId, address yesToken)
        internal
        returns (PoolKey memory key)
    {
        (address c0, address c1) = yesToken < e.usdc ? (yesToken, e.usdc) : (e.usdc, yesToken);
        key = PoolKey({
            currency0: Currency.wrap(c0),
            currency1: Currency.wrap(c1),
            fee: POOL_FEE,
            tickSpacing: TICK_SPACING,
            hooks: IHooks(e.hook)
        });
        IPrediXHook(e.hook).registerMarketPool(marketId, key);
        PoolId poolId = key.toId();
        console2.log("step3: poolId        =", uint256(PoolId.unwrap(poolId)));
    }

    function _step4InitAndMint(Env memory e, PoolKey memory key, address yesToken)
        internal
        returns (uint256 expectedTokenId)
    {
        // Pick initial tick so yesPrice lands inside the hook's window around 0.5.
        // Depends on which side yesToken sorts to (see constants).
        int24 initTick = yesToken < e.usdc ? INIT_TICK_YES_CURRENCY0 : INIT_TICK_YES_CURRENCY1;
        uint160 sqrtPriceX96 = TickMath.getSqrtPriceAtTick(initTick);

        // When yesToken is currency1, price ≈ 2 means we need 2× yesToken vs
        // USDC for balanced full-range liquidity. When yesToken is currency0,
        // price ≈ 0.5 means we need 2× yesToken vs USDC on the other side.
        // Either way, amount0 is the lower-address token and amount1 the higher.
        (uint256 amount0, uint256 amount1) =
            yesToken < e.usdc ? (AMM_YES_AMOUNT, AMM_USDC_AMOUNT) : (AMM_USDC_AMOUNT, AMM_YES_AMOUNT);

        uint128 liquidity = LiquidityAmounts.getLiquidityForAmounts(
            sqrtPriceX96,
            TickMath.getSqrtPriceAtTick(TICK_LOWER),
            TickMath.getSqrtPriceAtTick(TICK_UPPER),
            amount0,
            amount1
        );
        require(liquidity > 0, "computed liquidity is zero");

        _grantPermit2(e, yesToken);

        bytes[] memory calls = _buildMulticallCalls(e, key, sqrtPriceX96, liquidity, amount0, amount1);

        expectedTokenId = IPositionManager(e.positionManager).nextTokenId();
        IPositionManager(e.positionManager).multicall(calls);

        console2.log("step4: liquidity     =", uint256(liquidity));
        console2.log("step4: tokenId       =", expectedTokenId);
    }

    function _grantPermit2(Env memory e, address yesToken) internal {
        // Classical v4 periphery path: ERC20.approve(permit2) then
        // Permit2.approve(token, positionManager). Use max uint160/uint48
        // for single-session usage (testnet seed is one-shot).
        IERC20(yesToken).forceApprove(e.permit2, type(uint256).max);
        IERC20(e.usdc).forceApprove(e.permit2, type(uint256).max);
        IAllowanceTransfer(e.permit2).approve(yesToken, e.positionManager, type(uint160).max, type(uint48).max);
        IAllowanceTransfer(e.permit2).approve(e.usdc, e.positionManager, type(uint160).max, type(uint48).max);
    }

    function _buildMulticallCalls(
        Env memory e,
        PoolKey memory key,
        uint160 sqrtPriceX96,
        uint128 liquidity,
        uint256 amount0,
        uint256 amount1
    ) internal view returns (bytes[] memory calls) {
        bytes memory actions = abi.encodePacked(uint8(Actions.MINT_POSITION), uint8(Actions.SETTLE_PAIR));
        bytes[] memory params = new bytes[](2);
        params[0] = abi.encode(
            key, TICK_LOWER, TICK_UPPER, uint256(liquidity), uint128(amount0), uint128(amount1), e.deployer, bytes("")
        );
        params[1] = abi.encode(key.currency0, key.currency1);

        calls = new bytes[](2);
        calls[0] = abi.encodeWithSelector(IPoolInitializer_v4.initializePool.selector, key, sqrtPriceX96);
        calls[1] = abi.encodeWithSelector(
            IPositionManager.modifyLiquidities.selector, abi.encode(actions, params), block.timestamp + 300
        );
    }

    function _postAssertions(Env memory e, uint256 marketId, PoolKey memory key, uint256 expectedTokenId)
        internal
        view
    {
        PoolId poolId = key.toId();
        (uint160 postSqrtPriceX96, int24 postTick,,) = IPoolManager(e.poolManager).getSlot0(poolId);
        require(postSqrtPriceX96 != 0, "pool slot0 still zero after initializePool");

        uint256 nextAfter = IPositionManager(e.positionManager).nextTokenId();
        require(nextAfter == expectedTokenId + 1, "position NFT was not minted");

        IMarketFacet.MarketView memory mktAfter = IMarketFacet(e.diamond).getMarket(marketId);
        require(mktAfter.totalCollateral == SPLIT_AMOUNT, "totalCollateral mismatch after split");

        console2.log("post: sqrtPriceX96   =", uint256(postSqrtPriceX96));
        console2.log("post: tick           =", int256(postTick));
        console2.log("post: totalCollat    =", mktAfter.totalCollateral);
    }
}
