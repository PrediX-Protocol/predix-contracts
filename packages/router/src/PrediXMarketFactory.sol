// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";

import {IMarketFacet} from "@predix/shared/interfaces/IMarketFacet.sol";
import {IEventFacet} from "@predix/shared/interfaces/IEventFacet.sol";

interface IPrediXHookRegister {
    function registerMarketPool(uint256 marketId, PoolKey calldata key) external;
}

interface IAccessControlFacet {
    function hasRole(bytes32 role, address account) external view returns (bool);
}

/// @title PrediXMarketFactory
/// @notice Atomically deploys a binary market (or an N-candidate event) and
///         the corresponding Uniswap v4 pool(s) with the canonical PrediX hook
///         binding, in a single transaction. Liquidity provisioning is a
///         separate user step performed against the canonical v4 PositionManager
///         (the contract shipped in Uniswap's v4-periphery package).
///
/// @dev Audit M-05 (pass-2 closeout): the factory previously embedded a
///      `PoolModifyLiquidityTest` call inside `addLiquidity` /
///      `_splitAndAddLiquidity`. `PoolModifyLiquidityTest` is a v4-core test
///      harness and explicitly NOT meant for production — no NFT-based
///      position ownership, no Permit2 integration, no transferable LP
///      receipt. Mainnet operations route liquidity through the canonical
///      v4 PositionManager instead, so the factory's role narrows to the
///      market-creation primitives that need atomic ordering with hook
///      registration: `createMarket` (or `createEvent`) → `registerMarketPool`
///      → `poolManager.initialize`. Creators (or BE/FE tooling) call
///      PositionManager directly to seed liquidity afterwards using the
///      pool key emitted by this factory and the standard Permit2 flow.
///
///      Caller must have CREATOR_ROLE on Diamond. The factory holds zero
///      funds between calls. The only USDC pull is the pass-through that
///      lets the diamond charge `marketCreationFee` against the creator —
///      unused budget is refunded synchronously inside the same transaction.
contract PrediXMarketFactory {
    using SafeERC20 for IERC20;

    bytes32 internal constant CREATOR_ROLE = keccak256("predix.role.creator");

    IPoolManager public immutable poolManager;
    address public immutable diamond;
    IERC20 public immutable usdc;
    address public immutable hook;
    uint24 public immutable lpFeeFlag;
    int24 public immutable tickSpacing;

    /// @dev Canonical midpoint sqrtPriceX96 values for the 0.5/0.5 binary
    ///      initialization. Selected based on currency-ordering so the YES
    ///      token sits at the implied 50¢ regardless of address ordering.
    uint160 internal constant SQRT_PRICE_MID_C0 = 56022770974786139918731938227;
    uint160 internal constant SQRT_PRICE_MID_C1 = 112045541949572279837463876454;

    error ZeroAddress();
    error NotCreator();
    /// @notice Reverts when the factory constructor receives `lpFeeFlag_ == 0`.
    ///         Audit R-NEW-14 — mirrors the router's zero-check discipline.
    error InvalidLpFeeFlag();
    /// @notice Reverts when the factory constructor receives
    ///         `tickSpacing_ == 0`. Audit R-NEW-14.
    error InvalidTickSpacing();

    modifier onlyCreator() {
        if (!IAccessControlFacet(diamond).hasRole(CREATOR_ROLE, msg.sender)) revert NotCreator();
        _;
    }

    /// @notice Emitted when a binary market is atomically created and its
    ///         pool is registered + initialized. Liquidity provisioning is a
    ///         separate downstream step against the v4 PositionManager.
    event MarketCreatedWithPool(uint256 indexed marketId, address indexed creator);

    /// @notice Emitted when an event (N child markets) is atomically created
    ///         and every child's pool is registered + initialized.
    event EventCreatedWithPools(uint256 indexed eventId, uint256[] marketIds, address indexed creator);

    constructor(
        IPoolManager poolManager_,
        address diamond_,
        address usdc_,
        address hook_,
        uint24 lpFeeFlag_,
        int24 tickSpacing_
    ) {
        if (address(poolManager_) == address(0) || diamond_ == address(0)) revert ZeroAddress();
        if (usdc_ == address(0) || hook_ == address(0)) revert ZeroAddress();
        // Audit R-NEW-14: catch misdeployments at construction so the first
        // `_initPool` call cannot fail deep inside v4 PoolManager.initialize.
        if (lpFeeFlag_ == 0) revert InvalidLpFeeFlag();
        if (tickSpacing_ == 0) revert InvalidTickSpacing();

        poolManager = poolManager_;
        diamond = diamond_;
        usdc = IERC20(usdc_);
        hook = hook_;
        lpFeeFlag = lpFeeFlag_;
        tickSpacing = tickSpacing_;
    }

    /// @notice Create a binary market and atomically register + initialize
    ///         its AMM pool with the PrediX hook.
    /// @dev    Liquidity is NOT seeded by this call — the creator (or BE/FE
    ///         tooling) follows up by calling v4 PositionManager with the
    ///         pool key emitted via `MarketCreatedWithPool`. The pool key is
    ///         deterministic from `_buildPoolKey(yesToken)` so off-chain
    ///         tooling can reconstruct it from the marketId alone.
    /// @param  question    Market question string.
    /// @param  endTime     Market deadline (unix seconds).
    /// @param  oracle      Oracle address (must be approved on Diamond).
    /// @param  usdcBudget  Max USDC the caller allows this call to spend; any
    ///                     unused remainder is refunded synchronously. The
    ///                     diamond pulls `marketCreationFee` from this balance.
    /// @return marketId    The on-chain market ID.
    function createMarketWithPool(string calldata question, uint256 endTime, address oracle, uint256 usdcBudget)
        external
        onlyCreator
        returns (uint256 marketId)
    {
        if (usdcBudget > 0) usdc.safeTransferFrom(msg.sender, address(this), usdcBudget);
        usdc.forceApprove(diamond, usdcBudget);

        marketId = IMarketFacet(diamond).createMarket(question, endTime, oracle);

        IMarketFacet.MarketView memory m = IMarketFacet(diamond).getMarket(marketId);
        _initPool(marketId, m.yesToken);

        _settleResidualUsdc();
        emit MarketCreatedWithPool(marketId, msg.sender);
    }

    /// @notice Create an event with N binary child markets and atomically
    ///         register + initialize each child's pool with the PrediX hook.
    /// @dev    Liquidity is NOT seeded; see `createMarketWithPool` for the
    ///         downstream PositionManager flow.
    /// @param  name                Event name.
    /// @param  candidateQuestions  One question per candidate.
    /// @param  endTime             Shared deadline for all children.
    /// @param  oracle              Oracle (must implement IEventOracle).
    /// @param  usdcBudget          Max USDC the caller allows; diamond pulls
    ///                             `marketCreationFee` once per child.
    function createEventWithPools(
        string calldata name,
        string[] calldata candidateQuestions,
        uint256 endTime,
        address oracle,
        uint256 usdcBudget
    ) external onlyCreator returns (uint256 eventId, uint256[] memory marketIds) {
        if (usdcBudget > 0) usdc.safeTransferFrom(msg.sender, address(this), usdcBudget);
        usdc.forceApprove(diamond, usdcBudget);

        (eventId, marketIds) = IEventFacet(diamond).createEvent(name, candidateQuestions, endTime, oracle);

        for (uint256 i; i < marketIds.length; ++i) {
            IMarketFacet.MarketView memory m = IMarketFacet(diamond).getMarket(marketIds[i]);
            _initPool(marketIds[i], m.yesToken);
        }

        _settleResidualUsdc();
        emit EventCreatedWithPools(eventId, marketIds, msg.sender);
    }

    // =========================================================================
    // Internal
    // =========================================================================

    function _initPool(uint256 marketId, address yesToken) internal {
        PoolKey memory key = _buildPoolKey(yesToken);
        IPrediXHookRegister(hook).registerMarketPool(marketId, key);
        uint160 sqrtPrice = address(usdc) < yesToken ? SQRT_PRICE_MID_C1 : SQRT_PRICE_MID_C0;
        poolManager.initialize(key, sqrtPrice);
    }

    function _buildPoolKey(address yesToken) internal view returns (PoolKey memory key) {
        address quote = address(usdc);
        (Currency c0, Currency c1) = quote < yesToken
            ? (Currency.wrap(quote), Currency.wrap(yesToken))
            : (Currency.wrap(yesToken), Currency.wrap(quote));
        key = PoolKey({currency0: c0, currency1: c1, fee: lpFeeFlag, tickSpacing: tickSpacing, hooks: IHooks(hook)});
    }

    /// @dev Zero the diamond allowance and refund any remaining USDC back to
    ///      the caller. Defense-in-depth: `forceApprove(diamond, 0)` ensures
    ///      the factory never carries a standing allowance between calls,
    ///      and the synchronous refund keeps `factory.balanceOf(usdc) == 0`
    ///      between transactions.
    function _settleResidualUsdc() internal {
        usdc.forceApprove(diamond, 0);
        uint256 bal = usdc.balanceOf(address(this));
        if (bal > 0) usdc.safeTransfer(msg.sender, bal);
    }
}
