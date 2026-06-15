// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

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
            router.buyYes(MARKET_ID, usdcIn, 0, alice, 5, _deadline(), bytes32(0));
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
            router.sellYes(MARKET_ID, yesIn, 0, alice, 5, _deadline(), bytes32(0));
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
        // Effective-cap Path D: 5 sell-dir calls per buyNo (clobBuyNoLimit spot
        // probe + clobBuyNoLimit effective at mintEstimate + Pass 1 spot +
        // iter-1 quote + final safety quote). Buy direction stays single-shot.
        uint256[] memory sellSequence = new uint256[](5);
        sellSequence[0] = 500_000; // clobBuyNoLimit spot probe ($1 in)
        sellSequence[1] = 40_000_000; // clobBuyNoLimit effective at 80e6 mintEstimate
        sellSequence[2] = 500_000; // compute Pass 1 spot
        sellSequence[3] = 40_000_000; // iter 1 at 80e6
        sellSequence[4] = 39_800_000; // final safety at 79.6e6 (linear)
        quoter.setExactInSequence(zfoSellYes, sellSequence);
        quoter.setExactInResult(zfoBuyYes, 2_000_000);

        uint256 expectedMint = (((usdcIn * 1e6) / 500_000) * 9950) / 10_000; // cushion 0.5% (Path D)
        uint256 proceeds = expectedMint / 2;
        if (zfoSellYes) {
            poolManager.queueSwapResult(-int128(uint128(expectedMint)), int128(uint128(proceeds)));
        } else {
            poolManager.queueSwapResult(int128(uint128(proceeds)), -int128(uint128(expectedMint)));
        }

        _approveUsdcAsAlice(usdcIn);
        vm.prank(alice);
        router.buyNo(MARKET_ID, usdcIn, 0, alice, 5, _deadline(), bytes32(0));
        assertEq(exchange.lastLimitPrice(), 500_000, "cap = 1 - yesSellEffective = 0.50");
    }

    // -----------------------------------------------------------------
    // SELL_NO — virtual NO sell price = 1 - yesBuySpot
    // -----------------------------------------------------------------

    function test_SellNo_PrefersAmm_WhenClobBidIsLow() public {
        uint256 noIn = 100e6;
        bool zfoBuyYes = address(usdc) < address(yes1);
        quoter.setExactInResult(zfoBuyYes, 2_000_000);

        quoter.setExactOutResult(500_000); // rate $0.50/YES → exact-out at 100e6 = 50e6
        if (zfoBuyYes) {
            poolManager.queueSwapResult(-int128(50e6), int128(int256(noIn)));
        } else {
            poolManager.queueSwapResult(int128(int256(noIn)), -int128(50e6));
        }

        _approveNoAsAlice(noIn);
        vm.prank(alice);
        router.sellNo(MARKET_ID, noIn, 0, alice, 5, _deadline(), bytes32(0));
        assertEq(exchange.lastLimitPrice(), 500_000, "min = 1 - yesBuySpot = 0.50");
    }
}
