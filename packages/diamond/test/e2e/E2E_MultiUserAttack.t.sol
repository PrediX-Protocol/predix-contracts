// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IMarketFacet} from "@predix/shared/interfaces/IMarketFacet.sol";
import {IPrediXExchange} from "@predix/exchange/IPrediXExchange.sol";
import {IPrediXRouter} from "@predix/router/interfaces/IPrediXRouter.sol";
import {PrediXExchangeProxy} from "@predix/exchange/PrediXExchangeProxy.sol";
import {E2EForkBase} from "./E2EForkBase.t.sol";

/// @title E2E_MultiUserAttack
/// @notice Groups V (Multi-user), W (Invariants), X (Boundary), Y (Attack scenarios).
contract E2E_MultiUserAttack is E2EForkBase {
    IPrediXRouter internal router = IPrediXRouter(ROUTER);
    uint256 internal marketId;
    address internal yesToken;
    address internal noToken;

    function setUp() public override {
        super.setUp();
        _grantCreatorRole(DEPLOYER);
        marketId = _createMarket(DEPLOYER, block.timestamp + 7 days);
        (yesToken, noToken) = _getTokens(marketId);

        _splitPosition(alice, marketId, 10_000e6);
        _splitPosition(bob, marketId, 10_000e6);
        _splitPosition(charlie, marketId, 10_000e6);
    }

    // ================================================================
    // V. Multi-User Scenarios
    // ================================================================

    function test_V01_transferYES_thenRedeem() public {
        // Alice transfers YES to bob, bob redeems after resolve
        vm.prank(alice);
        IERC20(yesToken).transfer(bob, 5_000e6);

        vm.warp(block.timestamp + 8 days);
        _reportOutcome(marketId, true);
        _resolveMarket(marketId);

        uint256 bobUsdcBefore = IERC20(USDC).balanceOf(bob);
        vm.prank(bob);
        diamond.redeem(marketId);
        uint256 bobPayout = IERC20(USDC).balanceOf(bob) - bobUsdcBefore;

        // Bob had 10_000 YES (split) + 5_000 YES (from alice) = 15_000 YES
        assertEq(bobPayout, 15_000e6);
    }

    function test_V02_twoUsersSplit_bothRedeem() public {
        // Both already split in setUp. Resolve → both redeem.
        vm.warp(block.timestamp + 8 days);
        _reportOutcome(marketId, true);
        _resolveMarket(marketId);

        vm.prank(alice);
        uint256 alicePayout = diamond.redeem(marketId);
        vm.prank(bob);
        uint256 bobPayout = diamond.redeem(marketId);

        assertEq(alicePayout, 10_000e6);
        assertEq(bobPayout, 10_000e6);
    }

    function test_V03_alicePlaces_bobFills() public {
        // Alice places SELL YES @0.60
        vm.startPrank(alice);
        IERC20(yesToken).approve(EXCHANGE, type(uint256).max);
        exchange.placeOrder(marketId, IPrediXExchange.Side.SELL_YES, 600_000, 100e6);
        vm.stopPrank();

        // Bob fills via taker
        uint256 bobYesBefore = IERC20(yesToken).balanceOf(bob);
        vm.startPrank(bob);
        IERC20(USDC).approve(EXCHANGE, type(uint256).max);
        (uint256 filled,) = exchange.fillMarketOrder(
            marketId, IPrediXExchange.Side.BUY_YES, 600_000, 60e6, bob, bob, 10, block.timestamp + 300
        );
        vm.stopPrank();

        assertEq(filled, 100e6);
        assertEq(IERC20(yesToken).balanceOf(bob) - bobYesBefore, 100e6);
    }

    function test_V08_refund_unequalBalances() public {
        // Alice has 10_000 YES + 10_000 NO. Sell 5_000 YES to bob.
        vm.prank(alice);
        IERC20(yesToken).transfer(bob, 5_000e6);
        // Alice: 5_000 YES + 10_000 NO

        vm.warp(block.timestamp + 8 days);
        vm.prank(DEPLOYER);
        diamond.enableRefundMode(marketId);

        // Refund min(5000, 10000) = 5000
        uint256 usdcBefore = IERC20(USDC).balanceOf(alice);
        vm.prank(alice);
        diamond.refund(marketId, 5_000e6, 10_000e6);
        uint256 refunded = IERC20(USDC).balanceOf(alice) - usdcBefore;

        assertEq(refunded, 5_000e6);
        // Remaining: 0 YES + 5_000 NO
        assertEq(IERC20(yesToken).balanceOf(alice), 0);
        assertEq(IERC20(noToken).balanceOf(alice), 5_000e6);
    }

    function test_V09_split_partialSell_mergeRemainder() public {
        // Alice has 10_000 YES + 10_000 NO from setUp
        // Sell 3_000 YES on CLOB, merge remaining 7_000
        vm.startPrank(alice);
        IERC20(yesToken).approve(EXCHANGE, type(uint256).max);
        exchange.placeOrder(marketId, IPrediXExchange.Side.SELL_YES, 500_000, 3_000e6);

        // Merge 7_000 (burns 7_000 YES + 7_000 NO, returns 7_000 USDC)
        uint256 usdcBefore = IERC20(USDC).balanceOf(alice);
        diamond.mergePositions(marketId, 7_000e6);
        uint256 usdcAfter = IERC20(USDC).balanceOf(alice);
        vm.stopPrank();

        assertEq(usdcAfter - usdcBefore, 7_000e6);
    }

    function test_V11_redeem_nonParticipant_Revert() public {
        vm.warp(block.timestamp + 8 days);
        _reportOutcome(marketId, true);
        _resolveMarket(marketId);

        // eve never split → 0 YES + 0 NO
        vm.prank(eve);
        vm.expectRevert();
        diamond.redeem(marketId);
    }

    function test_V12_buyYes_Revert_insufficientUSDC() public {
        // eve has 100_000 USDC from setUp funding but let's drain her
        vm.startPrank(eve);
        IERC20(USDC).transfer(alice, IERC20(USDC).balanceOf(eve));
        IERC20(USDC).approve(ROUTER, type(uint256).max);
        vm.expectRevert();
        router.buyYes(marketId, 1e6, 1, eve, 10, block.timestamp + 300);
        vm.stopPrank();
    }

    // ================================================================
    // W. Economic Invariants
    // ================================================================

    function test_W01_supply_equals_collateral() public {
        IMarketFacet.MarketView memory m = diamond.getMarket(marketId);
        assertEq(IERC20(yesToken).totalSupply(), m.totalCollateral);
        assertEq(IERC20(noToken).totalSupply(), m.totalCollateral);
    }

    function test_W06_collateral_unchanged_by_CLOB() public {
        uint256 collateralBefore = diamond.getMarket(marketId).totalCollateral;

        // Alice sells YES, Bob buys → pure token swap, no collateral change
        vm.startPrank(alice);
        IERC20(yesToken).approve(EXCHANGE, type(uint256).max);
        exchange.placeOrder(marketId, IPrediXExchange.Side.SELL_YES, 500_000, 100e6);
        vm.stopPrank();

        vm.startPrank(bob);
        IERC20(USDC).approve(EXCHANGE, type(uint256).max);
        exchange.fillMarketOrder(marketId, IPrediXExchange.Side.BUY_YES, 500_000, 50e6, bob, bob, 10, block.timestamp + 300);
        vm.stopPrank();

        uint256 collateralAfter = diamond.getMarket(marketId).totalCollateral;
        assertEq(collateralAfter, collateralBefore);
    }

    function test_W07_collateral_increases_only_via_split() public {
        uint256 before = diamond.getMarket(marketId).totalCollateral;
        _splitPosition(eve, marketId, 500e6);
        uint256 after_ = diamond.getMarket(marketId).totalCollateral;
        assertEq(after_ - before, 500e6);
    }

    function test_W08_collateral_decreases_via_merge() public {
        uint256 before = diamond.getMarket(marketId).totalCollateral;
        vm.prank(alice);
        diamond.mergePositions(marketId, 1_000e6);
        uint256 after_ = diamond.getMarket(marketId).totalCollateral;
        assertEq(before - after_, 1_000e6);
    }

    // ================================================================
    // X. Boundary / Stress
    // ================================================================

    function test_X01_trade_minTradeAmount() public {
        // Place order at MIN_ORDER_AMOUNT = 1e6
        vm.startPrank(alice);
        IERC20(USDC).approve(EXCHANGE, type(uint256).max);
        (bytes32 orderId,) = exchange.placeOrder(marketId, IPrediXExchange.Side.BUY_YES, 500_000, 1e6);
        vm.stopPrank();
        assertTrue(orderId != bytes32(0));
    }

    function test_X03_allPriceTicks_valid() public {
        vm.startPrank(alice);
        IERC20(USDC).approve(EXCHANGE, type(uint256).max);
        // Place at first and last valid ticks
        exchange.placeOrder(marketId, IPrediXExchange.Side.BUY_YES, 10_000, 1e6); // $0.01
        exchange.placeOrder(marketId, IPrediXExchange.Side.BUY_YES, 990_000, 1e6); // $0.99
        vm.stopPrank();
    }

    function test_X05_fillWithMaxFills_1() public {
        // Place 3 orders
        vm.startPrank(alice);
        IERC20(yesToken).approve(EXCHANGE, type(uint256).max);
        exchange.placeOrder(marketId, IPrediXExchange.Side.SELL_YES, 500_000, 10e6);
        exchange.placeOrder(marketId, IPrediXExchange.Side.SELL_YES, 500_000, 10e6);
        exchange.placeOrder(marketId, IPrediXExchange.Side.SELL_YES, 500_000, 10e6);
        vm.stopPrank();

        // Bob fills with maxFills=1 → only 1 fill
        vm.startPrank(bob);
        IERC20(USDC).approve(EXCHANGE, type(uint256).max);
        (uint256 filled,) = exchange.fillMarketOrder(
            marketId, IPrediXExchange.Side.BUY_YES, 500_000, 50e6, bob, bob, 1, block.timestamp + 300
        );
        vm.stopPrank();

        // Only filled 10e6 (1 order)
        assertEq(filled, 10e6);
    }

    function test_X07_marketEndTimeFarFuture() public {
        _grantCreatorRole(eve);
        // 10 years from now → no overflow
        uint256 mid = _createMarket(eve, block.timestamp + 365 days * 10);
        IMarketFacet.MarketView memory m = diamond.getMarket(mid);
        assertGt(m.endTime, block.timestamp);
    }

    function test_X10_resolveAtExactEndTime() public {
        _grantCreatorRole(eve);
        uint256 endTime = block.timestamp + 1 hours;
        uint256 mid = _createMarket(eve, endTime);
        _splitPosition(eve, mid, 100e6);

        vm.warp(endTime); // exactly at endTime
        _reportOutcome(mid, true);
        _resolveMarket(mid);
        assertTrue(diamond.getMarket(mid).isResolved);
    }

    // ================================================================
    // Y. Attack Scenarios
    // ================================================================

    function test_Y04_drainUSDC_via_notTaker_Revert() public {
        // Eve tries to drain alice's USDC allowance by setting taker=alice
        vm.startPrank(alice);
        IERC20(USDC).approve(EXCHANGE, type(uint256).max);
        vm.stopPrank();

        vm.startPrank(eve);
        vm.expectRevert();
        // eve is msg.sender, taker=alice → E-02 revert
        exchange.fillMarketOrder(marketId, IPrediXExchange.Side.BUY_YES, 500_000, 100e6, alice, eve, 10, block.timestamp + 300);
        vm.stopPrank();
    }

    function test_Y06_instantUpgrade_blocked_by_timelock() public {
        PrediXExchangeProxy proxy = PrediXExchangeProxy(payable(EXCHANGE));

        // Even admin cannot execute without waiting 48h
        address fakeImpl = makeAddr("evil");
        vm.etch(fakeImpl, hex"00");

        vm.prank(OPERATOR);
        proxy.proposeUpgrade(fakeImpl);

        // Immediate execute → revert
        vm.prank(OPERATOR);
        vm.expectRevert();
        proxy.executeUpgrade();
    }

    function test_Y07_resetTimer_Revert_AlreadyPending() public {
        PrediXExchangeProxy proxy = PrediXExchangeProxy(payable(EXCHANGE));

        address impl1 = makeAddr("impl1");
        address impl2 = makeAddr("impl2");
        vm.etch(impl1, hex"00");
        vm.etch(impl2, hex"00");

        vm.prank(OPERATOR);
        proxy.proposeUpgrade(impl1);

        // Try to re-propose (reset timer) → revert
        vm.prank(OPERATOR);
        vm.expectRevert();
        proxy.proposeUpgrade(impl2);
    }

    function test_Y08_stealFunds_bannedRecipient_Revert() public {
        vm.startPrank(alice);
        IERC20(USDC).approve(ROUTER, type(uint256).max);
        // Try to send YES to diamond address
        vm.expectRevert();
        router.buyYes(marketId, 50e6, 1, DIAMOND, 10, block.timestamp + 300);
        vm.stopPrank();
    }

    function test_Y09_doubleRedeem_blocked() public {
        vm.warp(block.timestamp + 8 days);
        _reportOutcome(marketId, true);
        _resolveMarket(marketId);

        vm.startPrank(alice);
        diamond.redeem(marketId);
        // Second redeem → balance is 0 → revert
        vm.expectRevert();
        diamond.redeem(marketId);
        vm.stopPrank();
    }

    function test_Y10_dustGrief_makerCleanup() public {
        // Place a large order, then fill almost all of it leaving dust
        vm.startPrank(alice);
        IERC20(yesToken).approve(EXCHANGE, type(uint256).max);
        exchange.placeOrder(marketId, IPrediXExchange.Side.SELL_YES, 500_000, 100e6);
        vm.stopPrank();

        // Bob fills 99e6 of the 100e6 order
        vm.startPrank(bob);
        IERC20(USDC).approve(EXCHANGE, type(uint256).max);
        exchange.fillMarketOrder(marketId, IPrediXExchange.Side.BUY_YES, 500_000, 49e6, bob, bob, 10, block.timestamp + 300);
        vm.stopPrank();

        // Market still functional — another fill works
        vm.startPrank(charlie);
        IERC20(USDC).approve(EXCHANGE, type(uint256).max);
        (uint256 filled,) = exchange.fillMarketOrder(
            marketId, IPrediXExchange.Side.BUY_YES, 500_000, 10e6, charlie, charlie, 10, block.timestamp + 300
        );
        vm.stopPrank();

        assertGt(filled, 0);
    }
}
