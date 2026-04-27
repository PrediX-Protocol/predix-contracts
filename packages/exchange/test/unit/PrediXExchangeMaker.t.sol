// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {IPrediXExchange} from "../../src/IPrediXExchange.sol";

import {ExchangeTestBase} from "../base/ExchangeTestBase.sol";

/// @title PrediXExchangeMakerTest
/// @notice Unit tests for `placeOrder` and `cancelOrder`, plus the maker-side
///         audit fixes: H-01 (M1) `userOrderCount` decrement, H-02 (M2)
///         permissionless cancel on terminal markets, M4 `uint128` bound, and
///         M5 queue cleanup discipline (`_peekBest` is O(1) after cleanup).
contract PrediXExchangeMakerTest is ExchangeTestBase {
    // ============ placeOrder happy paths ============

    function test_PlaceOrder_Smoke_Buy() public {
        bytes32 id = _placeBuyYes(alice, 500_000, 100 * ONE_SHARE);
        IPrediXExchange.Order memory ord = exchange.getOrder(id);
        assertEq(ord.owner, alice);
        assertEq(ord.amount, 100 * ONE_SHARE);
        assertEq(ord.depositLocked, 50 * ONE_SHARE);
        assertEq(exchange.userOrderCount(MARKET_ID, alice), 1);
        assertEq(exchange.priceBitmap(MARKET_ID, IPrediXExchange.Side.BUY_YES), uint256(1) << 49);
    }

    function test_PlaceOrder_Sell() public {
        bytes32 id = _placeSellYes(alice, 500_000, 100 * ONE_SHARE);
        IPrediXExchange.Order memory ord = exchange.getOrder(id);
        assertEq(ord.depositLocked, 100 * ONE_SHARE);
    }

    function test_PlaceOrder_OrderPlacedEvent() public {
        _giveUsdc(alice, 50 * ONE_SHARE);
        vm.expectEmit(false, true, true, true);
        emit IPrediXExchange.OrderPlaced(
            bytes32(0), MARKET_ID, alice, IPrediXExchange.Side.BUY_YES, 500_000, 100 * ONE_SHARE
        );
        vm.prank(alice);
        exchange.placeOrder(MARKET_ID, IPrediXExchange.Side.BUY_YES, 500_000, 100 * ONE_SHARE);
    }

    // ============ placeOrder revert paths ============

    function test_Revert_PlaceOrder_InvalidPrice_Zero() public {
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(IPrediXExchange.InvalidPrice.selector, 0));
        exchange.placeOrder(MARKET_ID, IPrediXExchange.Side.BUY_YES, 0, 100 * ONE_SHARE);
    }

    function test_Revert_PlaceOrder_InvalidPrice_AtPrecision() public {
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(IPrediXExchange.InvalidPrice.selector, 1e6));
        exchange.placeOrder(MARKET_ID, IPrediXExchange.Side.BUY_YES, 1e6, 100 * ONE_SHARE);
    }

    function test_Revert_PlaceOrder_InvalidPrice_NotTickAligned() public {
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(IPrediXExchange.InvalidPrice.selector, 500_001));
        exchange.placeOrder(MARKET_ID, IPrediXExchange.Side.BUY_YES, 500_001, 100 * ONE_SHARE);
    }

    function test_Revert_PlaceOrder_InvalidAmount_Zero() public {
        vm.prank(alice);
        vm.expectRevert(IPrediXExchange.InvalidAmount.selector);
        exchange.placeOrder(MARKET_ID, IPrediXExchange.Side.BUY_YES, 500_000, 0);
    }

    function test_Revert_PlaceOrder_InvalidAmount_BelowMin() public {
        vm.prank(alice);
        vm.expectRevert(IPrediXExchange.InvalidAmount.selector);
        exchange.placeOrder(MARKET_ID, IPrediXExchange.Side.BUY_YES, 500_000, ONE_SHARE - 1);
    }

    /// @notice M4: `amount > type(uint128).max` reverts.
    function test_Revert_PlaceOrder_AmountExceedsUint128() public {
        vm.prank(alice);
        vm.expectRevert(IPrediXExchange.InvalidAmount.selector);
        exchange.placeOrder(MARKET_ID, IPrediXExchange.Side.BUY_YES, 500_000, uint256(type(uint128).max) + 1);
    }

    function test_Revert_PlaceOrder_MarketExpired() public {
        diamond.setMarketEndTime(MARKET_ID, block.timestamp);
        _giveUsdc(alice, 50 * ONE_SHARE);
        vm.prank(alice);
        vm.expectRevert(IPrediXExchange.MarketExpired.selector);
        exchange.placeOrder(MARKET_ID, IPrediXExchange.Side.BUY_YES, 500_000, 100 * ONE_SHARE);
    }

    function test_Revert_PlaceOrder_MarketResolved() public {
        diamond.setMarketResolved(MARKET_ID, true);
        _giveUsdc(alice, 50 * ONE_SHARE);
        vm.prank(alice);
        vm.expectRevert(IPrediXExchange.MarketResolved.selector);
        exchange.placeOrder(MARKET_ID, IPrediXExchange.Side.BUY_YES, 500_000, 100 * ONE_SHARE);
    }

    function test_Revert_PlaceOrder_MarketRefundMode() public {
        diamond.setMarketRefundMode(MARKET_ID, true);
        _giveUsdc(alice, 50 * ONE_SHARE);
        vm.prank(alice);
        vm.expectRevert(IPrediXExchange.MarketInRefundMode.selector);
        exchange.placeOrder(MARKET_ID, IPrediXExchange.Side.BUY_YES, 500_000, 100 * ONE_SHARE);
    }

    function test_Revert_PlaceOrder_MarketNotFound() public {
        vm.prank(alice);
        vm.expectRevert(IPrediXExchange.MarketNotFound.selector);
        exchange.placeOrder(999, IPrediXExchange.Side.BUY_YES, 500_000, 100 * ONE_SHARE);
    }

    function test_Revert_PlaceOrder_MaxOrdersExceeded() public {
        _giveUsdc(alice, 1000 * ONE_SHARE);
        for (uint256 i; i < 50; ++i) {
            vm.prank(alice);
            exchange.placeOrder(MARKET_ID, IPrediXExchange.Side.BUY_YES, 100_000 + (i % 9) * 10_000, ONE_SHARE);
        }
        vm.prank(alice);
        vm.expectRevert(IPrediXExchange.MaxOrdersExceeded.selector);
        exchange.placeOrder(MARKET_ID, IPrediXExchange.Side.BUY_YES, 500_000, ONE_SHARE);
    }

    // ============ Phase A complementary auto-match (with price improvement) ============

    function test_PlaceOrder_PhaseA_PriceImprovementRefund() public {
        _placeSellYes(alice, 500_000, 100 * ONE_SHARE);
        _giveUsdc(bob, 60 * ONE_SHARE);

        vm.prank(bob);
        exchange.placeOrder(MARKET_ID, IPrediXExchange.Side.BUY_YES, 600_000, 100 * ONE_SHARE);

        // Bob locked 60, used 50, refunded 10.
        assertEq(_usdcBalance(bob), 10 * ONE_SHARE);
        assertEq(_yesBalance(bob), 100 * ONE_SHARE);
        assertEq(_usdcBalance(alice), 50 * ONE_SHARE);
    }

    /// @notice Phase A self-match between maker order and the placer is skipped
    ///         silently — the placer's order rests rather than reverting.
    function test_PlaceOrder_PhaseA_SelfMatchSkipped() public {
        bytes32 sellId = _placeSellYes(alice, 500_000, 100 * ONE_SHARE);
        // Alice now buys above her own ask — self-match should be skipped, order rests.
        _giveUsdc(alice, 60 * ONE_SHARE);
        vm.prank(alice);
        (bytes32 buyId, uint256 filled) =
            exchange.placeOrder(MARKET_ID, IPrediXExchange.Side.BUY_YES, 600_000, 100 * ONE_SHARE);
        assertEq(filled, 0, "no fill (self-match)");
        // Both orders alive.
        assertEq(exchange.getOrder(sellId).filled, 0);
        assertEq(exchange.getOrder(buyId).filled, 0);
    }

    // ============ Phase B MINT (taker gets price improvement) ============

    function test_PlaceOrder_PhaseB_MintTakerImprovement() public {
        // Alice BUY_NO $0.40, Bob BUY_YES $0.65. MINT match.
        // Bob effective price = $0.60 (complement of $0.40).
        // Improvement = $0.05 per share = $5 total → refunded to Bob.
        _placeBuyNo(alice, 400_000, 100 * ONE_SHARE);
        _giveUsdc(bob, 65 * ONE_SHARE);

        vm.prank(bob);
        exchange.placeOrder(MARKET_ID, IPrediXExchange.Side.BUY_YES, 650_000, 100 * ONE_SHARE);

        assertEq(_yesBalance(bob), 100 * ONE_SHARE);
        assertEq(_noBalance(alice), 100 * ONE_SHARE);
        assertEq(_usdcBalance(bob), 5 * ONE_SHARE, "$5 improvement to taker");
        assertEq(_usdcBalance(feeRecipient), 0, "no surplus to feeRecipient");
    }

    // ============ Phase B MERGE — taker gets price improvement (X1) ============

    function test_PlaceOrder_PhaseB_MergeTakerImprovement() public {
        // X1 (§BACKLOG 2026-04-21): the MERGE path now passes the improvement
        // to the taker. Alice maker SELL_NO @ 0.40, Bob taker SELL_YES @ 0.55.
        // Merge proceeds = $100. Maker gets its limit $40. Taker gets the
        // complement $60 = fillAmt - makerPayout (not its own $55 limit) —
        // same behaviour as the taker-path fillMarketOrder already exhibits
        // (see PrediXExchangeTaker.test_fillMarketOrder_syntheticMergeOnly).
        // Surplus = 0 → no FeeCollected emit in the MERGE path.
        _placeSellNo(alice, 400_000, 100 * ONE_SHARE);
        _giveYesNo(bob, 100 * ONE_SHARE);

        vm.prank(bob);
        exchange.placeOrder(MARKET_ID, IPrediXExchange.Side.SELL_YES, 550_000, 100 * ONE_SHARE);

        assertEq(_usdcBalance(bob), 60 * ONE_SHARE, "taker gets complement $60, not limit $55");
        assertEq(_usdcBalance(alice), 40 * ONE_SHARE, "maker gets its limit $40");
        assertEq(_usdcBalance(feeRecipient), 0, "no surplus in MERGE path post-X1");
    }

    // ============ cancelOrder happy paths + audit M2 ============

    function test_CancelOrder_OwnerAnytime() public {
        bytes32 id = _placeBuyYes(alice, 500_000, 100 * ONE_SHARE);
        uint256 before = _usdcBalance(alice);

        vm.prank(alice);
        exchange.cancelOrder(id);

        assertEq(_usdcBalance(alice), before + 50 * ONE_SHARE);
        assertEq(exchange.getOrder(id).cancelled, true);
        assertEq(exchange.userOrderCount(MARKET_ID, alice), 0);
        assertEq(exchange.priceBitmap(MARKET_ID, IPrediXExchange.Side.BUY_YES), 0);
    }

    function test_CancelOrder_PermissionlessAfterExpiry() public {
        bytes32 id = _placeBuyYes(alice, 500_000, 100 * ONE_SHARE);
        diamond.setMarketEndTime(MARKET_ID, block.timestamp); // expired

        vm.prank(carol); // keeper, not owner
        exchange.cancelOrder(id);

        // Refund went to the OWNER (alice), not the keeper.
        assertEq(_usdcBalance(alice), 50 * ONE_SHARE);
        assertEq(_usdcBalance(carol), 0);
    }

    function test_CancelOrder_PermissionlessAfterResolution() public {
        bytes32 id = _placeBuyYes(alice, 500_000, 100 * ONE_SHARE);
        diamond.setMarketResolved(MARKET_ID, true);

        vm.prank(carol);
        exchange.cancelOrder(id);
        assertEq(_usdcBalance(alice), 50 * ONE_SHARE);
    }

    function test_CancelOrder_PermissionlessDuringRefundMode() public {
        bytes32 id = _placeBuyYes(alice, 500_000, 100 * ONE_SHARE);
        diamond.setMarketRefundMode(MARKET_ID, true);

        vm.prank(carol);
        exchange.cancelOrder(id);
        assertEq(_usdcBalance(alice), 50 * ONE_SHARE);
    }

    function test_Revert_CancelOrder_NonOwnerOnActiveMarket() public {
        bytes32 id = _placeBuyYes(alice, 500_000, 100 * ONE_SHARE);
        vm.prank(carol);
        vm.expectRevert(IPrediXExchange.NotOrderOwner.selector);
        exchange.cancelOrder(id);
    }

    function test_Revert_CancelOrder_OrderNotFound() public {
        vm.prank(alice);
        vm.expectRevert(IPrediXExchange.OrderNotFound.selector);
        exchange.cancelOrder(bytes32(uint256(0xdead)));
    }

    function test_Revert_CancelOrder_AlreadyCancelled() public {
        bytes32 id = _placeBuyYes(alice, 500_000, 100 * ONE_SHARE);
        vm.prank(alice);
        exchange.cancelOrder(id);
        vm.prank(alice);
        vm.expectRevert(IPrediXExchange.OrderAlreadyCancelled.selector);
        exchange.cancelOrder(id);
    }

    function test_Revert_CancelOrder_FullyFilled() public {
        bytes32 id = _placeSellYes(alice, 500_000, 100 * ONE_SHARE);
        _giveUsdc(bob, 100 * ONE_SHARE);
        vm.prank(bob);
        exchange.fillMarketOrder(
            MARKET_ID, IPrediXExchange.Side.BUY_YES, 600_000, 100 * ONE_SHARE, bob, bob, 0, _deadline()
        );
        vm.prank(alice);
        vm.expectRevert(IPrediXExchange.OrderFullyFilled.selector);
        exchange.cancelOrder(id);
    }

    function test_CancelOrder_OrderCancelledEvent() public {
        bytes32 id = _placeBuyYes(alice, 500_000, 100 * ONE_SHARE);
        vm.expectEmit(true, false, false, true);
        emit IPrediXExchange.OrderCancelled(id);
        vm.prank(alice);
        exchange.cancelOrder(id);
    }

    // ============ M1 — H-01 fix verification ============

    /// @notice Audit H-01: `userOrderCount` must decrement when a maker order is
    ///         fully filled, otherwise users get permanently locked at the cap.
    function test_UserOrderCount_DecrementsOnFullFill() public {
        // Alice fills 50 BUY orders (the cap), all small.
        for (uint256 i; i < 50; ++i) {
            uint256 px = 100_000 + (i % 9) * 10_000;
            usdc.mint(alice, px);
            vm.startPrank(alice);
            usdc.approve(address(exchange), type(uint256).max);
            exchange.placeOrder(MARKET_ID, IPrediXExchange.Side.BUY_YES, px, ONE_SHARE);
            vm.stopPrank();
        }
        assertEq(exchange.userOrderCount(MARKET_ID, alice), 50);

        // Counter-side seller fully fills every alice order.
        _giveYesNo(bob, 50 * ONE_SHARE);
        vm.prank(bob);
        exchange.fillMarketOrder(
            MARKET_ID, IPrediXExchange.Side.SELL_YES, 100_000, 50 * ONE_SHARE, bob, bob, 50, _deadline()
        );

        // After M1: alice is back to 0 and can place again.
        assertEq(exchange.userOrderCount(MARKET_ID, alice), 0, "decremented");
        usdc.mint(alice, 50 * ONE_SHARE);
        vm.prank(alice);
        exchange.placeOrder(MARKET_ID, IPrediXExchange.Side.BUY_YES, 500_000, 100 * ONE_SHARE);
        // No revert → cap respected after decrement.
    }

    // ============ M5 — queue cleanup discipline ============

    /// @notice Audit M5: after the only order at a price level is cancelled,
    ///         `_peekBest` must not see a stale bit and the bitmap must be cleared.
    function test_PeekBest_IsO1_AfterCancellations() public {
        // Place 5 orders all at the same idx, then cancel them all.
        bytes32[] memory ids = new bytes32[](5);
        ids[0] = _placeBuyYes(alice, 500_000, ONE_SHARE);
        ids[1] = _placeBuyYes(carol, 500_000, ONE_SHARE);
        ids[2] = _placeBuyYes(dave, 500_000, ONE_SHARE);
        ids[3] = _placeBuyYes(makeAddr("eve"), 500_000, ONE_SHARE);
        ids[4] = _placeBuyYes(makeAddr("frank"), 500_000, ONE_SHARE);

        // Cancel each as owner.
        address[5] memory owners = [alice, carol, dave, makeAddr("eve"), makeAddr("frank")];
        for (uint256 i; i < 5; ++i) {
            vm.prank(owners[i]);
            exchange.cancelOrder(ids[i]);
        }

        // Bitmap bit at idx 49 must be cleared.
        assertEq(exchange.priceBitmap(MARKET_ID, IPrediXExchange.Side.BUY_YES), 0);

        // A new order at a different price must show up cleanly.
        _placeBuyYes(alice, 600_000, ONE_SHARE);
        (uint256 bb,,,) = exchange.getBestPrices(MARKET_ID);
        assertEq(bb, 600_000, "bestBid is the only live order");
    }

    function test_Bitmap_ClearedWhenLastOrderAtLevelCancelled() public {
        bytes32 id = _placeBuyYes(alice, 500_000, 100 * ONE_SHARE);
        assertGt(exchange.priceBitmap(MARKET_ID, IPrediXExchange.Side.BUY_YES), 0);
        vm.prank(alice);
        exchange.cancelOrder(id);
        assertEq(exchange.priceBitmap(MARKET_ID, IPrediXExchange.Side.BUY_YES), 0);
    }
}
