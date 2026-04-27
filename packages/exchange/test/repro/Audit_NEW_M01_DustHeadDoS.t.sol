// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {IPrediXExchange} from "../../src/IPrediXExchange.sol";
import {ExchangeTestBase} from "../base/ExchangeTestBase.sol";

/// @notice Repro for AUDIT-NEW-M-01 (Fresh audit pass 2, 2026-04-25):
///
///         A resting maker order at the BEST price level whose remaining
///         capacity rounds to zero USDC consideration (i.e.
///         `(remaining * makerPrice) / 1e6 == 0`) blocks ALL takers on that
///         side. `MatchMath.computeFillDeltas` returns `(0, 0)` when
///         `makerShare` floors to zero. `_executeComplementaryTakerFill`
///         early-returns `(0, 0)`. The outer waterfall loop in
///         `_fillMarketOrder` (TakerPath.sol:94) sees `outDelta == 0` and
///         BREAKS — never advancing past the dust head to live liquidity
///         sitting behind it (or at worse price levels).
///
///         The MakerPath dust filter handles the symmetric case correctly via
///         `i++; continue;` — placing a maker order skips dust orders rather
///         than aborting. The TakerPath asymmetry is the bug.
///
///         Threshold for dust at price P: remaining < 1e6 / P. At $0.01
///         (P = 1e4), remaining < 100 shares is dust. At $0.50, remaining < 2
///         shares. At $0.99, remaining = 1 share is dust.
///
///         These tests demonstrate the bug at HEAD `ce524ba`. They will FAIL
///         (or need updating) when the fix lands. Recommended fix: at the
///         dust short-circuit, advance to the next maker in the queue OR
///         force-clean the dust order by setting `filled = amount` and
///         calling `_onMakerFullyFilled` to sweep residual to feeRecipient.
contract Audit_NEW_M01_DustHeadDoS is ExchangeTestBase {
    address internal eve = makeAddr("eve");

    /// @dev DEMONSTRATES BUG: Alice's 1-share SELL_YES at $0.01 (dust) blocks
    ///      Bob's 1e6-share BUY_YES taker order. Carol's deeper liquidity at
    ///      $0.02 is never reached even though Bob's limitPrice is $0.99.
    function test_BUG_DustHeadAt1Cent_BlocksAllBuyYesTakers() public {
        uint256 dustPrice = 10_000; // $0.01

        // Alice: SELL_YES at $0.01, amount=2e6 shares (must exceed
        // MIN_ORDER_AMOUNT). Will be partially filled to leave 1 share of dust.
        _placeSellYes(alice, dustPrice, 2e6);

        // Eve places a BUY_YES at $0.01, amount = 1_999_999 shares (one less
        // than Alice). Phase A complementary fully matches Eve against Alice,
        // leaving Alice with EXACTLY 1 share dust at the best-ask level.
        _placeBuyYes(eve, dustPrice, 1_999_999);

        // Carol: SELL_YES at $0.02 (one tick worse), amount=10e6 shares.
        // Real liquidity that should be reachable.
        _placeSellYes(carol, 20_000, 10e6);

        // Bob: tries to BUY_YES with 100 USDC, limit $0.99, expects to walk
        // past Alice's dust into Carol's liquidity.
        _giveUsdc(bob, 100e6);
        uint256 bobYesBefore = _yesBalance(bob);
        uint256 bobUsdcBefore = usdc.balanceOf(bob);

        vm.prank(bob);
        (uint256 filled, uint256 cost) = exchange.fillMarketOrder(
            MARKET_ID,
            IPrediXExchange.Side.BUY_YES,
            990_000, // limit $0.99 — well above any maker
            100e6, // 100 USDC budget
            bob,
            bob,
            10,
            block.timestamp + 60
        );

        // BUG: filled == 0 because Alice's dust at $0.01 is the FIFO head of
        // best-ask, and `(1 * 10000) / 1e6 = 0` → outDelta=0 → outer loop break.
        // Carol's $0.02 liquidity is NEVER reached.
        assertEq(filled, 0, "BUG: dust blocks all BUY_YES takers");
        assertEq(cost, 0, "BUG: nothing consumed");
        assertEq(_yesBalance(bob) - bobYesBefore, 0, "BUG: Bob got no YES");
        assertEq(usdc.balanceOf(bob), bobUsdcBefore, "BUG: Bob's USDC fully refunded");
    }

    /// @dev BUG variant: dust at higher price ($0.50) still blocks. At $0.50,
    ///      remaining=1 share floors to 0 USDC (1*5e5/1e6=0). Only remaining=2+
    ///      avoids dust threshold at $0.50.
    function test_BUG_DustAt50Cents_BlocksTakers() public {
        uint256 dustPrice = 500_000; // $0.50

        // Alice's amount must exceed MIN_ORDER_AMOUNT (=1e6). Use 2e6 so we
        // can leave 1 share dust after Eve takes 1_999_999.
        _placeSellYes(alice, dustPrice, 2e6);

        // Eve placeBuyYes 1_999_999 shares at the dust price. Partial-fills
        // Alice via Phase A, leaves Alice with EXACTLY 1 share dust.
        _placeBuyYes(eve, dustPrice, 1_999_999);

        // Carol: real liquidity at $0.51.
        _placeSellYes(carol, 510_000, 10e6);

        _giveUsdc(bob, 100e6);
        vm.prank(bob);
        (uint256 filled,) = exchange.fillMarketOrder(
            MARKET_ID, IPrediXExchange.Side.BUY_YES, 990_000, 100e6, bob, bob, 10, block.timestamp + 60
        );
        assertEq(filled, 0, "BUG: dust at $0.50 blocks deeper liquidity");
    }

    /// @dev Sanity: dust-head DOES NOT block MakerPath placers. A new maker
    ///      placing an opposite-side order silently skips the dust and matches
    ///      against deeper liquidity. Asymmetry confirmed.
    function test_Sanity_MakerPath_AdvancesPastDust() public {
        uint256 dustPrice = 10_000;

        _placeSellYes(alice, dustPrice, 2e6);

        // Eve partial-fills via placeBuyYes (amount must >= MIN_ORDER_AMOUNT),
        // leaves Alice with 1 dust share.
        _placeBuyYes(eve, dustPrice, 1_999_999);

        // Carol: SELL_YES at $0.02.
        _placeSellYes(carol, 20_000, 10e6);

        // Bob places BUY_YES at $0.05 limit (above Carol's $0.02). MakerPath
        // matches against the resting book: Phase A complementary walks
        // SELL_YES queue. At $0.01 idx, Alice's dust → MakerPath dust filter
        // skips with `i++; continue;`. Then walks $0.02 idx → finds Carol →
        // matches. So MakerPath PROGRESSES past the dust.
        _giveUsdc(bob, 100e6);
        vm.prank(bob);
        (, uint256 filledFromBookByPlacer) = exchange.placeOrder(MARKET_ID, IPrediXExchange.Side.BUY_YES, 50_000, 1e6);

        // Bob's BUY_YES placer matched against Carol at $0.02 (best avail
        // after dust skip). Verify positive fill.
        assertGt(filledFromBookByPlacer, 0, "MakerPath progresses past dust correctly");
    }

    /// @dev EXPECTED-AFTER-FIX placeholder. When the fix lands, the bug-repro
    ///      tests must invert: Bob's BUY_YES taker should successfully fill
    ///      against Carol's $0.02 liquidity instead of hitting `filled == 0`.
    function test_DESIRED_TakerSkipsDustHead_PendingFix() public pure {
        return;
    }
}
