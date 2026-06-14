// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

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
        bytes32 builder;
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
    error NotTaker();
    error Exchange_EmptyArray();
    error Exchange_BatchTooLarge();
    error Exchange_NothingToClaim();
    error Exchange_RegistryNotSet();
    error Exchange_ProtocolRecipientNotSet();

    // ============ Events ============

    event OrderPlaced(
        bytes32 indexed orderId,
        uint256 indexed marketId,
        address indexed owner,
        Side side,
        uint256 price,
        uint256 amount,
        bytes32 builder
    );

    /// @notice Emitted per individual match (maker ↔ taker or maker ↔ maker).
    /// @dev takerOrderId = bytes32(0) for taker-path fills (fillMarketOrder).
    event OrderMatched(
        bytes32 indexed makerOrderId,
        bytes32 indexed takerOrderId,
        uint256 indexed marketId,
        MatchType matchType,
        uint256 amount,
        uint256 price,
        bytes32 makerBuilder,
        bytes32 takerBuilder
    );

    event OrderCancelled(bytes32 indexed orderId);

    /// @notice Emitted when maker-path synthetic match (MINT/MERGE) produces protocol surplus.
    event FeeCollected(uint256 indexed marketId, uint256 amount);

    /// @notice Builder fee credited to a code's accrual ledger (per-fill or per-deposit).
    event BuilderFeeAccrued(bytes32 indexed code, uint256 amount);
    /// @notice Builder fee claimed out to the registry-defined recipient.
    event BuilderFeeClaimed(bytes32 indexed code, address indexed recipient, uint256 amount);
    /// @notice Exchange rebind to a BuilderRegistry.
    event BuilderRegistrySet(address indexed prev, address indexed cur);

    /// @notice Protocol fee charged on a single CLOB fill. `fee == rebate + treasury` (P1).
    ///         `matchType` 0=COMPLEMENTARY 1=MINT 2=MERGE; `p` is the traded-side price.
    event ProtocolFeeCharged(
        uint256 indexed marketId,
        address taker,
        address maker,
        bytes32 makerOrderId,
        uint256 fee,
        uint256 rebate,
        uint256 treasury,
        uint256 p,
        uint8 matchType,
        bytes32 takerBuilder,
        bytes32 makerBuilder
    );
    /// @notice Accrued protocol-fee treasury cut swept to the recipient.
    event ProtocolFeeSwept(address indexed recipient, uint256 amount);
    /// @notice Protocol-fee recipient rotated.
    event ProtocolFeeRecipientSet(address indexed prev, address indexed cur);

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
    /// @param builder Optional affiliate/builder tag (bytes32(0) = no attribution).
    /// @return orderId Unique identifier.
    /// @return filledAmount Amount immediately filled via matching.
    function placeOrder(uint256 marketId, Side side, uint256 price, uint256 amount, bytes32 builder)
        external
        returns (bytes32 orderId, uint256 filledAmount);

    /// @notice Cancel an unfilled / partially-filled order. Returns the locked portion to the owner.
    /// @dev Owner can always cancel. Anyone can cancel on expired/resolved markets (keeper pattern).
    function cancelOrder(bytes32 orderId) external;

    /// @notice Cancel multiple orders in a single transaction. Partial success —
    ///         skips invalid / already-cancelled / fully-filled orders, and orders
    ///         the caller may not cancel, without reverting. The owner may cancel
    ///         their own orders any time; on a terminal market (resolved / refund /
    ///         expired) a keeper may cancel anyone's orders. Refunds always go to
    ///         the order owner.
    /// @param orderIds Array of order IDs to cancel. Max 50 per batch.
    /// @return cancelledCount Number of orders successfully cancelled.
    function cancelOrders(bytes32[] calldata orderIds) external returns (uint256 cancelledCount);

    // ============ Taker path (permissionless) ============

    /// @notice Fill a market order with 4-way waterfall routing.
    /// @dev Permissionless — no role gate, no `onlyRouter`. Any caller is valid,
    ///      but `taker` MUST equal `msg.sender`. This prevents an attacker from
    ///      spending a victim's Exchange allowance by passing
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
        uint256 deadline,
        bytes32 takerBuilder
    ) external returns (uint256 filled, uint256 cost);

    // ============ View functions ============

    /// @notice Simulate `fillMarketOrder` without execution.
    /// @dev Pure view. Uses virtual consumption tracking. Callers use `eth_call` (free) to preview.
    /// @dev `taker` parameter mirrors `fillMarketOrder`'s self-match skip so
    ///      preview output matches the real call when the caller is the FIFO head
    ///      of an opposite-side level. Pass `address(0)` to disable the filter.
    function previewFillMarketOrder(
        uint256 marketId,
        Side takerSide,
        uint256 limitPrice,
        uint256 amountIn,
        uint256 maxFills,
        address taker
    ) external view returns (uint256 filled, uint256 cost);

    /// @notice Protocol fee `ΣF` the matching `fillMarketOrder` would charge (BUY marginal clamp / per-fill
    ///         SELL). Builder fee excluded (router/plain path uses `builder=0`). For integrator net-of-fee
    ///         quoting: BUY net shares = `previewFillMarketOrder.filled`; SELL net USDC = `filled − protocolFee`.
    function previewProtocolFee(
        uint256 marketId,
        Side takerSide,
        uint256 limitPrice,
        uint256 amountIn,
        uint256 maxFills,
        address taker
    ) external view returns (uint256 protocolFee);

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
