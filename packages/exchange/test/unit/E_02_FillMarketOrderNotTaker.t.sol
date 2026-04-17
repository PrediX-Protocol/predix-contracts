// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {IPrediXExchange} from "../../src/IPrediXExchange.sol";

import {ExchangeTestBase} from "../base/ExchangeTestBase.sol";

/// @notice Repro for E-02: `fillMarketOrder` must reject calls where
///         `msg.sender != taker`. Otherwise any attacker with a matching
///         resting order can drain any address that has a non-zero USDC
///         allowance to the Exchange (every address that placed a maker order).
contract E_02_FillMarketOrderNotTaker is ExchangeTestBase {
    function test_Revert_E_02_attackerCannotDrainVictim() public {
        address victim = alice;
        address attacker = bob;

        // Victim approves Exchange (natural side-effect of placing any order).
        _giveUsdc(victim, 1_000 * ONE_SHARE);

        // Attacker seeds a resting SELL_YES order so the taker path has liquidity.
        _placeSellYes(attacker, 500_000, 100 * ONE_SHARE);

        // Attack: attacker calls fillMarketOrder with taker=victim, recipient=attacker.
        // Victim's USDC would be pulled, tokens routed to attacker.
        vm.prank(attacker);
        vm.expectRevert(IPrediXExchange.NotTaker.selector);
        exchange.fillMarketOrder(
            MARKET_ID,
            IPrediXExchange.Side.BUY_YES,
            500_000,
            100 * ONE_SHARE,
            victim, // spoofed funding source
            attacker, // attacker pockets the output
            0,
            _deadline()
        );
    }

    function test_E_02_legitimateSelfTakerStillWorks() public {
        // Sanity: taker == msg.sender path continues to work (the canonical flow).
        _placeSellYes(alice, 500_000, 100 * ONE_SHARE);
        _giveUsdc(bob, 100 * ONE_SHARE);

        vm.prank(bob);
        (uint256 filled, uint256 cost) = exchange.fillMarketOrder(
            MARKET_ID, IPrediXExchange.Side.BUY_YES, 600_000, 100 * ONE_SHARE, bob, bob, 0, _deadline()
        );

        assertEq(filled, 100 * ONE_SHARE, "filled");
        assertEq(cost, 50 * ONE_SHARE, "cost");
    }

    function test_E_02_recipientMayDifferFromTaker() public {
        // Only `msg.sender == taker` is required. `recipient` can still be
        // a distinct address (e.g., user taking via a frontend that receives
        // tokens into a different custodial account).
        _placeSellYes(alice, 500_000, 100 * ONE_SHARE);
        _giveUsdc(bob, 100 * ONE_SHARE);

        address recipient = carol;
        vm.prank(bob);
        exchange.fillMarketOrder(
            MARKET_ID, IPrediXExchange.Side.BUY_YES, 600_000, 100 * ONE_SHARE, bob, recipient, 0, _deadline()
        );

        assertEq(_yesBalance(recipient), 100 * ONE_SHARE, "recipient receives");
        assertEq(_yesBalance(bob), 0, "taker does not receive");
    }
}
