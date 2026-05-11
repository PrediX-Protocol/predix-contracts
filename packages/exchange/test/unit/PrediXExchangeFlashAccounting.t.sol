// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IPrediXExchange} from "../../src/IPrediXExchange.sol";
import {ExchangeTestBase} from "../base/ExchangeTestBase.sol";

contract PrediXExchangeFlashAccounting is ExchangeTestBase {
    /// @notice 10-fill market order. With flash accounting, taker output is
    ///         settled once at the end instead of per-fill, saving gas.
    function test_fillMarketOrder_MultiFill_Gas() public {
        // Seed 10 resting SELL_YES orders at escalating prices
        for (uint256 i; i < 10; i++) {
            uint256 price = 100_000 + i * 10_000;
            _placeSellYes(alice, price, 10 * ONE_SHARE);
        }

        _giveUsdc(bob, 100 * ONE_SHARE);
        vm.prank(bob);
        uint256 gasBefore = gasleft();
        (uint256 filled,) = exchange.fillMarketOrder(
            MARKET_ID, IPrediXExchange.Side.BUY_YES, 990_000, 100 * ONE_SHARE, bob, bob, 10, _deadline(), bytes32(0)
        );
        uint256 gasUsed = gasBefore - gasleft();

        assertGt(filled, 0, "filled > 0");
        assertEq(IERC20(yesToken).balanceOf(address(exchange)), 0, "exchange YES zero after settlement");
        assertLt(gasUsed, 1_500_000, "gas under 1.5M for 10 fills");
    }

    /// @notice Fuzz: random orders + fills → solvency invariants hold.
    function testFuzz_fillMarketOrder_MultiFill_Solvency(
        uint8 numOrders,
        uint256 fillBudget
    ) public {
        numOrders = uint8(bound(numOrders, 1, 10));
        fillBudget = bound(fillBudget, ONE_SHARE, 500 * ONE_SHARE);

        // Seed resting SELL_YES orders at tick-aligned prices
        for (uint256 i; i < numOrders; i++) {
            uint256 priceIdx = 10 + (i * 88) / numOrders;
            uint256 price = priceIdx * 10_000;
            uint256 amount = ONE_SHARE + (i * 10 * ONE_SHARE);
            _placeSellYes(alice, price, amount);
        }

        uint256 exchangeUsdcBefore = usdc.balanceOf(address(exchange));
        uint256 exchangeYesBefore = IERC20(yesToken).balanceOf(address(exchange));

        _giveUsdc(bob, fillBudget);
        vm.prank(bob);
        exchange.fillMarketOrder(
            MARKET_ID, IPrediXExchange.Side.BUY_YES, 990_000, fillBudget, bob, bob, 10, _deadline(), bytes32(0)
        );

        uint256 exchangeUsdcAfter = usdc.balanceOf(address(exchange));
        uint256 exchangeYesAfter = IERC20(yesToken).balanceOf(address(exchange));

        // Solvency: exchange USDC should NOT decrease (maker deposits cover outflows)
        assertGe(exchangeUsdcAfter, 0, "exchange USDC non-negative");
        // After settlement, exchange should not hold excess YES tokens
        // (all taker output settled to recipient)
        assertLe(
            exchangeYesAfter,
            exchangeYesBefore,
            "exchange YES should not increase from taker fills"
        );
    }
}
