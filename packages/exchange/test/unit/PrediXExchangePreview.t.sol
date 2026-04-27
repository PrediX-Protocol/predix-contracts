// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Vm} from "forge-std/Vm.sol";

import {IPrediXExchange} from "../../src/IPrediXExchange.sol";

import {ExchangeTestBase} from "../base/ExchangeTestBase.sol";

/// @title PrediXExchangePreviewTest
/// @notice Spec §8.2 preview tests + multi-level walk regression coverage.
contract PrediXExchangePreviewTest is ExchangeTestBase {
    // ============ 1. preview matches actual fill (3 paths + multi-level) ============

    function test_preview_matches_actualFill_complementary() public {
        _placeSellYes(alice, 500_000, 100 * ONE_SHARE);
        _giveUsdc(bob, 100 * ONE_SHARE);

        (uint256 pf, uint256 pc) = exchange.previewFillMarketOrder(
            MARKET_ID, IPrediXExchange.Side.BUY_YES, 600_000, 100 * ONE_SHARE, 0, address(0)
        );

        vm.prank(bob);
        (uint256 af, uint256 ac) = exchange.fillMarketOrder(
            MARKET_ID, IPrediXExchange.Side.BUY_YES, 600_000, 100 * ONE_SHARE, bob, bob, 0, _deadline()
        );

        assertEq(pf, af, "filled");
        assertEq(pc, ac, "cost");
    }

    function test_preview_matches_actualFill_mint() public {
        _placeBuyNo(alice, 400_000, 100 * ONE_SHARE);
        _giveUsdc(bob, 100 * ONE_SHARE);

        (uint256 pf, uint256 pc) = exchange.previewFillMarketOrder(
            MARKET_ID, IPrediXExchange.Side.BUY_YES, 700_000, 100 * ONE_SHARE, 0, address(0)
        );

        vm.prank(bob);
        (uint256 af, uint256 ac) = exchange.fillMarketOrder(
            MARKET_ID, IPrediXExchange.Side.BUY_YES, 700_000, 100 * ONE_SHARE, bob, bob, 0, _deadline()
        );

        assertEq(pf, af);
        assertEq(pc, ac);
    }

    function test_preview_matches_actualFill_merge() public {
        _placeSellNo(alice, 400_000, 100 * ONE_SHARE);
        _giveYesNo(bob, 100 * ONE_SHARE);

        (uint256 pf, uint256 pc) = exchange.previewFillMarketOrder(
            MARKET_ID, IPrediXExchange.Side.SELL_YES, 500_000, 100 * ONE_SHARE, 0, address(0)
        );

        vm.prank(bob);
        (uint256 af, uint256 ac) = exchange.fillMarketOrder(
            MARKET_ID, IPrediXExchange.Side.SELL_YES, 500_000, 100 * ONE_SHARE, bob, bob, 0, _deadline()
        );

        assertEq(pf, af);
        assertEq(pc, ac);
    }

    /// @notice Multi-level virtual walk regression — preview must traverse the
    ///         bitmap when one level is fully consumed mid-iteration.
    function test_preview_virtualConsumptionTracking_multiLevel() public {
        _placeSellYes(alice, 500_000, 50 * ONE_SHARE);
        _placeSellYes(carol, 600_000, 50 * ONE_SHARE);
        _giveUsdc(bob, 100 * ONE_SHARE);

        (uint256 pf, uint256 pc) = exchange.previewFillMarketOrder(
            MARKET_ID, IPrediXExchange.Side.BUY_YES, 700_000, 100 * ONE_SHARE, 0, address(0)
        );

        vm.prank(bob);
        (uint256 af, uint256 ac) = exchange.fillMarketOrder(
            MARKET_ID, IPrediXExchange.Side.BUY_YES, 700_000, 100 * ONE_SHARE, bob, bob, 0, _deadline()
        );

        assertEq(pf, 100 * ONE_SHARE, "filled both levels");
        assertEq(pc, 55 * ONE_SHARE, "$25 + $30");
        assertEq(pf, af);
        assertEq(pc, ac);
    }

    // ============ 2. preview no state mutation ============

    function test_preview_no_state_mutation() public {
        bytes32 mid = _placeSellYes(alice, 500_000, 100 * ONE_SHARE);

        (uint256 bbY0, uint256 baY0, uint256 bbN0, uint256 baN0) = exchange.getBestPrices(MARKET_ID);
        IPrediXExchange.Order memory ord0 = exchange.getOrder(mid);
        uint256 bm0 = exchange.priceBitmap(MARKET_ID, IPrediXExchange.Side.SELL_YES);
        uint256 cnt0 = exchange.userOrderCount(MARKET_ID, alice);
        uint256 makerUsdc0 = _usdcBalance(alice);

        exchange.previewFillMarketOrder(
            MARKET_ID, IPrediXExchange.Side.BUY_YES, 600_000, 100 * ONE_SHARE, 0, address(0)
        );

        (uint256 bbY1, uint256 baY1, uint256 bbN1, uint256 baN1) = exchange.getBestPrices(MARKET_ID);
        IPrediXExchange.Order memory ord1 = exchange.getOrder(mid);
        uint256 bm1 = exchange.priceBitmap(MARKET_ID, IPrediXExchange.Side.SELL_YES);
        uint256 cnt1 = exchange.userOrderCount(MARKET_ID, alice);
        uint256 makerUsdc1 = _usdcBalance(alice);

        assertEq(bbY1, bbY0);
        assertEq(baY1, baY0);
        assertEq(bbN1, bbN0);
        assertEq(baN1, baN0);
        assertEq(bm1, bm0);
        assertEq(cnt1, cnt0);
        assertEq(ord1.filled, ord0.filled);
        assertEq(ord1.depositLocked, ord0.depositLocked);
        assertEq(makerUsdc1, makerUsdc0);
    }

    // ============ 3. preview emits no events ============

    function test_preview_no_events_emitted() public {
        _placeSellYes(alice, 500_000, 100 * ONE_SHARE);

        vm.recordLogs();
        exchange.previewFillMarketOrder(
            MARKET_ID, IPrediXExchange.Side.BUY_YES, 600_000, 100 * ONE_SHARE, 0, address(0)
        );
        Vm.Log[] memory logs = vm.getRecordedLogs();
        assertEq(logs.length, 0, "no events");
    }

    // ============ 4. preview empty CLOB ============

    function test_preview_empty_clob() public view {
        (uint256 f, uint256 c) = exchange.previewFillMarketOrder(
            MARKET_ID, IPrediXExchange.Side.BUY_YES, 600_000, 100 * ONE_SHARE, 0, address(0)
        );
        assertEq(f, 0);
        assertEq(c, 0);
    }

    // ============ 5. preview market state gating mirrors fill ============

    function test_Revert_preview_marketResolved() public {
        _placeSellYes(alice, 500_000, 10 * ONE_SHARE);
        diamond.setMarketResolved(MARKET_ID, true);

        vm.expectRevert(IPrediXExchange.MarketResolved.selector);
        exchange.previewFillMarketOrder(MARKET_ID, IPrediXExchange.Side.BUY_YES, 600_000, 10 * ONE_SHARE, 0, address(0));
    }

    function test_preview_zeroAmountInReturnsZero() public view {
        (uint256 f, uint256 c) =
            exchange.previewFillMarketOrder(MARKET_ID, IPrediXExchange.Side.BUY_YES, 600_000, 0, 0, address(0));
        assertEq(f, 0);
        assertEq(c, 0);
    }
}
