// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {RouterFixture} from "../utils/RouterFixture.sol";
import {IPrediXExchangeView} from "@predix/router/interfaces/IPrediXExchangeView.sol";

/// @dev Phase 5 restores the fee-adjusted AMM spot cap path now that the hook
///      exposes `commitSwapIdentityFor`. The router pre-commits the quoter's
///      identity before each quoter call, so V4Quoter's simulate-and-revert
///      frame passes the hook's FINAL-H06 commit gate. These tests assert the
///      original behavior: CLOB limit derived from the mock quoter's price.
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
    // BUY_YES — CLOB ask $0.95, AMM spot buy $0.40 → cap = $0.40
    // -----------------------------------------------------------------

    function test_BuyYes_PrefersAmm_WhenClobIsExpensive() public {
        uint256 usdcIn = 100e6;
        bool zfoBuy = address(usdc) < address(yes1);
        quoter.setExactInResult(zfoBuy, 2_500_000);
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
    // SELL_YES — AMM sell spot $0.60, CLOB bid $0.30 → min = $0.60
    // -----------------------------------------------------------------

    function test_SellYes_PrefersAmm_WhenClobBidIsLow() public {
        uint256 yesIn = 100e6;
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
        bool zfoBuyYes = address(usdc) < address(yes1);
        bool zfoSellYes = !zfoBuyYes;
        // NEW-M7: 3 sell-dir calls per buyNo (clobBuyNoLimit spot + compute
        // Pass 1 spot + compute Pass 2 proceeds). Buy direction stays
        // single-shot — used only by `_clobBuyYesLimit` here.
        uint256[] memory sellSequence = new uint256[](3);
        sellSequence[0] = 500_000;
        sellSequence[1] = 500_000;
        sellSequence[2] = 40_000_000;
        quoter.setExactInSequence(zfoSellYes, sellSequence);
        quoter.setExactInResult(zfoBuyYes, 2_000_000);

        uint256 expectedMint = (((usdcIn * 1e6) / 500_000) * 9900) / 10_000;
        uint256 proceeds = expectedMint / 2;
        if (zfoSellYes) {
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
        bool zfoBuyYes = address(usdc) < address(yes1);
        quoter.setExactInResult(zfoBuyYes, 2_000_000);

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
