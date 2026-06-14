// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import {IPrediXExchange} from "../../src/IPrediXExchange.sol";
import {Roles} from "@predix/shared/constants/Roles.sol";
import {ExchangeTestBase} from "../base/ExchangeTestBase.sol";

/// @notice Task 9: the fee-inclusive preview must mirror the taker-path EXECUTE exactly (else the router's
///         `_convergeCap` diverges). Parity is asserted by previewing, then executing the identical fill from
///         the same book, and comparing (filled, cost) + the protocol fee. Builder fee is excluded (router path).
contract PreviewFeeTest is ExchangeTestBase {
    address internal mk = makeAddr("pvMaker");
    address internal tk = makeAddr("pvTaker");
    address internal treasury = makeAddr("pvTreasury");

    function setUp() public override {
        super.setUp();
        diamond.grantRole(Roles.ADMIN_ROLE, address(this));
        exchange.setProtocolFeeRecipient(treasury);
    }

    function _dl() internal view returns (uint256) {
        return block.timestamp + 1;
    }

    // BUY, budget NOT binding (full fill): preview cost (notional + F) == execute cost; previewProtocolFee == F.
    function test_previewBuy_fullFill_costParity() public {
        diamond.setProtocolFee(MARKET_ID, 700, 0);
        _placeSellYes(mk, 500_000, 1e8);
        uint256 amountIn = 60e6;
        (uint256 fP, uint256 cP) =
            exchange.previewFillMarketOrder(MARKET_ID, IPrediXExchange.Side.BUY_YES, 500_000, amountIn, 0, tk);
        uint256 protoP = exchange.previewProtocolFee(MARKET_ID, IPrediXExchange.Side.BUY_YES, 500_000, amountIn, 0, tk);
        _giveUsdc(tk, amountIn);
        uint256 tkBefore = _usdcBalance(tk);
        vm.prank(tk);
        (uint256 fE, uint256 cE) = exchange.fillMarketOrder(
            MARKET_ID, IPrediXExchange.Side.BUY_YES, 500_000, amountIn, tk, tk, 0, _dl(), bytes32(0)
        );
        assertEq(fP, fE, "filled parity");
        assertEq(cP, cE, "cost parity (fee-inclusive)");
        assertEq(cP, 50e6 + 1_750_000, "notional + F");
        assertEq(exchange.accruedProtocolFee(), protoP, "previewProtocolFee == accrued F");
        assertEq(tkBefore - _usdcBalance(tk), cE, "taker spent exactly cost");
    }

    // BUY, budget BINDING (marginal clamp engages in BOTH preview + execute): cost parity still holds.
    function test_previewBuy_clampBinding_costParity() public {
        diamond.setProtocolFee(MARKET_ID, 700, 0);
        _placeSellYes(mk, 500_000, 1e8);
        uint256 amountIn = 30e6; // < full 51.75 → clamp engages
        (uint256 fP, uint256 cP) =
            exchange.previewFillMarketOrder(MARKET_ID, IPrediXExchange.Side.BUY_YES, 500_000, amountIn, 0, tk);
        _giveUsdc(tk, amountIn);
        vm.prank(tk);
        (uint256 fE, uint256 cE) = exchange.fillMarketOrder(
            MARKET_ID, IPrediXExchange.Side.BUY_YES, 500_000, amountIn, tk, tk, 0, _dl(), bytes32(0)
        );
        assertEq(fP, fE, "clamped filled parity");
        assertEq(cP, cE, "clamped cost parity");
        assertLe(cP, amountIn, "clamp keeps cost within budget");
    }

    // SELL: preview filled (gross USDC) + cost (shares) parity; previewProtocolFee == accrued F (per-fill skim).
    function test_previewSell_protocolFeeParity() public {
        diamond.setProtocolFee(MARKET_ID, 700, 0);
        // mk's BUY placement prefunds deposit(50) + reserve(1.75) under coef 700 → fund extra.
        _giveUsdc(mk, 100e6);
        vm.prank(mk);
        exchange.placeOrder(MARKET_ID, IPrediXExchange.Side.BUY_YES, 500_000, 1e8, bytes32(0));
        uint256 shares = 1e8;
        (uint256 fP, uint256 cP) =
            exchange.previewFillMarketOrder(MARKET_ID, IPrediXExchange.Side.SELL_YES, 1, shares, 0, tk);
        uint256 protoP = exchange.previewProtocolFee(MARKET_ID, IPrediXExchange.Side.SELL_YES, 1, shares, 0, tk);
        _giveYesNo(tk, shares);
        vm.prank(tk);
        (uint256 fE, uint256 cE) =
            exchange.fillMarketOrder(MARKET_ID, IPrediXExchange.Side.SELL_YES, 1, shares, tk, tk, 0, _dl(), bytes32(0));
        assertEq(fP, fE, "filled (gross USDC) parity");
        assertEq(cP, cE, "cost (shares) parity");
        assertEq(protoP, 1_750_000, "F = curve(1e8,700,0.5)");
        assertEq(exchange.accruedProtocolFee(), protoP, "previewProtocolFee == accrued F");
    }

    function test_previewP10_feeOff_unchanged() public {
        _placeSellYes(mk, 500_000, 1e8); // coef 0
        (uint256 fP, uint256 cP) =
            exchange.previewFillMarketOrder(MARKET_ID, IPrediXExchange.Side.BUY_YES, 500_000, 60e6, 0, tk);
        uint256 protoP = exchange.previewProtocolFee(MARKET_ID, IPrediXExchange.Side.BUY_YES, 500_000, 60e6, 0, tk);
        assertEq(protoP, 0, "no protocol fee when coef 0");
        assertEq(fP, 1e8, "full fill");
        assertEq(cP, 50e6, "cost = notional only (P10)");
    }
}
