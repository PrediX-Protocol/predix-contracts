// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {RouterFixture} from "../utils/RouterFixture.sol";
import {IPrediXExchangeView} from "@predix/router/interfaces/IPrediXExchangeView.sol";

/// @dev Phase 4 Part 1 narrow fix regression guard. The router used to ask the
///      V4Quoter for an AMM spot price and forward it to the exchange as a CLOB
///      limit cap (BUY) or minimum (SELL). That path is known broken against the
///      deployed `PrediXHookV2` because the quoter's simulate-and-revert pattern
///      triggers `hook.beforeSwap` with `sender = quoter` and the FINAL-H06
///      commit gate has no pre-committed identity under `(quoter, poolId)`.
///
///      Phase 4 Part 1 removes the quoter probe from the two spot-price helpers
///      entirely, degrading the four `_clob*Limit` helpers to constants:
///
///        * `_clobBuyYesLimit` → `PRICE_PRECISION` (= 1_000_000) — permissive cap
///        * `_clobSellYesLimit` → `0` — permissive min
///        * `_clobBuyNoLimit` → `PRICE_PRECISION` — permissive cap
///        * `_clobSellNoLimit` → `0` — permissive min
///
///      These tests assert those constants are forwarded to the exchange on each
///      entry point. Phase 5 (backlog #49) will restore the fee-adjusted spot
///      cap once the hook exposes `commitSwapIdentityFor`.
contract PrediXRouter_AmmCap is RouterFixture {
    uint256 internal constant PRICE_PRECISION = 1e6;

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
    // BUY_YES — permissive cap = PRICE_PRECISION (1.00)
    // -----------------------------------------------------------------

    function test_BuyYes_PermissiveCap_ForwardsPriceUnit() public {
        uint256 usdcIn = 100e6;
        // AMM real swap for the full USDC (CLOB mock is a no-op, so everything spills to AMM).
        bool zfoBuy = address(usdc) < address(yes1);
        if (zfoBuy) {
            poolManager.queueSwapResult(-int128(int256(usdcIn)), int128(250e6));
        } else {
            poolManager.queueSwapResult(int128(250e6), -int128(int256(usdcIn)));
        }

        _approveUsdcAsAlice(usdcIn);
        vm.prank(alice);
        (uint256 yesOut, uint256 clobFilled, uint256 ammFilled) =
            router.buyYes(MARKET_ID, usdcIn, 0, alice, 5, _deadline());
        assertEq(clobFilled, 0, "CLOB mock returns zero fill");
        assertEq(ammFilled, 250e6, "AMM filled full budget");
        assertEq(yesOut, 250e6);
        assertEq(exchange.lastLimitPrice(), PRICE_PRECISION, "cap = PRICE_PRECISION (permissive)");
    }

    // -----------------------------------------------------------------
    // SELL_YES — permissive min = 0
    // -----------------------------------------------------------------

    function test_SellYes_PermissiveMin_ForwardsZero() public {
        uint256 yesIn = 100e6;
        bool zfoSell = address(yes1) < address(usdc);
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
        assertEq(exchange.lastLimitPrice(), 0, "min = 0 (permissive)");
    }

    // -----------------------------------------------------------------
    // BUY_NO — permissive cap = PRICE_PRECISION (1.00)
    // -----------------------------------------------------------------

    function test_BuyNo_PermissiveCap_ForwardsPriceUnit() public {
        uint256 usdcIn = 40e6;
        // `_computeBuyNoMintAmount` is Phase 5-gated — the 4 public quote methods
        // + 2 compute helpers still call the quoter, so this test exercises only
        // the CLOB-cap forwarding path. Use a mock quoter response for the mint
        // sizing so the test isolates the cap assertion.
        bool zfoBuyYes = address(usdc) < address(yes1);
        quoter.setExactInResult(zfoBuyYes, 2_000_000); // usdc → yes @ price 0.5

        uint256 expectedMint = (((usdcIn * 1e6) / 500_000) * 9700) / 10_000;
        uint256 proceeds = expectedMint / 2;
        if (zfoBuyYes) {
            poolManager.queueSwapResult(int128(uint128(proceeds)), -int128(uint128(expectedMint)));
        } else {
            poolManager.queueSwapResult(-int128(uint128(expectedMint)), int128(uint128(proceeds)));
        }

        _approveUsdcAsAlice(usdcIn);
        vm.prank(alice);
        router.buyNo(MARKET_ID, usdcIn, 0, alice, 5, _deadline());
        assertEq(exchange.lastLimitPrice(), PRICE_PRECISION, "cap = PRICE_PRECISION (permissive)");
    }

    // -----------------------------------------------------------------
    // SELL_NO — permissive min = 0
    // -----------------------------------------------------------------

    function test_SellNo_PermissiveMin_ForwardsZero() public {
        uint256 noIn = 100e6;
        // exact-out quote for the flash-buy — still Phase 5-gated in real use,
        // but the mock lets this test isolate the cap forwarding.
        quoter.setExactOutResult(50e6);
        bool zfoBuyYes = address(usdc) < address(yes1);
        if (zfoBuyYes) {
            poolManager.queueSwapResult(-int128(50e6), int128(int256(noIn)));
        } else {
            poolManager.queueSwapResult(int128(int256(noIn)), -int128(50e6));
        }

        _approveNoAsAlice(noIn);
        vm.prank(alice);
        router.sellNo(MARKET_ID, noIn, 0, alice, 5, _deadline());
        assertEq(exchange.lastLimitPrice(), 0, "min = 0 (permissive)");
    }
}
