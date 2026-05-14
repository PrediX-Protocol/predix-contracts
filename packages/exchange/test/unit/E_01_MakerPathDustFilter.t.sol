// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import {IPrediXExchange} from "../../src/IPrediXExchange.sol";

import {ExchangeTestBase} from "../base/ExchangeTestBase.sol";

/// @notice Repro for E-01: MakerPath `_matchCompAtTick` must NEVER execute a
///         match where `fillAmt * makerPrice` floors to 0. Pre-original-fix the
///         fill executed and transferred tokens on one leg for 0 USDC
///         consideration — silent wealth transfer between parties. After M-04
///         the dust filter distinguishes structural-maker-dust (force-clean +
///         sweep residual to feeRecipient) from sub-tick-placer (skip without
///         state mutation). The silent-wealth-transfer invariant still holds:
///         the next placer never receives the dust residual for free.
contract E_01_MakerPathDustFilter is ExchangeTestBase {
    /// @dev Alice posts SELL_YES at 990_000 (max tick) amount=1_000_001. Bob
    ///      fills 1_000_000, leaving Alice with 1 share of STRUCTURAL dust:
    ///        (1 * 990_000) / 1e6 == 0 — no possible fill at her price tick.
    ///      Carol then places BUY_YES at the same price. M-04 force-cleans
    ///      Alice's dust: 1 YES sweeps to feeRecipient, queue + bitmap clear,
    ///      Carol finds no liquidity and rests at full size. The original E-01
    ///      invariant (Carol receives 0 free tokens) is preserved.
    function test_E_01_dustMatchSkippedPreservingLedger() public {
        uint256 price = 990_000;
        uint256 aliceSize = 1_000_001;
        uint256 bobFillSize = 1_000_000;
        uint256 carolSize = 1_000_000;

        _placeSellYes(alice, price, aliceSize);
        _giveUsdc(bob, (bobFillSize * price) / 1e6);
        vm.prank(bob);
        exchange.placeOrder(MARKET_ID, IPrediXExchange.Side.BUY_YES, price, bobFillSize, bytes32(0));

        uint256 carolYesBefore = _yesBalance(carol);
        uint256 feeRecipientYesBefore = _yesBalance(feeRecipient);

        _giveUsdc(carol, (carolSize * price) / 1e6);
        vm.prank(carol);
        (bytes32 carolId, uint256 filled) =
            exchange.placeOrder(MARKET_ID, IPrediXExchange.Side.BUY_YES, price, carolSize, bytes32(0));

        // Silent-wealth-transfer guarantee: Carol must not receive the dust.
        assertEq(filled, 0, "dust must not produce a fill");
        assertEq(_yesBalance(carol), carolYesBefore, "carol must NOT receive free tokens");

        // M-04: structural dust is force-cleaned. 1 YES sweeps to feeRecipient
        // instead of being stranded inside the exchange.
        assertEq(
            _yesBalance(feeRecipient) - feeRecipientYesBefore, 1, "alice's 1-share dust swept to feeRecipient"
        );

        // Carol's order sits on the book at full size.
        IPrediXExchange.Order memory carolOrder = exchange.getOrder(carolId);
        assertEq(uint256(carolOrder.filled), 0, "carol.filled stays 0");
        assertEq(uint256(carolOrder.amount), carolSize, "carol.amount preserved on book");
        assertFalse(carolOrder.cancelled, "carol order not cancelled");
    }

    function test_E_01_nonDustMatchStillFills() public {
        // Non-dust sanity: a regular-size match at the same price executes.
        uint256 price = 500_000;
        _placeSellYes(alice, price, 100 * ONE_SHARE);
        _giveUsdc(bob, 50 * ONE_SHARE);

        vm.prank(bob);
        (, uint256 filled) = exchange.placeOrder(MARKET_ID, IPrediXExchange.Side.BUY_YES, price, 100 * ONE_SHARE, bytes32(0));

        assertEq(filled, 100 * ONE_SHARE, "normal match must fill fully");
        assertEq(_yesBalance(bob), 100 * ONE_SHARE, "bob receives YES");
    }
}
