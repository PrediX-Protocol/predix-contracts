// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {ModifyLiquidityParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";

import {IMarketFacet} from "@predix/shared/interfaces/IMarketFacet.sol";
import {IEventFacet} from "@predix/shared/interfaces/IEventFacet.sol";

interface IPrediXHookRegister {
    function registerMarketPool(uint256 marketId, PoolKey calldata key) external;
}

interface IPoolModifyLiquidityTest {
    function modifyLiquidity(PoolKey memory key, ModifyLiquidityParams memory params, bytes memory hookData)
        external
        payable
        returns (int256 delta);
}

interface IAccessControlFacet {
    function hasRole(bytes32 role, address account) external view returns (bool);
}

/// @title PrediXMarketFactory
/// @notice Batches market creation + AMM pool setup into a single transaction.
///         Caller must have CREATOR_ROLE on Diamond and approve USDC to this
///         contract before calling. Holds zero funds between calls.
contract PrediXMarketFactory {
    using SafeERC20 for IERC20;

    bytes32 internal constant CREATOR_ROLE = keccak256("predix.role.creator");

    IPoolManager public immutable poolManager;
    address public immutable diamond;
    IERC20 public immutable usdc;
    address public immutable hook;
    IPoolModifyLiquidityTest public immutable lpTest;
    uint24 public immutable lpFeeFlag;
    int24 public immutable tickSpacing;

    uint160 internal constant SQRT_PRICE_MID_C0 = 56022770974786139918731938227;
    uint160 internal constant SQRT_PRICE_MID_C1 = 112045541949572279837463876454;
    int24 internal constant MIN_TICK_ALIGNED = -887220;
    int24 internal constant MAX_TICK_ALIGNED = 887220;

    error ZeroAddress();
    error RefundFailed();
    error NotCreator();

    modifier onlyCreator() {
        if (!IAccessControlFacet(diamond).hasRole(CREATOR_ROLE, msg.sender)) revert NotCreator();
        _;
    }

    event MarketCreatedWithPool(uint256 indexed marketId, uint256 liquidityDelta, address indexed creator);
    event EventCreatedWithPools(uint256 indexed eventId, uint256[] marketIds, uint256 liquidityDelta, address indexed creator);
    event LiquidityAdded(uint256 indexed marketId, uint256 liquidityDelta, address indexed provider);

    constructor(
        IPoolManager poolManager_,
        address diamond_,
        address usdc_,
        address hook_,
        address lpTest_,
        uint24 lpFeeFlag_,
        int24 tickSpacing_
    ) {
        if (address(poolManager_) == address(0) || diamond_ == address(0)) revert ZeroAddress();
        if (usdc_ == address(0) || hook_ == address(0) || lpTest_ == address(0)) revert ZeroAddress();

        poolManager = poolManager_;
        diamond = diamond_;
        usdc = IERC20(usdc_);
        hook = hook_;
        lpTest = IPoolModifyLiquidityTest(lpTest_);
        lpFeeFlag = lpFeeFlag_;
        tickSpacing = tickSpacing_;
    }

    /// @notice Create a binary market with AMM pool in a single transaction.
    /// @param question   Market question string.
    /// @param endTime    Market deadline (unix seconds).
    /// @param oracle     Oracle address (must be approved on Diamond).
    /// @param liquidityDelta  Uniswap v4 liquidity units for full-range LP.
    /// @param usdcBudget Max USDC the caller allows this call to spend (pulled via transferFrom).
    /// @return marketId  The on-chain market ID.
    function createMarketWithPool(
        string calldata question,
        uint256 endTime,
        address oracle,
        uint256 liquidityDelta,
        uint256 usdcBudget
    ) external onlyCreator returns (uint256 marketId) {
        usdc.safeTransferFrom(msg.sender, address(this), usdcBudget);

        marketId = IMarketFacet(diamond).createMarket(question, endTime, oracle);

        IMarketFacet.MarketView memory m = IMarketFacet(diamond).getMarket(marketId);
        _setupPool(marketId, m.yesToken, liquidityDelta);

        _refundAll(m.yesToken, m.noToken);
        emit MarketCreatedWithPool(marketId, liquidityDelta, msg.sender);
    }

    /// @notice Create a multi-outcome event with AMM pools for every child market.
    /// @param name             Event name.
    /// @param candidateQuestions  Question strings for each child market.
    /// @param endTime          Shared deadline for all children.
    /// @param liquidityDelta   Liquidity units per child pool.
    /// @param usdcBudget       Max USDC the caller allows (for all children combined).
    /// @return eventId   The on-chain event ID.
    /// @return marketIds The child market IDs.
    function createEventWithPools(
        string calldata name,
        string[] calldata candidateQuestions,
        uint256 endTime,
        uint256 liquidityDelta,
        uint256 usdcBudget
    ) external onlyCreator returns (uint256 eventId, uint256[] memory marketIds) {
        usdc.safeTransferFrom(msg.sender, address(this), usdcBudget);

        (eventId, marketIds) = IEventFacet(diamond).createEvent(name, candidateQuestions, endTime);

        uint256 perChild = usdc.balanceOf(address(this)) / marketIds.length;
        for (uint256 i; i < marketIds.length; ++i) {
            IMarketFacet.MarketView memory m = IMarketFacet(diamond).getMarket(marketIds[i]);
            _setupPoolBudgeted(marketIds[i], m.yesToken, liquidityDelta, perChild);
            _refundTokens(m.yesToken, m.noToken);
        }

        _refundUsdc();
        emit EventCreatedWithPools(eventId, marketIds, liquidityDelta, msg.sender);
    }

    /// @notice Add liquidity to an existing market's AMM pool.
    /// @param marketId       Target market (must already have pool registered + initialized).
    /// @param liquidityDelta Liquidity units to add (full-range).
    /// @param usdcBudget     Max USDC the caller allows.
    function addLiquidity(uint256 marketId, uint256 liquidityDelta, uint256 usdcBudget) external onlyCreator {
        usdc.safeTransferFrom(msg.sender, address(this), usdcBudget);

        IMarketFacet.MarketView memory m = IMarketFacet(diamond).getMarket(marketId);
        _splitAndAddLiquidity(marketId, m.yesToken, liquidityDelta, usdcBudget);

        _refundAll(m.yesToken, m.noToken);
        emit LiquidityAdded(marketId, liquidityDelta, msg.sender);
    }

    // =========================================================================
    // Internal
    // =========================================================================

    function _setupPool(uint256 marketId, address yesToken, uint256 liquidityDelta) internal {
        _initPool(marketId, yesToken);
        uint256 splitAmount = usdc.balanceOf(address(this));
        _splitAndAddLiquidity(marketId, yesToken, liquidityDelta, splitAmount);
    }

    function _setupPoolBudgeted(uint256 marketId, address yesToken, uint256 liquidityDelta, uint256 budget) internal {
        _initPool(marketId, yesToken);
        _splitAndAddLiquidity(marketId, yesToken, liquidityDelta, budget);
    }

    function _initPool(uint256 marketId, address yesToken) internal {
        PoolKey memory key = _buildPoolKey(yesToken);
        IPrediXHookRegister(hook).registerMarketPool(marketId, key);
        uint160 sqrtPrice = address(usdc) < yesToken ? SQRT_PRICE_MID_C1 : SQRT_PRICE_MID_C0;
        poolManager.initialize(key, sqrtPrice);
    }

    function _splitAndAddLiquidity(uint256 marketId, address yesToken, uint256 liquidityDelta, uint256 budget) internal {
        // Full-range LP at midpoint needs ~2/3 YES and ~1/3 USDC.
        // Split 75% of budget to YES+NO, keep 25% as USDC for LP.
        uint256 splitAmount = (budget * 3) / 4;
        usdc.forceApprove(diamond, splitAmount);
        IMarketFacet(diamond).splitPosition(marketId, splitAmount);

        IERC20(yesToken).forceApprove(address(lpTest), type(uint256).max);
        usdc.forceApprove(address(lpTest), type(uint256).max);

        PoolKey memory key = _buildPoolKey(yesToken);
        ModifyLiquidityParams memory params = ModifyLiquidityParams({
            tickLower: MIN_TICK_ALIGNED,
            tickUpper: MAX_TICK_ALIGNED,
            liquidityDelta: int256(liquidityDelta),
            salt: bytes32(0)
        });
        lpTest.modifyLiquidity(key, params, "");
    }

    function _buildPoolKey(address yesToken) internal view returns (PoolKey memory key) {
        address quote = address(usdc);
        (Currency c0, Currency c1) = quote < yesToken
            ? (Currency.wrap(quote), Currency.wrap(yesToken))
            : (Currency.wrap(yesToken), Currency.wrap(quote));
        key = PoolKey({
            currency0: c0,
            currency1: c1,
            fee: lpFeeFlag,
            tickSpacing: tickSpacing,
            hooks: IHooks(hook)
        });
    }

    function _refundAll(address yesToken, address noToken) internal {
        _refundTokens(yesToken, noToken);
        _refundUsdc();
    }

    function _refundTokens(address yesToken, address noToken) internal {
        uint256 yesBal = IERC20(yesToken).balanceOf(address(this));
        if (yesBal > 0) IERC20(yesToken).safeTransfer(msg.sender, yesBal);
        uint256 noBal = IERC20(noToken).balanceOf(address(this));
        if (noBal > 0) IERC20(noToken).safeTransfer(msg.sender, noBal);
    }

    function _refundUsdc() internal {
        uint256 usdcBal = usdc.balanceOf(address(this));
        if (usdcBal > 0) usdc.safeTransfer(msg.sender, usdcBal);
    }
}
