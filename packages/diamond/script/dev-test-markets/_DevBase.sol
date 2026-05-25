// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import {Script, console2} from "forge-std/Script.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {IPrediXHook} from "@predix/hook/interfaces/IPrediXHook.sol";

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {LPFeeLibrary} from "@uniswap/v4-core/src/libraries/LPFeeLibrary.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";

import {IPositionManager} from "v4-periphery/src/interfaces/IPositionManager.sol";
import {IPoolInitializer_v4} from "v4-periphery/src/interfaces/IPoolInitializer_v4.sol";
import {Actions} from "v4-periphery/src/libraries/Actions.sol";
import {LiquidityAmounts} from "v4-periphery/src/libraries/LiquidityAmounts.sol";

import {IAllowanceTransfer} from "permit2/src/interfaces/IAllowanceTransfer.sol";

/// @notice Shared helpers for diverse dev-test markets. Wraps the v4 PositionManager
///         LP-mint flow so each market script stays focused on its own setup logic.
abstract contract DevBase is Script {
    using SafeERC20 for IERC20;

    struct Ctx {
        address diamond;
        address exchange;
        address hook;
        address oracleManual;
        address usdc;
        address poolManager;
        address permit2;
        address positionManager;
        uint256 deployerKey;
        uint256 creatorKey;
        uint256 lpKey;
    }

    uint24 internal constant POOL_FEE = LPFeeLibrary.DYNAMIC_FEE_FLAG;
    int24 internal constant TICK_SPACING = 60;
    int24 internal constant TICK_LOWER = -887220;
    int24 internal constant TICK_UPPER = 887220;
    // Init tick = 6960 when USDC is currency0 (yesToken > usdc) ⇒ yesPrice ≈ 0.4986 (inside ±5%)
    // Init tick = -6960 when yesToken is currency0 ⇒ same price magnitude, opposite direction
    int24 internal constant INIT_TICK_YES_C1 = 6960;
    int24 internal constant INIT_TICK_YES_C0 = -6960;

    function _load() internal returns (Ctx memory c) {
        c.diamond = vm.envAddress("DIAMOND_ADDRESS");
        c.exchange = vm.envAddress("EXCHANGE_ADDRESS");
        c.hook = vm.envAddress("HOOK_PROXY_ADDRESS");
        c.oracleManual = vm.envAddress("ORACLE_MANUAL_ADDRESS");
        c.usdc = vm.envAddress("USDC_ADDRESS");
        c.poolManager = vm.envAddress("POOL_MANAGER_ADDRESS");
        c.permit2 = vm.envAddress("PERMIT2_ADDRESS");
        c.positionManager = vm.envAddress("POSITION_MANAGER_ADDRESS");

        string memory mnemonic = vm.envString("MNEMONIC");
        c.deployerKey = vm.deriveKey(mnemonic, 0);
        c.creatorKey = vm.deriveKey(mnemonic, 6);
        c.lpKey = vm.deriveKey(mnemonic, 9);
    }

    /// @notice Build canonical PoolKey for a market (yesToken + USDC, dynamic fee, this hook).
    function _buildPoolKey(Ctx memory c, address yesToken) internal pure returns (PoolKey memory key) {
        (address c0, address c1) = yesToken < c.usdc ? (yesToken, c.usdc) : (c.usdc, yesToken);
        key = PoolKey({
            currency0: Currency.wrap(c0),
            currency1: Currency.wrap(c1),
            fee: POOL_FEE,
            tickSpacing: TICK_SPACING,
            hooks: IHooks(c.hook)
        });
    }

    /// @notice Register pool binding on hook + initialize pool + mint full-range LP NFT
    ///         to LP wallet. Assumes LP already holds enough YES + USDC. Assumes LP
    ///         already approved YES + USDC to Permit2 + Permit2 → PositionManager.
    /// @param lpAddr LP wallet receiving the position NFT
    /// @param ammUsdcAmount USDC put into pool
    /// @param ammYesAmount YES put into pool (typically 2× USDC for 0.5 price)
    function _registerAndLpAmm(
        Ctx memory c,
        uint256 marketId,
        address yesToken,
        address lpAddr,
        uint256 ammUsdcAmount,
        uint256 ammYesAmount
    ) internal returns (PoolKey memory key, uint256 tokenId) {
        key = _buildPoolKey(c, yesToken);
        IPrediXHook(c.hook).registerMarketPool(marketId, key);

        int24 initTick = yesToken < c.usdc ? INIT_TICK_YES_C0 : INIT_TICK_YES_C1;
        uint160 sqrtPriceX96 = TickMath.getSqrtPriceAtTick(initTick);

        (uint256 amount0, uint256 amount1) =
            yesToken < c.usdc ? (ammYesAmount, ammUsdcAmount) : (ammUsdcAmount, ammYesAmount);

        uint128 liquidity = LiquidityAmounts.getLiquidityForAmounts(
            sqrtPriceX96,
            TickMath.getSqrtPriceAtTick(TICK_LOWER),
            TickMath.getSqrtPriceAtTick(TICK_UPPER),
            amount0,
            amount1
        );
        require(liquidity > 0, "computed liquidity is zero");

        bytes memory actions = abi.encodePacked(uint8(Actions.MINT_POSITION), uint8(Actions.SETTLE_PAIR));
        bytes[] memory params = new bytes[](2);
        params[0] = abi.encode(
            key, TICK_LOWER, TICK_UPPER, uint256(liquidity), uint128(amount0), uint128(amount1), lpAddr, bytes("")
        );
        params[1] = abi.encode(key.currency0, key.currency1);

        bytes[] memory calls = new bytes[](2);
        calls[0] = abi.encodeWithSelector(IPoolInitializer_v4.initializePool.selector, key, sqrtPriceX96);
        calls[1] = abi.encodeWithSelector(
            IPositionManager.modifyLiquidities.selector, abi.encode(actions, params), block.timestamp + 300
        );

        tokenId = IPositionManager(c.positionManager).nextTokenId();
        IPositionManager(c.positionManager).multicall(calls);
    }

    /// @notice Grant Permit2 + PositionManager allowances for both YES and USDC.
    ///         Idempotent — safe to call again with same params.
    function _grantPermit2(Ctx memory c, address yesToken) internal {
        IERC20(yesToken).forceApprove(c.permit2, type(uint256).max);
        IERC20(c.usdc).forceApprove(c.permit2, type(uint256).max);
        IAllowanceTransfer(c.permit2).approve(yesToken, c.positionManager, type(uint160).max, type(uint48).max);
        IAllowanceTransfer(c.permit2).approve(c.usdc, c.positionManager, type(uint160).max, type(uint48).max);
    }
}

interface ITestUSDCMint {
    function mint(address to, uint256 amount) external;
}
