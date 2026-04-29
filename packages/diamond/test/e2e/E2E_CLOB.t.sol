// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IMarketFacet} from "@predix/shared/interfaces/IMarketFacet.sol";
import {IPrediXExchange} from "@predix/exchange/IPrediXExchange.sol";
import {PrediXExchange} from "@predix/exchange/PrediXExchange.sol";
import {E2EForkBase} from "./E2EForkBase.t.sol";

/// @title E2E_CLOB
/// @notice Groups E, F, G, H: Order placement, matching, cancel, exchange pause.
contract E2E_CLOB is E2EForkBase {
    uint256 internal marketId;
    address internal yesToken;
    address internal noToken;

    function setUp() public override {
        super.setUp();
        _grantCreatorRole(DEPLOYER);
        marketId = _createMarket(DEPLOYER, block.timestamp + 7 days);
        (yesToken, noToken) = _getTokens(marketId);

        // Fund alice + bob with YES/NO tokens
        _splitPosition(alice, marketId, 50_000e6);
        _splitPosition(bob, marketId, 50_000e6);
    }

    // ================================================================
    // E. Order Placement
    // ================================================================

    function test_E01_placeOrder_BUY_YES_resting() public {
        vm.startPrank(alice);
        IERC20(USDC).approve(EXCHANGE, type(uint256).max);
        (bytes32 orderId, uint256 filled) = exchange.placeOrder(marketId, IPrediXExchange.Side.BUY_YES, 600_000, 100e6);
        vm.stopPrank();

        assertTrue(orderId != bytes32(0));
        assertEq(filled, 0);
    }

    function test_E02_placeOrder_SELL_YES_resting() public {
        vm.startPrank(alice);
        IERC20(yesToken).approve(EXCHANGE, type(uint256).max);
        (bytes32 orderId, uint256 filled) = exchange.placeOrder(marketId, IPrediXExchange.Side.SELL_YES, 600_000, 100e6);
        vm.stopPrank();

        assertTrue(orderId != bytes32(0));
        assertEq(filled, 0);
    }

    function test_E03_placeOrder_BUY_NO_resting() public {
        vm.startPrank(alice);
        IERC20(USDC).approve(EXCHANGE, type(uint256).max);
        (bytes32 orderId, uint256 filled) = exchange.placeOrder(marketId, IPrediXExchange.Side.BUY_NO, 400_000, 100e6);
        vm.stopPrank();

        assertTrue(orderId != bytes32(0));
        assertEq(filled, 0);
    }

    function test_E04_placeOrder_SELL_NO_resting() public {
        vm.startPrank(alice);
        IERC20(noToken).approve(EXCHANGE, type(uint256).max);
        (bytes32 orderId, uint256 filled) = exchange.placeOrder(marketId, IPrediXExchange.Side.SELL_NO, 400_000, 100e6);
        vm.stopPrank();

        assertTrue(orderId != bytes32(0));
        assertEq(filled, 0);
    }

    function test_E05_placeOrder_minPrice_0_01() public {
        vm.startPrank(alice);
        IERC20(USDC).approve(EXCHANGE, type(uint256).max);
        (bytes32 orderId,) = exchange.placeOrder(marketId, IPrediXExchange.Side.BUY_YES, 10_000, 100e6);
        vm.stopPrank();
        assertTrue(orderId != bytes32(0));
    }

    function test_E06_placeOrder_maxPrice_0_99() public {
        vm.startPrank(alice);
        IERC20(USDC).approve(EXCHANGE, type(uint256).max);
        (bytes32 orderId,) = exchange.placeOrder(marketId, IPrediXExchange.Side.BUY_YES, 990_000, 100e6);
        vm.stopPrank();
        assertTrue(orderId != bytes32(0));
    }

    function test_E07_placeOrder_Revert_priceZero() public {
        vm.startPrank(alice);
        IERC20(USDC).approve(EXCHANGE, type(uint256).max);
        vm.expectRevert();
        exchange.placeOrder(marketId, IPrediXExchange.Side.BUY_YES, 0, 100e6);
        vm.stopPrank();
    }

    function test_E08_placeOrder_Revert_priceEqualPrecision() public {
        vm.startPrank(alice);
        IERC20(USDC).approve(EXCHANGE, type(uint256).max);
        vm.expectRevert();
        exchange.placeOrder(marketId, IPrediXExchange.Side.BUY_YES, 1_000_000, 100e6);
        vm.stopPrank();
    }

    function test_E09_placeOrder_Revert_priceNotTickAligned() public {
        vm.startPrank(alice);
        IERC20(USDC).approve(EXCHANGE, type(uint256).max);
        vm.expectRevert();
        exchange.placeOrder(marketId, IPrediXExchange.Side.BUY_YES, 15_000, 100e6);
        vm.stopPrank();
    }

    function test_E10_placeOrder_minAmount_exactly() public {
        vm.startPrank(alice);
        IERC20(USDC).approve(EXCHANGE, type(uint256).max);
        (bytes32 orderId,) = exchange.placeOrder(marketId, IPrediXExchange.Side.BUY_YES, 500_000, 1e6);
        vm.stopPrank();
        assertTrue(orderId != bytes32(0));
    }

    function test_E11_placeOrder_Revert_belowMinAmount() public {
        vm.startPrank(alice);
        IERC20(USDC).approve(EXCHANGE, type(uint256).max);
        vm.expectRevert();
        exchange.placeOrder(marketId, IPrediXExchange.Side.BUY_YES, 500_000, 999_999);
        vm.stopPrank();
    }

    function test_E12_placeOrder_Revert_aboveUint128Max() public {
        vm.startPrank(alice);
        IERC20(USDC).approve(EXCHANGE, type(uint256).max);
        vm.expectRevert();
        exchange.placeOrder(marketId, IPrediXExchange.Side.BUY_YES, 500_000, uint256(type(uint128).max) + 1);
        vm.stopPrank();
    }

    function test_E13_placeOrder_50thOrder_atLimit() public {
        vm.startPrank(alice);
        IERC20(USDC).approve(EXCHANGE, type(uint256).max);
        for (uint256 i; i < 50; i++) {
            uint256 price = 10_000 + (i % 98) * 10_000;
            exchange.placeOrder(marketId, IPrediXExchange.Side.BUY_YES, price, 1e6);
        }
        vm.stopPrank();
    }

    function test_E14_placeOrder_Revert_51stOrder() public {
        vm.startPrank(alice);
        IERC20(USDC).approve(EXCHANGE, type(uint256).max);
        for (uint256 i; i < 50; i++) {
            exchange.placeOrder(marketId, IPrediXExchange.Side.BUY_YES, 500_000, 1e6);
        }
        vm.expectRevert();
        exchange.placeOrder(marketId, IPrediXExchange.Side.BUY_YES, 500_000, 1e6);
        vm.stopPrank();
    }

    // ================================================================
    // F. Matching
    // ================================================================

    function test_F01_complementary_BUY_vs_SELL_samePrice() public {
        // Alice places BUY YES @0.60
        vm.startPrank(alice);
        IERC20(USDC).approve(EXCHANGE, type(uint256).max);
        exchange.placeOrder(marketId, IPrediXExchange.Side.BUY_YES, 600_000, 100e6);
        vm.stopPrank();

        // Bob places SELL YES @0.60 → instant match
        uint256 bobUsdcBefore = IERC20(USDC).balanceOf(bob);
        vm.startPrank(bob);
        IERC20(yesToken).approve(EXCHANGE, type(uint256).max);
        (, uint256 filled) = exchange.placeOrder(marketId, IPrediXExchange.Side.SELL_YES, 600_000, 100e6);
        vm.stopPrank();

        assertEq(filled, 100e6);
        assertGt(IERC20(USDC).balanceOf(bob), bobUsdcBefore);
    }

    function test_F02_complementary_priceImprovement() public {
        // Alice places BUY YES @0.70 (willing to pay more)
        vm.startPrank(alice);
        IERC20(USDC).approve(EXCHANGE, type(uint256).max);
        exchange.placeOrder(marketId, IPrediXExchange.Side.BUY_YES, 700_000, 100e6);
        vm.stopPrank();

        // Bob places SELL YES @0.60 (cheaper) → matches at 0.60, alice gets improvement
        uint256 aliceYesBefore = IERC20(yesToken).balanceOf(alice);
        vm.startPrank(bob);
        IERC20(yesToken).approve(EXCHANGE, type(uint256).max);
        exchange.placeOrder(marketId, IPrediXExchange.Side.SELL_YES, 600_000, 100e6);
        vm.stopPrank();

        uint256 aliceYesAfter = IERC20(yesToken).balanceOf(alice);
        assertEq(aliceYesAfter - aliceYesBefore, 100e6);
    }

    function test_F03_MINT_synthetic_bothBuy() public {
        // Alice places BUY YES @0.65
        vm.startPrank(alice);
        IERC20(USDC).approve(EXCHANGE, type(uint256).max);
        exchange.placeOrder(marketId, IPrediXExchange.Side.BUY_YES, 650_000, 100e6);
        vm.stopPrank();

        // Bob places BUY NO @0.40 → MINT synthetic (0.65 + 0.40 > 1.00? No... need >= 1.00)
        // Use 0.65 + 0.35 = 1.00 exactly → MINT eligible
        vm.startPrank(bob);
        IERC20(USDC).approve(EXCHANGE, type(uint256).max);
        (, uint256 filled) = exchange.placeOrder(marketId, IPrediXExchange.Side.BUY_NO, 350_000, 100e6);
        vm.stopPrank();

        // Should have minted via diamond.splitPosition
        assertGt(filled, 0);
    }

    function test_F04_MERGE_synthetic_bothSell() public {
        // Alice places SELL YES @0.40
        vm.startPrank(alice);
        IERC20(yesToken).approve(EXCHANGE, type(uint256).max);
        exchange.placeOrder(marketId, IPrediXExchange.Side.SELL_YES, 400_000, 100e6);
        vm.stopPrank();

        // Bob places SELL NO @0.60 → MERGE synthetic (0.40 + 0.60 = 1.00)
        vm.startPrank(bob);
        IERC20(noToken).approve(EXCHANGE, type(uint256).max);
        (, uint256 filled) = exchange.placeOrder(marketId, IPrediXExchange.Side.SELL_NO, 600_000, 100e6);
        vm.stopPrank();

        assertGt(filled, 0);
    }

    function test_F06_selfMatch_Revert() public {
        // Alice places BUY YES @0.60
        vm.startPrank(alice);
        IERC20(USDC).approve(EXCHANGE, type(uint256).max);
        exchange.placeOrder(marketId, IPrediXExchange.Side.BUY_YES, 600_000, 100e6);
        // Alice tries SELL YES @0.60 against her own order → should skip self
        IERC20(yesToken).approve(EXCHANGE, type(uint256).max);
        (, uint256 filled) = exchange.placeOrder(marketId, IPrediXExchange.Side.SELL_YES, 600_000, 50e6);
        vm.stopPrank();

        // Self-match skipped, order rests unfilled
        assertEq(filled, 0);
    }

    function test_F07_partialFill() public {
        // Alice BUY YES @0.60 for 100
        vm.startPrank(alice);
        IERC20(USDC).approve(EXCHANGE, type(uint256).max);
        exchange.placeOrder(marketId, IPrediXExchange.Side.BUY_YES, 600_000, 100e6);
        vm.stopPrank();

        // Bob SELL YES @0.60 for 50 → partial fill
        vm.startPrank(bob);
        IERC20(yesToken).approve(EXCHANGE, type(uint256).max);
        (, uint256 filled) = exchange.placeOrder(marketId, IPrediXExchange.Side.SELL_YES, 600_000, 50e6);
        vm.stopPrank();

        assertEq(filled, 50e6);
    }

    function test_F11_fillMarketOrder_Revert_deadlineExpired() public {
        vm.startPrank(alice);
        IERC20(USDC).approve(EXCHANGE, type(uint256).max);
        vm.expectRevert();
        exchange.fillMarketOrder(marketId, IPrediXExchange.Side.BUY_YES, 600_000, 100e6, alice, alice, 10, block.timestamp - 1);
        vm.stopPrank();
    }

    function test_F12_fillMarketOrder_Revert_notTaker() public {
        vm.startPrank(alice);
        IERC20(USDC).approve(EXCHANGE, type(uint256).max);
        vm.expectRevert();
        // alice is msg.sender but taker=bob → E-02 revert
        exchange.fillMarketOrder(marketId, IPrediXExchange.Side.BUY_YES, 600_000, 100e6, bob, alice, 10, block.timestamp + 100);
        vm.stopPrank();
    }

    // ================================================================
    // G. Cancel
    // ================================================================

    function test_G01_cancelOwnBuyOrder() public {
        vm.startPrank(alice);
        IERC20(USDC).approve(EXCHANGE, type(uint256).max);
        (bytes32 orderId,) = exchange.placeOrder(marketId, IPrediXExchange.Side.BUY_YES, 600_000, 100e6);

        uint256 usdcBefore = IERC20(USDC).balanceOf(alice);
        exchange.cancelOrder(orderId);
        vm.stopPrank();

        uint256 refund = IERC20(USDC).balanceOf(alice) - usdcBefore;
        assertGt(refund, 0);
    }

    function test_G02_cancelOwnSellOrder() public {
        vm.startPrank(alice);
        IERC20(yesToken).approve(EXCHANGE, type(uint256).max);
        (bytes32 orderId,) = exchange.placeOrder(marketId, IPrediXExchange.Side.SELL_YES, 600_000, 100e6);

        uint256 yesBefore = IERC20(yesToken).balanceOf(alice);
        exchange.cancelOrder(orderId);
        vm.stopPrank();

        uint256 refund = IERC20(yesToken).balanceOf(alice) - yesBefore;
        assertEq(refund, 100e6);
    }

    function test_G03_cancel_Revert_alreadyCancelled() public {
        vm.startPrank(alice);
        IERC20(USDC).approve(EXCHANGE, type(uint256).max);
        (bytes32 orderId,) = exchange.placeOrder(marketId, IPrediXExchange.Side.BUY_YES, 600_000, 100e6);
        exchange.cancelOrder(orderId);
        vm.expectRevert();
        exchange.cancelOrder(orderId);
        vm.stopPrank();
    }

    function test_G05_cancel_Revert_notOwnerActiveMarket() public {
        vm.startPrank(alice);
        IERC20(USDC).approve(EXCHANGE, type(uint256).max);
        (bytes32 orderId,) = exchange.placeOrder(marketId, IPrediXExchange.Side.BUY_YES, 600_000, 100e6);
        vm.stopPrank();

        // Bob tries to cancel alice's order on active market
        vm.prank(bob);
        vm.expectRevert();
        exchange.cancelOrder(orderId);
    }

    function test_G06_cancel_permissionless_onResolvedMarket() public {
        vm.startPrank(alice);
        IERC20(USDC).approve(EXCHANGE, type(uint256).max);
        (bytes32 orderId,) = exchange.placeOrder(marketId, IPrediXExchange.Side.BUY_YES, 600_000, 100e6);
        vm.stopPrank();

        // Resolve market
        vm.warp(block.timestamp + 8 days);
        _reportOutcome(marketId, true);
        _resolveMarket(marketId);

        // Charlie (non-owner) cancels alice's order → permissionless on terminal
        uint256 aliceUsdcBefore = IERC20(USDC).balanceOf(alice);
        vm.prank(charlie);
        exchange.cancelOrder(orderId);

        assertGt(IERC20(USDC).balanceOf(alice), aliceUsdcBefore);
    }

    // ================================================================
    // H. Exchange Pause
    // ================================================================

    function test_H01_pause_blocksPlaceOrder() public {
        vm.prank(DEPLOYER);
        PrediXExchange(EXCHANGE).pause();

        vm.startPrank(alice);
        IERC20(USDC).approve(EXCHANGE, type(uint256).max);
        vm.expectRevert();
        exchange.placeOrder(marketId, IPrediXExchange.Side.BUY_YES, 600_000, 100e6);
        vm.stopPrank();

        vm.prank(DEPLOYER);
        PrediXExchange(EXCHANGE).unpause();
    }

    function test_H02_pause_cancelStillWorks() public {
        vm.startPrank(alice);
        IERC20(USDC).approve(EXCHANGE, type(uint256).max);
        (bytes32 orderId,) = exchange.placeOrder(marketId, IPrediXExchange.Side.BUY_YES, 600_000, 100e6);
        vm.stopPrank();

        vm.prank(DEPLOYER);
        PrediXExchange(EXCHANGE).pause();

        // Cancel works even when paused
        vm.prank(alice);
        exchange.cancelOrder(orderId);

        vm.prank(DEPLOYER);
        PrediXExchange(EXCHANGE).unpause();
    }

    function test_H03_pause_fillMarketOrderStillWorks() public {
        // Place a resting order first
        vm.startPrank(alice);
        IERC20(yesToken).approve(EXCHANGE, type(uint256).max);
        exchange.placeOrder(marketId, IPrediXExchange.Side.SELL_YES, 500_000, 100e6);
        vm.stopPrank();

        vm.prank(DEPLOYER);
        PrediXExchange(EXCHANGE).pause();

        // Taker fill works even when paused
        vm.startPrank(bob);
        IERC20(USDC).approve(EXCHANGE, type(uint256).max);
        (uint256 filled,) = exchange.fillMarketOrder(
            marketId, IPrediXExchange.Side.BUY_YES, 500_000, 50e6, bob, bob, 10, block.timestamp + 100
        );
        vm.stopPrank();

        assertGt(filled, 0);

        vm.prank(DEPLOYER);
        PrediXExchange(EXCHANGE).unpause();
    }

    function test_H04_unpause_placeOrderWorks() public {
        vm.prank(DEPLOYER);
        PrediXExchange(EXCHANGE).pause();
        vm.prank(DEPLOYER);
        PrediXExchange(EXCHANGE).unpause();

        vm.startPrank(alice);
        IERC20(USDC).approve(EXCHANGE, type(uint256).max);
        (bytes32 orderId,) = exchange.placeOrder(marketId, IPrediXExchange.Side.BUY_YES, 600_000, 100e6);
        vm.stopPrank();

        assertTrue(orderId != bytes32(0));
    }
}
