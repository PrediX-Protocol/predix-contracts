// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

/// @title IPrediXExchange
/// @notice Permissionless on-chain CLOB for PrediX binary prediction markets.
/// @dev Exchange is protocol infrastructure. No access control on the taker path.
///      Architecture mirrors Uniswap v4 PoolManager: permissionless core + optional Router.
interface IPrediXExchange {
    // ============ Enums ============

    /// @notice Trading sides for binary outcome markets.
    /// @dev BUY = acquire tokens, pay USDC. SELL = dispose tokens, receive USDC.
    enum Side {
        BUY_YES,
        SELL_YES,
        BUY_NO,
        SELL_NO
    }

    /// @notice Match type — determines token flow mechanism.
    enum MatchType {
        COMPLEMENTARY,
        MINT,
        MERGE
    }

    // ============ Structs ============

    /// @notice On-chain limit order — packed into 5 storage slots.
    /// @dev Slot 1: owner(20) + timestamp(8) + side(1) + cancelled(1) = 30 bytes
    ///      Slot 2: marketId(32)
    ///      Slot 3: price(32)
    ///      Slot 4: amount(32)
    ///      Slot 5: filled(16) + depositLocked(16) = 32 bytes
    struct Order {
        address owner;
        uint64 timestamp;
        Side side;
        bool cancelled;
        uint256 marketId;
        uint256 price;
        uint256 amount;
        uint128 filled;
        uint128 depositLocked;
    }

    /// @notice Aggregated depth at a single price level.
    struct PriceLevel {
        uint256 price;
        uint256 totalAmount;
    }

    // ============ Errors ============

    error InvalidPrice(uint256 price);
    error InvalidAmount();
    error ZeroAddress();

    error MarketNotFound();
    error MarketExpired();
    error MarketResolved();
    error MarketInRefundMode();
    error MarketPaused();

    error OrderNotFound();
    error NotOrderOwner();
    error OrderAlreadyCancelled();
    error OrderFullyFilled();
    error MaxOrdersExceeded();

    error SelfMatchNotAllowed();
    error DeadlineExpired(uint256 deadline, uint256 current);
    error InsufficientLiquidity();
    error Exchange_InsufficientBalanceForMint();
    error Exchange_QueueFull();
    /// @notice Thrown when `fillMarketOrder` is called with `taker != msg.sender`.
    ///         Prevents an attacker from spending a victim's USDC allowance to
    ///         the Exchange by passing `taker = victim, recipient = attacker`.
    error NotTaker();

    // ============ Events ============

    event OrderPlaced(
        bytes32 indexed orderId,
        uint256 indexed marketId,
        address indexed owner,
        Side side,
        uint256 price,
        uint256 amount
    );

    /// @notice Emitted per individual match (maker ↔ taker or maker ↔ maker).
    /// @dev takerOrderId = bytes32(0) for taker-path fills (fillMarketOrder).
    event OrderMatched(
        bytes32 indexed makerOrderId,
        bytes32 indexed takerOrderId,
        uint256 indexed marketId,
        MatchType matchType,
        uint256 amount,
        uint256 price
    );

    event OrderCancelled(bytes32 indexed orderId);

    /// @notice Emitted when maker-path synthetic match (MINT/MERGE) produces protocol surplus.
    event FeeCollected(uint256 indexed marketId, uint256 amount);

    /// @notice Emitted once per fillMarketOrder call — aggregate taker results.
    event TakerFilled(
        uint256 indexed marketId,
        address indexed taker,
        address indexed recipient,
        Side takerSide,
        uint256 totalFilled,
        uint256 totalCost,
        uint256 matchCount
    );

    // ============ Maker path ============

    /// @notice Place a limit order. Auto-matches against resting orders (COMPLEMENTARY + MINT + MERGE).
    /// @param marketId Target prediction market.
    /// @param side BUY_YES / SELL_YES / BUY_NO / SELL_NO.
    /// @param price Limit price in 6 decimals, multiple of $0.01 (range $0.01..$0.99).
    /// @param amount Number of outcome tokens (6 decimals).
    /// @return orderId Unique identifier.
    /// @return filledAmount Amount immediately filled via matching.
    function placeOrder(uint256 marketId, Side side, uint256 price, uint256 amount)
        external
        returns (bytes32 orderId, uint256 filledAmount);

    /// @notice Cancel an unfilled / partially-filled order. Returns the locked portion to the owner.
    /// @dev Owner can always cancel. Anyone can cancel on expired/resolved markets (keeper pattern).
    function cancelOrder(bytes32 orderId) external;

    // ============ Taker path (permissionless) ============

    /// @notice Fill a market order with 4-way waterfall routing.
    /// @dev Permissionless — no role gate, no `onlyRouter`. Any caller is valid,
    ///      but `taker` MUST equal `msg.sender` (E-02 fix). This prevents an
    ///      attacker from spending a victim's Exchange allowance by passing
    ///      `taker = victim, recipient = attacker`.
    ///      Upfront pull → loop → refund unused. Each iteration picks the cheapest of:
    ///        - COMPLEMENTARY (direct opposite-side match)
    ///        - SYNTHETIC (same-action opposite-token via MINT or MERGE)
    ///      Stops when orderbook exhausted, limitPrice crossed, amountIn consumed,
    ///      or maxFills reached.
    /// @param marketId Target market.
    /// @param takerSide What the taker wants to acquire/dispose.
    /// @param limitPrice BUY: max price per share. SELL: min price per share. Never crossed.
    /// @param amountIn Taker's input budget (USDC for buy, shares for sell).
    /// @param taker Address providing input funds (MUST equal `msg.sender`).
    /// @param recipient Address receiving output tokens (can differ from taker).
    /// @param maxFills Max iterations. 0 = DEFAULT_MAX_FILLS. No hard upper bound.
    /// @param deadline Transaction deadline. Reverts if expired.
    /// @return filled Total output delivered to recipient.
    /// @return cost Total input consumed from taker.
    function fillMarketOrder(
        uint256 marketId,
        Side takerSide,
        uint256 limitPrice,
        uint256 amountIn,
        address taker,
        address recipient,
        uint256 maxFills,
        uint256 deadline
    ) external returns (uint256 filled, uint256 cost);

    // ============ View functions ============

    /// @notice Simulate `fillMarketOrder` without execution.
    /// @dev Pure view. Uses virtual consumption tracking. Callers use `eth_call` (free) to preview.
    function previewFillMarketOrder(
        uint256 marketId,
        Side takerSide,
        uint256 limitPrice,
        uint256 amountIn,
        uint256 maxFills
    ) external view returns (uint256 filled, uint256 cost);

    function getBestPrices(uint256 marketId)
        external
        view
        returns (uint256 bestBidYes, uint256 bestAskYes, uint256 bestBidNo, uint256 bestAskNo);

    function getDepthAtPrice(uint256 marketId, Side side, uint256 price) external view returns (uint256 totalAmount);

    function getOrderBook(uint256 marketId, uint8 depth)
        external
        view
        returns (
            PriceLevel[] memory yesBids,
            PriceLevel[] memory yesAsks,
            PriceLevel[] memory noBids,
            PriceLevel[] memory noAsks
        );

    function getOrder(bytes32 orderId) external view returns (Order memory);
}
