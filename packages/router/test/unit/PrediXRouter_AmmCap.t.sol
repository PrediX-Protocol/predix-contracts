// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {RouterFixture} from "../utils/RouterFixture.sol";
import {IPrediXExchangeView} from "@predix/router/interfaces/IPrediXExchangeView.sol";

/// @dev Proves that the router's CLOB cap is derived from the fee-adjusted AMM spot price,
///      so a CLOB quote that is worse than the live AMM mid is rejected by the exchange
///      (which never fills above a `BUY` cap or below a `SELL` min) and the router falls
///      through to the AMM leg for the full remainder.
contract PrediXRouter_AmmCap is RouterFixture {
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

    // -----------------------------------------------------------------
    // BUY_YES — CLOB ask $0.95, AMM spot buy $0.40 → cap = $0.40 forwarded
    // -----------------------------------------------------------------

    function test_BuyYes_PrefersAmm_WhenClobIsExpensive() public {
        uint256 usdcIn = 100e6;
        // AMM spot-buy quote: 1 USDC → 2.5 YES → price 0.40.
        bool zfoBuy = address(usdc) < address(yes1);
        quoter.setExactInResult(zfoBuy, 2_500_000);
        // AMM real swap for the full USDC (CLOB got nothing because cap too low): 100 → 250 YES.
        if (zfoBuy) {
            poolManager.queueSwapResult(-int128(int256(usdcIn)), int128(250e6));
        } else {
            poolManager.queueSwapResult(int128(250e6), -int128(int256(usdcIn)));
        }

        _approveUsdcAsAlice(usdcIn);
        vm.prank(alice);
        (uint256 yesOut, uint256 clobFilled, uint256 ammFilled) =
            router.buyYes(MARKET_ID, usdcIn, 0, alice, 5, _deadline());
        assertEq(clobFilled, 0, "CLOB rejected above cap");
        assertEq(ammFilled, 250e6, "AMM filled full budget");
        assertEq(yesOut, 250e6);
        assertEq(exchange.lastLimitPrice(), 400_000, "cap = AMM buy spot 0.40");
    }

    // -----------------------------------------------------------------
    // SELL_YES — AMM sell spot $0.60, CLOB bid $0.30 → min = $0.60 forwarded
    // -----------------------------------------------------------------

    function test_SellYes_PrefersAmm_WhenClobBidIsLow() public {
        uint256 yesIn = 100e6;
        // AMM spot-sell quote: 1 YES → 0.60 USDC → min = 0.60.
        bool zfoSell = address(yes1) < address(usdc);
        quoter.setExactInResult(zfoSell, 600_000);
        if (zfoSell) {
            poolManager.queueSwapResult(-int128(int256(yesIn)), int128(60e6));
        } else {
            poolManager.queueSwapResult(int128(60e6), -int128(int256(yesIn)));
        }

        _approveYesAsAlice(yesIn);
        vm.prank(alice);
        (uint256 usdcOut, uint256 clobFilled, uint256 ammFilled) =
            router.sellYes(MARKET_ID, yesIn, 0, alice, 5, _deadline());
        assertEq(clobFilled, 0);
        assertEq(ammFilled, 60e6);
        assertEq(usdcOut, 60e6);
        assertEq(exchange.lastLimitPrice(), 600_000, "min = AMM sell spot 0.60");
    }

    // -----------------------------------------------------------------
    // BUY_NO — virtual NO price = 1 - yesSellSpot
    // -----------------------------------------------------------------

    function test_BuyNo_PrefersAmm_WhenClobIsExpensive() public {
        uint256 usdcIn = 40e6;
        // AMM sell-YES spot: 1 YES → 0.50 USDC → yesSellSpot = 0.50 → virtual NO = 0.50.
        // Also set the buy-direction quote for mintAmount derivation (same 0.50 price).
        bool zfoBuyYes = address(usdc) < address(yes1);
        bool zfoSellYes = !zfoBuyYes;
        quoter.setExactInResult(zfoSellYes, 500_000); // yes → usdc
        quoter.setExactInResult(zfoBuyYes, 2_000_000); // usdc → yes @ price 0.5

        // Virtual buyNo path: mintAmount = usdcIn/noPriceSpot * margin.
        uint256 expectedMint = (((usdcIn * 1e6) / 500_000) * 9700) / 10_000;
        uint256 proceeds = expectedMint / 2;
        if (zfoSellYes) {
            // selling YES → currency0=yes (no wait, depends). Simpler: follow existing buyNo test pattern.
            poolManager.queueSwapResult(-int128(uint128(expectedMint)), int128(uint128(proceeds)));
        } else {
            poolManager.queueSwapResult(int128(uint128(proceeds)), -int128(uint128(expectedMint)));
        }

        _approveUsdcAsAlice(usdcIn);
        vm.prank(alice);
        router.buyNo(MARKET_ID, usdcIn, 0, alice, 5, _deadline());
        assertEq(exchange.lastLimitPrice(), 500_000, "cap = 1 - yesSellSpot = 0.50");
    }

    // -----------------------------------------------------------------
    // SELL_NO — virtual NO sell price = 1 - yesBuySpot
    // -----------------------------------------------------------------

    function test_SellNo_PrefersAmm_WhenClobBidIsLow() public {
        uint256 noIn = 100e6;
        // AMM buy-YES spot: 1 USDC → 2 YES → yesBuySpot = 0.50 → virtual NO sell min = 0.50.
        bool zfoBuyYes = address(usdc) < address(yes1);
        quoter.setExactInResult(zfoBuyYes, 2_000_000);

        // exact-out quote for the flash-buy: cost = 50 USDC for 100 YES.
        quoter.setExactOutResult(50e6);
        if (zfoBuyYes) {
            poolManager.queueSwapResult(-int128(50e6), int128(int256(noIn)));
        } else {
            poolManager.queueSwapResult(int128(int256(noIn)), -int128(50e6));
        }

        _approveNoAsAlice(noIn);
        vm.prank(alice);
        router.sellNo(MARKET_ID, noIn, 0, alice, 5, _deadline());
        assertEq(exchange.lastLimitPrice(), 500_000, "min = 1 - yesBuySpot = 0.50");
    }
}
