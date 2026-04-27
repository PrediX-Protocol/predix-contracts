// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {IPrediXExchange} from "../../src/IPrediXExchange.sol";

import {ExchangeTestBase} from "../base/ExchangeTestBase.sol";

/// @title PrediXExchangeTakerTest
/// @notice Unit tests for `fillMarketOrder` covering every spec §8.1 case plus
///         the audit-flagged review tests (C2 module pause, M1 decrement, M5
///         queue cleanup).
contract PrediXExchangeTakerTest is ExchangeTestBase {
    // ============ 1. complementary only ============

    function test_fillMarketOrder_complementaryOnly() public {
        _placeSellYes(alice, 500_000, 100 * ONE_SHARE);
        _giveUsdc(bob, 100 * ONE_SHARE);

        vm.prank(bob);
        (uint256 filled, uint256 cost) = exchange.fillMarketOrder(
            MARKET_ID, IPrediXExchange.Side.BUY_YES, 600_000, 100 * ONE_SHARE, bob, bob, 0, _deadline()
        );

        assertEq(filled, 100 * ONE_SHARE, "filled");
        assertEq(cost, 50 * ONE_SHARE, "cost");
        assertEq(_yesBalance(bob), 100 * ONE_SHARE, "bob YES");
        assertEq(_usdcBalance(alice), 50 * ONE_SHARE, "alice USDC");
    }

    // ============ 2. synthetic MINT only ============

    function test_fillMarketOrder_syntheticMintOnly() public {
        _placeBuyNo(alice, 400_000, 100 * ONE_SHARE);
        _giveUsdc(bob, 100 * ONE_SHARE);

        vm.prank(bob);
        (uint256 filled, uint256 cost) = exchange.fillMarketOrder(
            MARKET_ID, IPrediXExchange.Side.BUY_YES, 700_000, 100 * ONE_SHARE, bob, bob, 0, _deadline()
        );

        assertEq(filled, 100 * ONE_SHARE, "filled");
        assertEq(cost, 60 * ONE_SHARE, "cost = takerEffective * shares");
        assertEq(_yesBalance(bob), 100 * ONE_SHARE, "bob YES");
        assertEq(_noBalance(alice), 100 * ONE_SHARE, "alice NO");
        assertEq(_usdcBalance(feeRecipient), 0, "no surplus");
    }

    // ============ 3. synthetic MERGE only ============

    function test_fillMarketOrder_syntheticMergeOnly() public {
        _placeSellNo(alice, 400_000, 100 * ONE_SHARE);
        _giveYesNo(bob, 100 * ONE_SHARE);

        vm.prank(bob);
        (uint256 filled, uint256 cost) = exchange.fillMarketOrder(
            MARKET_ID, IPrediXExchange.Side.SELL_YES, 500_000, 100 * ONE_SHARE, bob, bob, 0, _deadline()
        );

        assertEq(filled, 60 * ONE_SHARE, "USDC out");
        assertEq(cost, 100 * ONE_SHARE, "YES in");
        assertEq(_usdcBalance(bob), 60 * ONE_SHARE, "bob USDC");
        assertEq(_usdcBalance(alice), 40 * ONE_SHARE, "alice USDC");
        assertEq(_usdcBalance(feeRecipient), 0, "no surplus");
    }

    // ============ 4. mixed waterfall (comp + syn together) ============

    function test_fillMarketOrder_mixedWaterfall() public {
        // SELL_YES @ $0.55 (comp, expensive), BUY_NO @ $0.40 (syn effective $0.60).
        _placeSellYes(alice, 550_000, 50 * ONE_SHARE);
        _placeBuyNo(carol, 400_000, 50 * ONE_SHARE);
        _giveUsdc(bob, 100 * ONE_SHARE);

        // Taker BUY_YES @ $0.65: comp $0.55 < syn $0.60 → comp wins iter 1.
        // Then comp exhausted → syn fills iter 2.
        vm.prank(bob);
        (uint256 filled, uint256 cost) = exchange.fillMarketOrder(
            MARKET_ID, IPrediXExchange.Side.BUY_YES, 650_000, 100 * ONE_SHARE, bob, bob, 0, _deadline()
        );

        assertEq(filled, 100 * ONE_SHARE, "filled both");
        // Iter 1: 50 @ $0.55 = $27.5; Iter 2: 50 @ $0.60 (syn) = $30. Total $57.5.
        assertEq(cost, 575_000 * ONE_SHARE / 1e4, "cost");
    }

    // ============ 5. tiebreaker prefers complementary ============

    function test_fillMarketOrder_tieBreaker_prefersComplementary() public {
        // Comp price $0.50, syn effective $0.50 (BUY_NO @ $0.50).
        _placeSellYes(alice, 500_000, 50 * ONE_SHARE);
        _placeBuyNo(carol, 500_000, 50 * ONE_SHARE);
        _giveUsdc(bob, 100 * ONE_SHARE);

        vm.recordLogs();
        vm.prank(bob);
        exchange.fillMarketOrder(
            MARKET_ID, IPrediXExchange.Side.BUY_YES, 600_000, 50 * ONE_SHARE, bob, bob, 1, _deadline()
        );

        // Single iteration with maxFills=1 — must pick COMPLEMENTARY (no diamond call).
        // Verify alice's order fully filled and carol's untouched.
        assertEq(_usdcBalance(alice), 25 * ONE_SHARE, "alice received comp payout");
        assertEq(_noBalance(carol), 0, "carol NO not minted (syn skipped)");
    }

    // ============ 6. limitPrice respected (BUY) ============

    function test_fillMarketOrder_limitPriceRespected_buy() public {
        _placeSellYes(alice, 700_000, 100 * ONE_SHARE);
        _giveUsdc(bob, 100 * ONE_SHARE);

        vm.prank(bob);
        (uint256 filled, uint256 cost) = exchange.fillMarketOrder(
            MARKET_ID, IPrediXExchange.Side.BUY_YES, 600_000, 100 * ONE_SHARE, bob, bob, 0, _deadline()
        );

        assertEq(filled, 0, "no fill above cap");
        assertEq(cost, 0, "no cost");
        assertEq(_usdcBalance(bob), 100 * ONE_SHARE, "full refund");
    }

    // ============ 7. limitPrice respected (SELL) ============

    function test_fillMarketOrder_limitPriceRespected_sell() public {
        _placeBuyYes(alice, 400_000, 100 * ONE_SHARE);
        _giveYesNo(bob, 100 * ONE_SHARE);

        uint256 yesBefore = _yesBalance(bob);
        vm.prank(bob);
        (uint256 filled, uint256 cost) = exchange.fillMarketOrder(
            MARKET_ID, IPrediXExchange.Side.SELL_YES, 500_000, 100 * ONE_SHARE, bob, bob, 0, _deadline()
        );

        assertEq(filled, 0, "no fill below floor");
        assertEq(cost, 0, "no cost");
        assertEq(_yesBalance(bob), yesBefore, "tokens fully refunded");
    }

    // ============ 8. maxFills bounded ============

    function test_fillMarketOrder_maxFills_bounded() public {
        // 5 SELL_YES makers each at different prices, taker only fills 2 due to maxFills.
        _placeSellYes(alice, 500_000, 10 * ONE_SHARE);
        _placeSellYes(carol, 510_000, 10 * ONE_SHARE);
        _placeSellYes(dave, 520_000, 10 * ONE_SHARE);
        _placeSellYes(makeAddr("eve"), 530_000, 10 * ONE_SHARE);
        _placeSellYes(makeAddr("frank"), 540_000, 10 * ONE_SHARE);

        _giveUsdc(bob, 100 * ONE_SHARE);
        vm.prank(bob);
        (uint256 filled,) = exchange.fillMarketOrder(
            MARKET_ID, IPrediXExchange.Side.BUY_YES, 600_000, 100 * ONE_SHARE, bob, bob, 2, _deadline()
        );

        assertEq(filled, 20 * ONE_SHARE, "exactly 2 fills");
    }

    // ============ 9. maxFills = 0 uses DEFAULT_MAX_FILLS = 10 ============

    function test_fillMarketOrder_maxFills_zero_uses_default() public {
        // 12 makers; with maxFills=0 (default 10), only 10 fill.
        for (uint256 i; i < 12; ++i) {
            address m = address(uint160(0x1000 + i));
            _placeSellYes(m, 500_000 + uint256(i) * 10_000, 1 * ONE_SHARE);
        }

        _giveUsdc(bob, 100 * ONE_SHARE);
        vm.prank(bob);
        (uint256 filled,) = exchange.fillMarketOrder(
            MARKET_ID, IPrediXExchange.Side.BUY_YES, 800_000, 100 * ONE_SHARE, bob, bob, 0, _deadline()
        );

        assertEq(filled, 10 * ONE_SHARE, "default cap = 10");
    }

    // ============ 10. deadline expired reverts ============

    function test_Revert_fillMarketOrder_deadlineExpired() public {
        _placeSellYes(alice, 500_000, 10 * ONE_SHARE);
        _giveUsdc(bob, 10 * ONE_SHARE);

        uint256 stale = block.timestamp - 1;
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(IPrediXExchange.DeadlineExpired.selector, stale, block.timestamp));
        exchange.fillMarketOrder(MARKET_ID, IPrediXExchange.Side.BUY_YES, 600_000, 10 * ONE_SHARE, bob, bob, 0, stale);
    }

    // ============ 11. refunds unused exact ============

    function test_fillMarketOrder_refunds_unused() public {
        _placeSellYes(alice, 500_000, 10 * ONE_SHARE);
        _giveUsdc(bob, 100 * ONE_SHARE);

        uint256 before = _usdcBalance(bob);
        vm.prank(bob);
        (, uint256 cost) = exchange.fillMarketOrder(
            MARKET_ID, IPrediXExchange.Side.BUY_YES, 600_000, 100 * ONE_SHARE, bob, bob, 0, _deadline()
        );

        // Spent exactly cost, refund = 100 - cost.
        assertEq(before - _usdcBalance(bob), cost, "spent == cost (refund exact)");
    }

    // ============ 12. empty CLOB returns (0, 0), refund all ============

    function test_fillMarketOrder_empty_clob() public {
        _giveUsdc(bob, 100 * ONE_SHARE);
        uint256 before = _usdcBalance(bob);

        vm.prank(bob);
        (uint256 filled, uint256 cost) = exchange.fillMarketOrder(
            MARKET_ID, IPrediXExchange.Side.BUY_YES, 600_000, 100 * ONE_SHARE, bob, bob, 0, _deadline()
        );

        assertEq(filled, 0, "no filled");
        assertEq(cost, 0, "no cost");
        assertEq(_usdcBalance(bob), before, "full refund");
    }

    // ============ 13. self-match complementary silently skips (L-06 audit Pass 2.1) ============

    function test_fillMarketOrder_selfMatchComplementary_SkipsSilently() public {
        // L-06: TakerPath now mirrors MakerPath — own orders are skipped via
        // `_peekBest`'s `taker` filter rather than reverting. The taker gets
        // a zero-fill (no other liquidity in this fixture).
        _placeSellYes(bob, 500_000, 10 * ONE_SHARE);
        _giveUsdc(bob, 10 * ONE_SHARE);

        uint256 before = _usdcBalance(bob);
        vm.prank(bob);
        (uint256 filled, uint256 cost) = exchange.fillMarketOrder(
            MARKET_ID, IPrediXExchange.Side.BUY_YES, 600_000, 10 * ONE_SHARE, bob, bob, 0, _deadline()
        );
        assertEq(filled, 0, "no fill - own order skipped");
        assertEq(cost, 0, "no cost");
        assertEq(_usdcBalance(bob), before, "full refund");
    }

    // ============ 14. self-match synthetic silently skips (L-06 audit Pass 2.1) ============

    function test_fillMarketOrder_selfMatchSynthetic_SkipsSilently() public {
        _placeBuyNo(bob, 400_000, 10 * ONE_SHARE);
        usdc.mint(bob, 10 * ONE_SHARE);
        uint256 before = _usdcBalance(bob);

        vm.prank(bob);
        (uint256 filled, uint256 cost) = exchange.fillMarketOrder(
            MARKET_ID, IPrediXExchange.Side.BUY_YES, 700_000, 10 * ONE_SHARE, bob, bob, 0, _deadline()
        );
        assertEq(filled, 0);
        assertEq(cost, 0);
        assertEq(_usdcBalance(bob), before);
    }

    // ============ 15. taker not approved reverts ============

    function test_Revert_fillMarketOrder_takerNotApproved() public {
        _placeSellYes(alice, 500_000, 10 * ONE_SHARE);
        usdc.mint(bob, 10 * ONE_SHARE);
        // No approve.

        vm.prank(bob);
        vm.expectRevert();
        exchange.fillMarketOrder(
            MARKET_ID, IPrediXExchange.Side.BUY_YES, 600_000, 10 * ONE_SHARE, bob, bob, 0, _deadline()
        );
    }

    // ============ 16. market expired reverts ============

    function test_Revert_fillMarketOrder_marketExpired() public {
        _placeSellYes(alice, 500_000, 10 * ONE_SHARE);
        _giveUsdc(bob, 10 * ONE_SHARE);
        diamond.setMarketEndTime(MARKET_ID, block.timestamp);

        vm.prank(bob);
        vm.expectRevert(IPrediXExchange.MarketExpired.selector);
        exchange.fillMarketOrder(
            MARKET_ID, IPrediXExchange.Side.BUY_YES, 600_000, 10 * ONE_SHARE, bob, bob, 0, _deadline()
        );
    }

    // ============ 17. market resolved reverts ============

    function test_Revert_fillMarketOrder_marketResolved() public {
        _placeSellYes(alice, 500_000, 10 * ONE_SHARE);
        _giveUsdc(bob, 10 * ONE_SHARE);
        diamond.setMarketResolved(MARKET_ID, true);

        vm.prank(bob);
        vm.expectRevert(IPrediXExchange.MarketResolved.selector);
        exchange.fillMarketOrder(
            MARKET_ID, IPrediXExchange.Side.BUY_YES, 600_000, 10 * ONE_SHARE, bob, bob, 0, _deadline()
        );
    }

    // ============ 18. market paused reverts (M2/C2) ============

    function test_Revert_fillMarketOrder_marketPaused_diamondModule() public {
        _placeSellYes(alice, 500_000, 10 * ONE_SHARE);
        _giveUsdc(bob, 10 * ONE_SHARE);
        // Use the canonical Modules.MARKET hash from shared (verifies C2 fix).
        bytes32 marketModule = keccak256("predix.module.market");
        diamond.setModulePaused(marketModule, true);

        vm.prank(bob);
        vm.expectRevert(IPrediXExchange.MarketPaused.selector);
        exchange.fillMarketOrder(
            MARKET_ID, IPrediXExchange.Side.BUY_YES, 600_000, 10 * ONE_SHARE, bob, bob, 0, _deadline()
        );
    }

    // ============ 19. market refund mode reverts ============

    function test_Revert_fillMarketOrder_marketRefundMode() public {
        _placeSellYes(alice, 500_000, 10 * ONE_SHARE);
        _giveUsdc(bob, 10 * ONE_SHARE);
        diamond.setMarketRefundMode(MARKET_ID, true);

        vm.prank(bob);
        vm.expectRevert(IPrediXExchange.MarketInRefundMode.selector);
        exchange.fillMarketOrder(
            MARKET_ID, IPrediXExchange.Side.BUY_YES, 600_000, 10 * ONE_SHARE, bob, bob, 0, _deadline()
        );
    }

    // ============ 20. TakerFilled event emitted ============

    function test_fillMarketOrder_takerFilledEventEmitted() public {
        _placeSellYes(alice, 500_000, 10 * ONE_SHARE);
        _giveUsdc(bob, 10 * ONE_SHARE);

        vm.expectEmit(true, true, true, true);
        emit IPrediXExchange.TakerFilled(
            MARKET_ID, bob, bob, IPrediXExchange.Side.BUY_YES, 10 * ONE_SHARE, 5 * ONE_SHARE, 1
        );
        vm.prank(bob);
        exchange.fillMarketOrder(
            MARKET_ID, IPrediXExchange.Side.BUY_YES, 600_000, 10 * ONE_SHARE, bob, bob, 0, _deadline()
        );
    }

    // ============ 21. OrderMatched per fill ============

    function test_fillMarketOrder_orderMatched_event_per_fill() public {
        bytes32 makerId = _placeSellYes(alice, 500_000, 10 * ONE_SHARE);
        _giveUsdc(bob, 10 * ONE_SHARE);

        vm.expectEmit(true, true, true, true);
        emit IPrediXExchange.OrderMatched(
            makerId, bytes32(0), MARKET_ID, IPrediXExchange.MatchType.COMPLEMENTARY, 10 * ONE_SHARE, 500_000
        );
        vm.prank(bob);
        exchange.fillMarketOrder(
            MARKET_ID, IPrediXExchange.Side.BUY_YES, 600_000, 10 * ONE_SHARE, bob, bob, 0, _deadline()
        );
    }

    // ============ 22. recipient ≠ taker ============

    function test_fillMarketOrder_recipientDifferentFromTaker() public {
        _placeSellYes(alice, 500_000, 10 * ONE_SHARE);
        _giveUsdc(bob, 10 * ONE_SHARE);

        vm.prank(bob);
        exchange.fillMarketOrder(
            MARKET_ID, IPrediXExchange.Side.BUY_YES, 600_000, 10 * ONE_SHARE, bob, carol, 0, _deadline()
        );

        assertEq(_yesBalance(carol), 10 * ONE_SHARE, "recipient got YES");
        assertEq(_yesBalance(bob), 0, "taker got nothing");
    }

    // ============ 23. multi-level waterfall ============

    function test_fillMarketOrder_multiLevelWaterfall() public {
        _placeSellYes(alice, 500_000, 30 * ONE_SHARE);
        _placeSellYes(carol, 510_000, 30 * ONE_SHARE);
        _placeSellYes(dave, 520_000, 30 * ONE_SHARE);

        _giveUsdc(bob, 100 * ONE_SHARE);
        vm.prank(bob);
        (uint256 filled,) = exchange.fillMarketOrder(
            MARKET_ID, IPrediXExchange.Side.BUY_YES, 700_000, 100 * ONE_SHARE, bob, bob, 0, _deadline()
        );

        assertEq(filled, 90 * ONE_SHARE, "all 3 levels filled");
    }

    // ============ 24. stops when budget exhausted ============

    function test_fillMarketOrder_stopsWhenBudgetExhausted() public {
        _placeSellYes(alice, 500_000, 1000 * ONE_SHARE);
        _giveUsdc(bob, 25 * ONE_SHARE); // budget for 50 shares only

        vm.prank(bob);
        (uint256 filled, uint256 cost) = exchange.fillMarketOrder(
            MARKET_ID, IPrediXExchange.Side.BUY_YES, 600_000, 25 * ONE_SHARE, bob, bob, 0, _deadline()
        );

        assertEq(filled, 50 * ONE_SHARE, "filled exactly budget");
        assertEq(cost, 25 * ONE_SHARE, "cost = budget");
    }

    // ============ 25. synthetic preserves YES.supply == NO.supply ============

    function test_fillMarketOrder_syntheticCollateralInvariant() public {
        _placeBuyNo(alice, 400_000, 100 * ONE_SHARE);
        _giveUsdc(bob, 100 * ONE_SHARE);

        vm.prank(bob);
        exchange.fillMarketOrder(
            MARKET_ID, IPrediXExchange.Side.BUY_YES, 700_000, 100 * ONE_SHARE, bob, bob, 0, _deadline()
        );

        assertEq(IERC20(yesToken).totalSupply(), IERC20(noToken).totalSupply(), "YES.supply == NO.supply");
    }

    // ============ Extra: zero-address checks ============

    function test_Revert_fillMarketOrder_zeroTaker() public {
        vm.expectRevert(IPrediXExchange.ZeroAddress.selector);
        exchange.fillMarketOrder(
            MARKET_ID, IPrediXExchange.Side.BUY_YES, 600_000, 1 * ONE_SHARE, address(0), bob, 0, _deadline()
        );
    }

    function test_Revert_fillMarketOrder_zeroRecipient() public {
        vm.expectRevert(IPrediXExchange.ZeroAddress.selector);
        exchange.fillMarketOrder(
            MARKET_ID, IPrediXExchange.Side.BUY_YES, 600_000, 1 * ONE_SHARE, bob, address(0), 0, _deadline()
        );
    }

    // ============ Extra: amountIn = 0 returns (0, 0) without revert ============

    function test_fillMarketOrder_zeroAmountInReturnsZero() public {
        (uint256 f, uint256 c) =
            exchange.fillMarketOrder(MARKET_ID, IPrediXExchange.Side.BUY_YES, 600_000, 0, bob, bob, 0, _deadline());
        assertEq(f, 0);
        assertEq(c, 0);
    }

    // ============ Extra: market not found translated by Exchange ============

    function test_Revert_fillMarketOrder_marketNotFound() public {
        _giveUsdc(bob, 1 * ONE_SHARE);
        vm.prank(bob);
        vm.expectRevert(IPrediXExchange.MarketNotFound.selector);
        exchange.fillMarketOrder(999, IPrediXExchange.Side.BUY_YES, 600_000, 1 * ONE_SHARE, bob, bob, 0, _deadline());
    }
}
