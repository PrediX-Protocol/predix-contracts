// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import {IPrediXExchangeView} from "@predix/router/interfaces/IPrediXExchangeView.sol";

import {RouterFixture} from "../utils/RouterFixture.sol";

/// @title EffectiveCap_Routing
/// @notice Pins the effective-price CLOB cap optimization. The router sizes the
///         CLOB limit price at the AMM's *effective* price for the actual trade
///         size, not the $1 spot. In a pool with price impact this widens the
///         cap from spot toward effective, letting the orderbook fill resting
///         orders priced between the two — strictly preserved profit for the
///         taker, because the AMM would have charged at least the effective
///         price for the same units.
///
///         The unit mock exchange records `lastLimitPrice` but does not filter
///         fills on it, so these tests assert the cap *derivation* changed.
///         The end-to-end "more CLOB fill" behavior against a real orderbook is
///         covered by the diamond integration suite.
contract EffectiveCap_Routing is RouterFixture {
    function _approveUsdcAsAlice(uint256 amount) internal {
        vm.prank(alice);
        usdc.approve(address(router), amount);
    }

    function _approveYesAsAlice(uint256 amount) internal {
        vm.prank(alice);
        yes1.approve(address(router), amount);
    }

    function _approveNoAsAlice(uint256 amount) internal {
        vm.prank(alice);
        no1.approve(address(router), amount);
    }

    // ================================================================
    // BUY_YES — cap = effective at usdcIn, not $1 spot
    // ================================================================

    /// @dev Impact pool: $100 buys only 230 YES (vs 250 linear no-impact at
    ///      $0.40 spot). Effective = 100e6 × 1e6 / 230e6 = 434_782 (~$0.4348).
    ///      Old spot cap would have been 400_000; the effective cap is wider,
    ///      so CLOB orders priced in (0.40, 0.4348] are now routable.
    function test_BuyYes_Cap_UsesEffectiveNotSpot() public {
        uint256 usdcIn = 100e6;
        bool zfoBuy = address(usdc) < address(yes1);
        // Sequence: [cap quote at usdcIn=100e6 → 230e6 YES (impact)].
        uint256[] memory seq = new uint256[](1);
        seq[0] = 230_000_000; // impact-reduced YES out at $100
        quoter.setExactInSequence(zfoBuy, seq);

        // CLOB consumes the whole budget so no AMM leg is needed.
        exchange.setResult(MARKET_ID, IPrediXExchangeView.Side.BUY_YES, 230e6, usdcIn);

        _approveUsdcAsAlice(usdcIn);
        vm.prank(alice);
        router.buyYes(MARKET_ID, usdcIn, 0, alice, 5, _deadline());

        // Effective cap = 100e6 * 1e6 / 230e6 = 434_782.
        assertEq(exchange.lastLimitPrice(), 434_782, "cap = effective at trade size, not $0.40 spot");
    }

    /// @dev Deep pool (no impact) reduces to the spot value: cap == spot,
    ///      proving the change is a strict generalization, not a regression
    ///      for well-funded pools.
    function test_BuyYes_Cap_DeepPool_EqualsSpot() public {
        uint256 usdcIn = 100e6;
        bool zfoBuy = address(usdc) < address(yes1);
        // Scaling mock canned: 2.5 YES per $1 → no-impact $0.40 spot.
        quoter.setExactInResult(zfoBuy, 2_500_000);

        exchange.setResult(MARKET_ID, IPrediXExchangeView.Side.BUY_YES, 250e6, usdcIn);

        _approveUsdcAsAlice(usdcIn);
        vm.prank(alice);
        router.buyYes(MARKET_ID, usdcIn, 0, alice, 5, _deadline());

        // No-impact: effective == spot == $0.40.
        assertEq(exchange.lastLimitPrice(), 400_000, "deep-pool cap collapses to spot");
    }

    // ================================================================
    // SELL_YES — cap = effective sell at yesIn (lower than spot under impact)
    // ================================================================

    /// @dev Impact pool: selling 100 YES yields only 55e6 USDC (vs 60e6 linear
    ///      at $0.60 spot). Effective = 55e6 × 1e6 / 100e6 = 550_000. The lower
    ///      (more permissive) min lets the CLOB fill bids in [0.55, 0.60).
    function test_SellYes_Cap_UsesEffectiveNotSpot() public {
        uint256 yesIn = 100e6;
        bool zfoSell = address(yes1) < address(usdc);
        uint256[] memory seq = new uint256[](1);
        seq[0] = 55_000_000; // impact-reduced USDC out at 100 YES
        quoter.setExactInSequence(zfoSell, seq);

        exchange.setResult(MARKET_ID, IPrediXExchangeView.Side.SELL_YES, 55e6, yesIn);

        // Pre-fund mock exchange with USDC to settle the CLOB fill.
        usdc.mint(address(exchange), 1_000e6);

        _approveYesAsAlice(yesIn);
        vm.prank(alice);
        router.sellYes(MARKET_ID, yesIn, 0, alice, 5, _deadline());

        assertEq(exchange.lastLimitPrice(), 550_000, "min = effective sell at size, not $0.60 spot");
    }

    // ================================================================
    // SELL_NO — cap = 1 - effective buy-yes exact-out at noIn
    // ================================================================

    /// @dev Impact pool: flash-buying 100 YES (exact-out) costs 52e6 USDC (vs
    ///      50e6 linear at $0.50). Effective YES buy = 52e6 × 1e6 / 100e6 =
    ///      520_000. NO sell min = 1 - 520_000 = 480_000 (vs old 500_000 spot).
    function test_SellNo_Cap_UsesEffectiveExactOut() public {
        uint256 noIn = 100e6;
        quoter.setExactOutResult(52e6); // exact-out cost to buy 100e6 YES

        exchange.setResult(MARKET_ID, IPrediXExchangeView.Side.SELL_NO, 40e6, 50e6);
        usdc.mint(address(exchange), 1_000e6);

        _approveNoAsAlice(noIn);
        vm.prank(alice);
        router.sellNo(MARKET_ID, noIn, 0, alice, 5, _deadline());

        assertEq(exchange.lastLimitPrice(), 480_000, "min = 1 - effective yes-buy = 0.48");
    }
}
