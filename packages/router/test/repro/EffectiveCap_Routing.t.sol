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

    /// @dev Impact pool, no CLOB: $100 buys only 230 YES (vs 250 linear at
    ///      $0.40 spot). Effective = 100e6 × 1e6 / 230e6 = 434_782 (~$0.4348).
    ///      With no CLOB the convergence gate (gateCost == 0) returns the
    ///      Level-1 cap directly, so this isolates the effective-at-trade-size
    ///      derivation: the cap reflects the impact-aware effective price, not
    ///      the $1 spot probe. The over-take convergence path is exercised
    ///      separately in `test_BuyYes_Convergence_ClobBookSplit`.
    function test_BuyYes_Cap_UsesEffectiveNotSpot() public {
        uint256 usdcIn = 100e6;
        bool zfoBuy = address(usdc) < address(yes1);
        // Single cap quote at usdcIn=100e6 → 230e6 YES (impact-reduced).
        uint256[] memory seq = new uint256[](1);
        seq[0] = 230_000_000;
        quoter.setExactInSequence(zfoBuy, seq);

        // No CLOB → AMM takes the whole budget (100 USDC → 230 YES).
        if (zfoBuy) {
            poolManager.queueSwapResult(-int128(int256(usdcIn)), int128(230e6));
        } else {
            poolManager.queueSwapResult(int128(230e6), -int128(int256(usdcIn)));
        }

        _approveUsdcAsAlice(usdcIn);
        vm.prank(alice);
        (uint256 yesOut, uint256 clobFilled, uint256 ammFilled) =
            router.buyYes(MARKET_ID, usdcIn, 0, alice, 5, _deadline());

        assertEq(clobFilled, 0, "no CLOB");
        assertEq(ammFilled, 230e6, "AMM filled budget");
        assertEq(yesOut, 230e6);
        // Cap = effective at $100 = 434_782, not the $0.40 spot.
        assertEq(exchange.lastLimitPrice(), 434_782, "cap = effective at trade size, not $0.40 spot");
    }

    /// @dev Level-2 convergence end-to-end on a CLOB+AMM split using the mock
    ///      order book. CLOB has two ask tranches ($0.40 and $0.48); the AMM
    ///      effective at $1 (no-impact scaling mock) is $0.50. The gate detects
    ///      the split and runs the convergence loop; with a no-impact pool the
    ///      converged cap equals the effective ($0.50), so both tranches fill
    ///      from CLOB and the budget is consumed. Verifies the gate +
    ///      convergence path executes and routes correctly without reverting.
    function test_BuyYes_Convergence_ClobBookSplit() public {
        uint256 usdcIn = 100e6;
        bool zfoBuy = address(usdc) < address(yes1);
        quoter.setExactInResult(zfoBuy, 2_000_000); // $0.50 spot (2 YES per $1)

        // SELL_YES asks: 100 YES @ $0.40, deep 200 YES @ $0.48 (both ≤ $0.50 cap).
        uint256[] memory prices = new uint256[](2);
        uint256[] memory shares = new uint256[](2);
        prices[0] = 400_000;
        shares[0] = 100e6;
        prices[1] = 480_000;
        shares[1] = 200e6;
        exchange.setBook(MARKET_ID, IPrediXExchangeView.Side.BUY_YES, prices, shares);
        usdc.mint(address(exchange), 1_000e6);

        _approveUsdcAsAlice(usdcIn);
        vm.prank(alice);
        (uint256 yesOut, uint256 clobFilled, uint256 ammFilled) =
            router.buyYes(MARKET_ID, usdcIn, 0, alice, 10, _deadline());

        // $40 → 100 YES @ $0.40; remaining $60 → 125 YES @ $0.48. Cap = $0.50
        // so both tranches eligible and the budget is fully consumed by CLOB
        // (225 YES for $100). The converged cap did NOT wrongly exclude the
        // $0.48 tranche (a spot-only cap below $0.48 would have), so the taker
        // captured the cheaper-than-AMM orderbook depth.
        assertEq(clobFilled, 225e6, "both CLOB tranches captured under converged cap");
        assertEq(ammFilled, 0, "budget fully filled by CLOB");
        assertEq(yesOut, 225e6);
    }

    /// @dev The core Level-2 win: convergence EXCLUDES a marginal CLOB order
    ///      that the Level-1 (full-size) cap would over-take, routing the tail
    ///      to a cheaper AMM remainder. Impact pool — effective rises with size:
    ///        effective($100) = $0.55,  effective($60) = $0.52,  spot = $0.50.
    ///      Book: 100 YES @ $0.40 (cheap) + 500 YES @ $0.54 (marginal, big).
    ///      Level-1 cap $0.55 admits the $0.54 order → CLOB absorbs the whole
    ///      $100. Convergence walks the cap up from spot and settles at $0.52
    ///      (= effective at the $60 left after the $0.40 fill); the $0.54 order
    ///      is now above-cap and excluded, so $60 routes to the AMM at $0.52 —
    ///      cheaper than the $0.54 CLOB tail.
    function test_BuyYes_Convergence_ExcludesMarginalOrder() public {
        uint256 usdcIn = 100e6;
        bool zfoBuy = address(usdc) < address(yes1);
        // Impact quote sequence consumed in convergence order:
        //   [0] cap at $100  → 181_818_181 YES  (effective $0.55)
        //   [1] seed at MIN  → 2000 YES         (effective $0.50 spot)
        //   [2] re-quote $60 → 115_384_615 YES  (effective $0.52)
        //   [3] re-quote $60 → 115_384_615 YES  (converged, breaks)
        uint256[] memory q = new uint256[](4);
        q[0] = 181_818_181;
        q[1] = 2000;
        q[2] = 115_384_615;
        q[3] = 115_384_615;
        quoter.setExactInSequence(zfoBuy, q);

        uint256[] memory prices = new uint256[](2);
        uint256[] memory shares = new uint256[](2);
        prices[0] = 400_000;
        shares[0] = 100e6; // cheap
        prices[1] = 540_000;
        shares[1] = 500e6; // marginal, big enough to absorb the whole budget
        exchange.setBook(MARKET_ID, IPrediXExchangeView.Side.BUY_YES, prices, shares);
        usdc.mint(address(exchange), 1_000e6);

        // AMM leg: $60 USDC → 115.38e6 YES at effective $0.52.
        if (zfoBuy) {
            poolManager.queueSwapResult(-int128(int256(60e6)), int128(115_384_615));
        } else {
            poolManager.queueSwapResult(int128(115_384_615), -int128(int256(60e6)));
        }

        _approveUsdcAsAlice(usdcIn);
        vm.prank(alice);
        (uint256 yesOut, uint256 clobFilled, uint256 ammFilled) =
            router.buyYes(MARKET_ID, usdcIn, 0, alice, 10, _deadline());

        // Converged cap $0.52 excludes the $0.54 order: CLOB delivers only the
        // 100 YES @ $0.40; the $60 tail goes to the AMM (115.38e6 YES) instead
        // of the more-expensive $0.54 CLOB depth. Level-1 would have taken the
        // $0.54 order and delivered less YES overall.
        assertEq(clobFilled, 100e6, "only the cheap CLOB order taken");
        assertEq(ammFilled, 115_384_615, "marginal tail routed to cheaper AMM");
        assertEq(yesOut, 215_384_615);
        assertEq(exchange.lastLimitPrice(), 520_000, "converged cap = effective at remainder");
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

    /// @dev Impact pool, no CLOB: selling 100 YES yields only 55e6 USDC (vs
    ///      60e6 linear at $0.60 spot). Effective = 55e6 × 1e6 / 100e6 =
    ///      550_000. With no CLOB the gate returns the Level-1 cap, isolating
    ///      the effective-sell-at-size derivation: the min reflects the
    ///      impact-aware effective, not the $0.60 spot.
    function test_SellYes_Cap_UsesEffectiveNotSpot() public {
        uint256 yesIn = 100e6;
        bool zfoSell = address(yes1) < address(usdc);
        uint256[] memory seq = new uint256[](1);
        seq[0] = 55_000_000; // impact-reduced USDC out at 100 YES
        quoter.setExactInSequence(zfoSell, seq);

        // No CLOB → AMM takes the whole 100 YES for 55 USDC.
        if (zfoSell) {
            poolManager.queueSwapResult(-int128(int256(yesIn)), int128(55e6));
        } else {
            poolManager.queueSwapResult(int128(55e6), -int128(int256(yesIn)));
        }

        _approveYesAsAlice(yesIn);
        vm.prank(alice);
        (uint256 usdcOut, uint256 clobFilled, uint256 ammFilled) =
            router.sellYes(MARKET_ID, yesIn, 0, alice, 5, _deadline());

        assertEq(clobFilled, 0, "no CLOB");
        assertEq(ammFilled, 55e6, "AMM filled");
        assertEq(usdcOut, 55e6);
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
        quoter.setExactOutResult(520_000); // rate $0.52/YES → exact-out at 100e6 = 52e6

        // CLOB takes 50e6 NO (cost) for 40e6 USDC; 50e6 NO routes to the AMM leg.
        exchange.setResult(MARKET_ID, IPrediXExchangeView.Side.SELL_NO, 40e6, 50e6);
        usdc.mint(address(exchange), 1_000e6);

        // AMM leg flash-buys the 50e6 NO remainder's YES exact-out. Cost at
        // rate $0.52 = 26e6 USDC; pool delivers 50e6 YES for 26e6 USDC.
        uint256 noRemainder = 50e6;
        uint256 ammCost = (noRemainder * 520_000) / 1e6; // 26e6
        if (address(usdc) < address(yes1)) {
            poolManager.queueSwapResult(-int128(uint128(ammCost)), int128(uint128(noRemainder)));
        } else {
            poolManager.queueSwapResult(int128(uint128(noRemainder)), -int128(uint128(ammCost)));
        }

        _approveNoAsAlice(noIn);
        vm.prank(alice);
        router.sellNo(MARKET_ID, noIn, 0, alice, 5, _deadline());

        assertEq(exchange.lastLimitPrice(), 480_000, "min = 1 - effective yes-buy = 0.48");
    }
}
