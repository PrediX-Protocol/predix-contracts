// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {IPrediXExchange} from "../../src/IPrediXExchange.sol";

import {ExchangeTestBase} from "../base/ExchangeTestBase.sol";

/// @notice Fix-lock: MakerPath MINT gives price improvement to taker
///         (the placer), not feeRecipient. Mirrors COMPLEMENTARY
///         (_refundPriceImprovement) and MERGE (taker-gets-complement).
contract Audit_MintPriceImprovement is ExchangeTestBase {
    /// @dev Core test: taker gets price improvement, feeRecipient gets nothing.
    function test_MintPriceImprovement_TakerGetsRefund() public {
        _placeBuyNo(bob, 360_000, 100 * ONE_SHARE);

        _giveUsdc(alice, (100 * ONE_SHARE * 650_000) / 1e6);

        uint256 feeBefore = usdc.balanceOf(feeRecipient);

        vm.prank(alice);
        (, uint256 filled) = exchange.placeOrder(MARKET_ID, IPrediXExchange.Side.BUY_YES, 650_000, 100 * ONE_SHARE);

        assertEq(filled, 100 * ONE_SHARE, "fully filled via MINT");

        // Alice deposited 65 USDC, effective cost = 64 USDC (complement of $0.36).
        // Improvement = 1 USDC returned to alice.
        uint256 aliceFinalUsdc = usdc.balanceOf(alice);
        uint256 makerUsdc = (100 * ONE_SHARE * 360_000) / 1e6; // 36 USDC
        uint256 expectedImprovement = (100 * ONE_SHARE * 650_000) / 1e6 - (100 * ONE_SHARE - makerUsdc);
        assertEq(aliceFinalUsdc, expectedImprovement, "taker receives improvement");

        // feeRecipient gets ZERO from the MINT match.
        assertEq(usdc.balanceOf(feeRecipient) - feeBefore, 0, "no surplus to feeRecipient");
    }

    /// @dev Exact-match prices ($0.65 + $0.35 = $1.00) -> zero improvement.
    function test_MintExactMatch_ZeroImprovement() public {
        _placeBuyNo(bob, 350_000, 50 * ONE_SHARE);

        _giveUsdc(alice, (50 * ONE_SHARE * 650_000) / 1e6);

        vm.prank(alice);
        exchange.placeOrder(MARKET_ID, IPrediXExchange.Side.BUY_YES, 650_000, 50 * ONE_SHARE);

        // $0.65 + $0.35 = $1.00 exact. No improvement.
        assertEq(usdc.balanceOf(alice), 0, "no improvement on exact match");
    }

    /// @dev Large price gap -> large improvement.
    function test_MintLargeGap_LargeImprovement() public {
        // Bob BUY_NO at $0.10. Alice BUY_YES at $0.99.
        // Effective taker price = $0.90. Improvement = $0.09 per share.
        _placeBuyNo(bob, 100_000, 200 * ONE_SHARE);

        _giveUsdc(alice, (200 * ONE_SHARE * 990_000) / 1e6);
        uint256 feeBefore = usdc.balanceOf(feeRecipient);

        vm.prank(alice);
        exchange.placeOrder(MARKET_ID, IPrediXExchange.Side.BUY_YES, 990_000, 200 * ONE_SHARE);

        uint256 makerUsdc = (200 * ONE_SHARE * 100_000) / 1e6; // 20 USDC
        uint256 takerDeposit = (200 * ONE_SHARE * 990_000) / 1e6; // 198 USDC
        uint256 takerEffective = 200 * ONE_SHARE - makerUsdc; // 180 USDC
        uint256 expectedImprovement = takerDeposit - takerEffective; // 18 USDC

        assertEq(usdc.balanceOf(alice), expectedImprovement, "large improvement refunded");
        assertEq(usdc.balanceOf(feeRecipient) - feeBefore, 0, "feeRecipient gets zero");
    }

    /// @dev Consistency: MINT improvement matches COMPLEMENTARY improvement.
    function test_MintVsComplementary_ConsistentImprovement() public {
        // Scenario A: COMPLEMENTARY.
        // Carol SELL_YES at $0.60. Dave BUY_YES at $0.65.
        // Improvement = $0.05 per share.
        _placeSellYes(carol, 600_000, 10 * ONE_SHARE);
        _giveUsdc(dave, (10 * ONE_SHARE * 650_000) / 1e6);
        vm.prank(dave);
        exchange.placeOrder(MARKET_ID, IPrediXExchange.Side.BUY_YES, 650_000, 10 * ONE_SHARE);
        uint256 compImprovement = usdc.balanceOf(dave);

        // Scenario B: MINT at equivalent effective price.
        // Bob BUY_NO at $0.40. Alice BUY_YES at $0.65.
        // Effective = $0.60 (complement of $0.40). Improvement = $0.05.
        _placeBuyNo(bob, 400_000, 10 * ONE_SHARE);
        _giveUsdc(alice, (10 * ONE_SHARE * 650_000) / 1e6);
        vm.prank(alice);
        exchange.placeOrder(MARKET_ID, IPrediXExchange.Side.BUY_YES, 650_000, 10 * ONE_SHARE);
        uint256 mintImprovement = usdc.balanceOf(alice);

        assertEq(mintImprovement, compImprovement, "MINT and COMPLEMENTARY give same improvement");
    }
}
