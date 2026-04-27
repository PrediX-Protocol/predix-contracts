// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {IPrediXExchange} from "../../src/IPrediXExchange.sol";
import {ExchangeTestBase} from "../base/ExchangeTestBase.sol";

/// @notice Fix-lock for AUDIT-M-01 (Pass 2.1):
///         TakerPath now force-cleans dust orders at the FIFO head instead
///         of breaking the waterfall. When `(fillAmount * makerPrice) / 1e6`
///         floors to zero, the dust maker is marked fully-filled, residual
///         `depositLocked` (in shares for SELL orders, USDC for BUY orders)
///         is swept to `feeRecipient`, queue + bitmap entries are dropped,
///         and the loop continues to deeper liquidity.
contract Audit_NEW_M01_DustHeadDoS is ExchangeTestBase {
    address internal eve = makeAddr("eve");

    /// @dev FIX-LOCK: Alice's 1-share SELL_YES dust at $0.01 no longer blocks
    ///      Bob's BUY_YES taker. The waterfall force-cleans Alice's dust and
    ///      reaches Carol's $0.02 liquidity.
    function test_DustHeadAt1Cent_NoLongerBlocksTakers() public {
        uint256 dustPrice = 10_000; // $0.01

        _placeSellYes(alice, dustPrice, 2e6);
        // Eve takes 1_999_999, leaves Alice with 1 share dust.
        _placeBuyYes(eve, dustPrice, 1_999_999);

        _placeSellYes(carol, 20_000, 10e6);

        _giveUsdc(bob, 100e6);
        uint256 bobYesBefore = _yesBalance(bob);

        vm.prank(bob);
        (uint256 filled, uint256 cost) = exchange.fillMarketOrder(
            MARKET_ID, IPrediXExchange.Side.BUY_YES, 990_000, 100e6, bob, bob, 10, block.timestamp + 60
        );

        // M-01 fix: dust auto-cleaned, Bob reached Carol's $0.02 liquidity.
        assertGt(filled, 0, "M-01 fix: taker reaches deeper liquidity past dust");
        assertGt(cost, 0);
        assertGt(_yesBalance(bob) - bobYesBefore, 0);
    }

    /// @dev FIX-LOCK: dust at $0.50 also auto-cleaned.
    function test_DustAt50Cents_NoLongerBlocks() public {
        uint256 dustPrice = 500_000;

        _placeSellYes(alice, dustPrice, 2e6);
        _placeBuyYes(eve, dustPrice, 1_999_999);

        _placeSellYes(carol, 510_000, 10e6);

        _giveUsdc(bob, 100e6);
        vm.prank(bob);
        (uint256 filled,) = exchange.fillMarketOrder(
            MARKET_ID, IPrediXExchange.Side.BUY_YES, 990_000, 100e6, bob, bob, 10, block.timestamp + 60
        );
        assertGt(filled, 0, "M-01 fix at $0.50");
    }

    /// @dev FIX-LOCK: residual SELL token dust swept to feeRecipient on
    ///      force-clean. Confirms the dust isn't lost / stuck.
    function test_DustResidual_SweptToFeeRecipient() public {
        uint256 dustPrice = 10_000;
        _placeSellYes(alice, dustPrice, 2e6);
        _placeBuyYes(eve, dustPrice, 1_999_999);

        // Provide deeper liquidity so the taker triggers force-clean of dust head.
        _placeSellYes(carol, 20_000, 10e6);

        uint256 feeRecipientYesBefore = _yesBalance(feeRecipient);

        _giveUsdc(bob, 100e6);
        vm.prank(bob);
        exchange.fillMarketOrder(
            MARKET_ID, IPrediXExchange.Side.BUY_YES, 990_000, 100e6, bob, bob, 10, block.timestamp + 60
        );

        // 1 share of YES (Alice's dust) swept to feeRecipient.
        assertEq(_yesBalance(feeRecipient) - feeRecipientYesBefore, 1, "1-share dust swept");
    }

    /// @dev Sanity: MakerPath retains the symmetric advance-past-dust behaviour.
    function test_Sanity_MakerPath_AdvancesPastDust() public {
        uint256 dustPrice = 10_000;
        _placeSellYes(alice, dustPrice, 2e6);
        _placeBuyYes(eve, dustPrice, 1_999_999);

        _placeSellYes(carol, 20_000, 10e6);

        _giveUsdc(bob, 100e6);
        vm.prank(bob);
        (, uint256 placerFilled) = exchange.placeOrder(MARKET_ID, IPrediXExchange.Side.BUY_YES, 50_000, 1e6);
        assertGt(placerFilled, 0, "MakerPath progresses past dust");
    }
}
