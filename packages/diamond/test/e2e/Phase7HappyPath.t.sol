// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {IMarketFacet} from "@predix/shared/interfaces/IMarketFacet.sol";
import {IPrediXExchange} from "@predix/exchange/IPrediXExchange.sol";
import {IManualOracle} from "@predix/oracle/interfaces/IManualOracle.sol";
import {IPrediXHook} from "@predix/hook/interfaces/IPrediXHook.sol";

import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {LPFeeLibrary} from "@uniswap/v4-core/src/libraries/LPFeeLibrary.sol";

import {Phase7ForkBase} from "./Phase7ForkBase.t.sol";

/// @notice Happy-path flows that exercise the Phase 7 contracts end-to-end
///         without broadcasting. Each test is self-contained — creates its
///         own market, does the minimum setup, and asserts on concrete
///         on-chain state (balances, events, market view).
contract Phase7HappyPath is Phase7ForkBase {
    IMarketFacet internal market;
    IPrediXExchange internal exchange;
    IManualOracle internal manualOracle;
    IPrediXHook internal hook;

    function setUp() public virtual override {
        super.setUp();
        market = IMarketFacet(DIAMOND);
        exchange = IPrediXExchange(EXCHANGE);
        manualOracle = IManualOracle(MANUAL_ORACLE);
        hook = IPrediXHook(HOOK_PROXY);
    }

    // -----------------------------------------------------------------
    // Shared helpers
    // -----------------------------------------------------------------

    function _createMarket(string memory q, uint256 endOffset) internal returns (uint256 marketId) {
        vm.prank(MULTISIG);
        marketId = market.createMarket(q, block.timestamp + endOffset, MANUAL_ORACLE);
    }

    function _split(address user, uint256 marketId, uint256 amount) internal {
        deal(USDC, user, amount);
        vm.startPrank(user);
        IERC20(USDC).approve(DIAMOND, amount);
        market.splitPosition(marketId, amount);
        vm.stopPrank();
    }

    // =================================================================
    // D2.1 — createMarket
    // =================================================================

    function test_Phase7_CreateMarket_Ok() public {
        uint256 marketId = _createMarket("D2.1 market", 1 days);

        IMarketFacet.MarketView memory mkt = market.getMarket(marketId);
        assertEq(mkt.oracle, MANUAL_ORACLE);
        assertFalse(mkt.isResolved);
        assertFalse(mkt.refundModeActive);
        assertTrue(mkt.yesToken != address(0));
        assertTrue(mkt.noToken != address(0));
        assertEq(mkt.totalCollateral, 0);
    }

    // =================================================================
    // D2.2 — registerPool
    // =================================================================

    function test_Phase7_RegisterPool_Ok() public {
        uint256 marketId = _createMarket("D2.2 market", 1 days);
        IMarketFacet.MarketView memory mkt = market.getMarket(marketId);

        (address c0, address c1) = mkt.yesToken < USDC ? (mkt.yesToken, USDC) : (USDC, mkt.yesToken);
        PoolKey memory key = PoolKey({
            currency0: Currency.wrap(c0),
            currency1: Currency.wrap(c1),
            fee: LPFeeLibrary.DYNAMIC_FEE_FLAG,
            tickSpacing: 60,
            hooks: IHooks(HOOK_PROXY)
        });

        hook.registerMarketPool(marketId, key);

        // Pool binding is internal; assert it took by re-registering the
        // same key. The hook's uniqueness guard (poolId-first check order
        // per packages/hook/src/hooks/PrediXHookV2.sol:297) surfaces as
        // `Hook_PoolAlreadyRegistered`.
        vm.expectRevert(IPrediXHook.Hook_PoolAlreadyRegistered.selector);
        hook.registerMarketPool(marketId, key);
    }

    // =================================================================
    // D2.5 — placeLimitOrder
    // =================================================================

    function test_Phase7_PlaceLimitOrder_Ok() public {
        uint256 marketId = _createMarket("D2.5 market", 1 days);

        address maker = makeAddr("maker");
        uint256 budget = 100e6;
        deal(USDC, maker, budget);

        vm.startPrank(maker);
        IERC20(USDC).approve(EXCHANGE, budget);
        (bytes32 orderId, uint256 filled) = exchange.placeOrder(marketId, IPrediXExchange.Side.BUY_YES, 0.6e6, 10e6);
        vm.stopPrank();

        assertTrue(orderId != bytes32(0), "orderId should be set");
        assertEq(filled, 0, "no counter-order exists yet");
        IPrediXExchange.Order memory o = exchange.getOrder(orderId);
        assertEq(o.owner, maker);
        assertEq(o.amount, 10e6);
        assertEq(o.price, 0.6e6);
    }

    // =================================================================
    // D2.6 — matchOrders (complementary BUY_YES × SELL_YES at same price)
    // =================================================================

    function test_Phase7_MatchOrders_Ok() public {
        uint256 marketId = _createMarket("D2.6 market", 1 days);

        // Maker: split 10 USDC into 10 YES + 10 NO, then place SELL_YES at 0.5.
        address maker = makeAddr("maker");
        _split(maker, marketId, 10e6);

        IMarketFacet.MarketView memory mkt = market.getMarket(marketId);

        vm.startPrank(maker);
        IERC20(mkt.yesToken).approve(EXCHANGE, 10e6);
        exchange.placeOrder(marketId, IPrediXExchange.Side.SELL_YES, 0.5e6, 10e6);
        vm.stopPrank();

        // Taker: place BUY_YES at 0.5, same amount → COMPLEMENTARY match.
        address taker = makeAddr("taker");
        deal(USDC, taker, 10e6);
        vm.startPrank(taker);
        IERC20(USDC).approve(EXCHANGE, 10e6);
        (, uint256 filled) = exchange.placeOrder(marketId, IPrediXExchange.Side.BUY_YES, 0.5e6, 10e6);
        vm.stopPrank();

        assertEq(filled, 10e6, "match should fill entire cross");
        assertEq(IERC20(mkt.yesToken).balanceOf(taker), 10e6, "taker receives YES");
    }

    // =================================================================
    // D2.7 — cancelOrder refunds escrow
    // =================================================================

    function test_Phase7_CancelOrder_Ok() public {
        uint256 marketId = _createMarket("D2.7 market", 1 days);

        address maker = makeAddr("maker");
        uint256 budget = 50e6;
        deal(USDC, maker, budget);

        vm.startPrank(maker);
        IERC20(USDC).approve(EXCHANGE, budget);
        (bytes32 orderId,) = exchange.placeOrder(marketId, IPrediXExchange.Side.BUY_YES, 0.5e6, 20e6);
        uint256 afterPlace = IERC20(USDC).balanceOf(maker);

        exchange.cancelOrder(orderId);
        uint256 afterCancel = IERC20(USDC).balanceOf(maker);
        vm.stopPrank();

        assertLt(afterPlace, budget, "escrow should have been deducted");
        assertEq(afterCancel, budget, "cancel should refund full escrow");
    }

    // =================================================================
    // D2.8 — split + merge round trip preserves USDC
    // =================================================================

    function test_Phase7_SplitMerge_Ok() public {
        uint256 marketId = _createMarket("D2.8 market", 1 days);
        IMarketFacet.MarketView memory mkt = market.getMarket(marketId);

        address user = makeAddr("split_merge_user");
        uint256 amount = 50e6;
        deal(USDC, user, amount);

        vm.startPrank(user);
        IERC20(USDC).approve(DIAMOND, amount);
        market.splitPosition(marketId, amount);
        assertEq(IERC20(mkt.yesToken).balanceOf(user), amount, "YES minted");
        assertEq(IERC20(mkt.noToken).balanceOf(user), amount, "NO minted");
        assertEq(IERC20(USDC).balanceOf(user), 0, "USDC escrowed");

        market.mergePositions(marketId, amount);
        assertEq(IERC20(mkt.yesToken).balanceOf(user), 0, "YES burned");
        assertEq(IERC20(mkt.noToken).balanceOf(user), 0, "NO burned");
        assertEq(IERC20(USDC).balanceOf(user), amount, "USDC returned");
        vm.stopPrank();
    }

    // =================================================================
    // D2.9 — ManualOracle report → resolveMarket → redeem
    // =================================================================

    function test_Phase7_ResolveMarket_Oracle_Ok() public {
        uint256 marketId = _createMarket("D2.9 market", 1 hours);
        IMarketFacet.MarketView memory mkt = market.getMarket(marketId);

        address holder = makeAddr("yes_holder");
        uint256 amount = 30e6;
        _split(holder, marketId, amount);

        // Past endTime, reporter submits outcome, anyone resolves.
        vm.warp(mkt.endTime + 1);
        vm.prank(REPORTER_ADDR);
        manualOracle.report(marketId, true);
        market.resolveMarket(marketId);

        IMarketFacet.MarketView memory resolved = market.getMarket(marketId);
        assertTrue(resolved.isResolved, "market should be resolved");
        assertTrue(resolved.outcome, "outcome is YES");

        // Holder redeems winning YES position — gets USDC minus default redemption fee.
        uint256 before = IERC20(USDC).balanceOf(holder);
        vm.prank(holder);
        uint256 payout = market.redeem(marketId);
        uint256 afterBal = IERC20(USDC).balanceOf(holder);
        assertEq(afterBal - before, payout, "redeem delta matches return value");
        assertGt(payout, 0, "winner should receive payout");
        // Default redemption fee is 0 per testnet config (see testenv.local).
        assertEq(payout, amount, "zero-fee redeem pays full winning side");
    }
}
