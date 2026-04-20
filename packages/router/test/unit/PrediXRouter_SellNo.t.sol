// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {RouterFixture} from "../utils/RouterFixture.sol";
import {IPrediXRouter} from "@predix/router/interfaces/IPrediXRouter.sol";
import {IPrediXExchangeView} from "@predix/router/interfaces/IPrediXExchangeView.sol";

contract PrediXRouter_SellNo is RouterFixture {
    function _approveNoAsAlice(uint256 amount) internal {
        vm.prank(alice);
        no1.approve(address(router), amount);
    }

    function test_HappyPath_ClobOnly() public {
        exchange.setResult(MARKET_ID, IPrediXExchangeView.Side.SELL_NO, 50e6, 100e6);
        _approveNoAsAlice(100e6);
        uint256 aliceUsdcBefore = usdc.balanceOf(alice);
        vm.prank(alice);
        (uint256 usdcOut, uint256 clobFilled, uint256 ammFilled) =
            router.sellNo(MARKET_ID, 100e6, 0, alice, 5, _deadline());
        assertEq(usdcOut, 50e6);
        assertEq(clobFilled, 50e6);
        assertEq(ammFilled, 0);
        assertEq(usdc.balanceOf(alice), aliceUsdcBefore + 50e6);
    }

    function test_VirtualPath_SellNo_AmmOnly_Quoter() public {
        // quoter exact-output: cost to get noIn YES = 50_000_000 (0.5 USDC per YES spot)
        uint256 noIn = 100e6;
        uint256 costQuote = 50e6;
        quoter.setExactOutResult(costQuote);

        // Swap exact-out: pay costQuote USDC, receive noIn YES
        // zeroForOne = usdc < yes1 → buy YES
        if (address(usdc) < address(yes1)) {
            poolManager.queueSwapResult(-int128(uint128(costQuote)), int128(uint128(noIn)));
        } else {
            poolManager.queueSwapResult(int128(uint128(noIn)), -int128(uint128(costQuote)));
        }

        _approveNoAsAlice(noIn);
        vm.prank(alice);
        (uint256 usdcOut,, uint256 ammFilled) = router.sellNo(MARKET_ID, noIn, 0, alice, 5, _deadline());
        assertEq(usdcOut, noIn - costQuote, "usdcOut = noIn - cost");
        assertEq(ammFilled, noIn - costQuote);
        assertEq(hook.commitCount(), 3);
    }

    function test_Revert_SellNo_QuoteOutsideSafetyMargin() public {
        uint256 noIn = 100e6;
        uint256 costQuote = 50e6;
        quoter.setExactOutResult(costQuote);
        // Actual cost far exceeds maxCost = costQuote / 0.97
        uint256 actualCost = 80e6; // > 50e6 / 0.97 ≈ 51.5e6
        if (address(usdc) < address(yes1)) {
            poolManager.queueSwapResult(-int128(uint128(actualCost)), int128(uint128(noIn)));
        } else {
            poolManager.queueSwapResult(int128(uint128(noIn)), -int128(uint128(actualCost)));
        }
        _approveNoAsAlice(noIn);
        vm.prank(alice);
        vm.expectRevert(IPrediXRouter.QuoteOutsideSafetyMargin.selector);
        router.sellNo(MARKET_ID, noIn, 0, alice, 5, _deadline());
    }

    function test_Revert_SellNo_ExactInUnfilled_NoLiquidity() public {
        // Quoter returns a cost ≥ noIn → virtual-NO leg is unprofitable and
        // _executeAmmSellNo returns 0 instead of reverting. With no CLOB fill either,
        // the outer waterfall reports ExactInUnfilled.
        quoter.setExactOutResult(200e6);
        _approveNoAsAlice(100e6);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(IPrediXRouter.ExactInUnfilled.selector, 100e6));
        router.sellNo(MARKET_ID, 100e6, 0, alice, 5, _deadline());
    }

    function test_HappyPath_SellNo_ClobMostly_AmmDustSkipped() public {
        // CLOB consumes 99 of 100 NO, yielding 55 USDC. On the 1 wei NO remainder the
        // quoter returns a cost ≥ noIn → virtual-NO leg skipped. Final fill = CLOB only.
        uint256 noIn = 100e6;
        exchange.setResult(MARKET_ID, IPrediXExchangeView.Side.SELL_NO, 55e6, noIn - 1);
        quoter.setExactOutResult(200e6);

        _approveNoAsAlice(noIn);
        vm.prank(alice);
        (uint256 usdcOut, uint256 clobFilled, uint256 ammFilled) =
            router.sellNo(MARKET_ID, noIn, 0, alice, 5, _deadline());

        assertEq(clobFilled, 55e6, "clobFilled");
        assertEq(ammFilled, 0, "ammFilled dust skipped");
        assertEq(usdcOut, 55e6, "usdcOut = clob only");
        assertEq(usdc.balanceOf(address(router)), 0, "router usdc zero");
        assertEq(no1.balanceOf(address(router)), 0, "router no zero");
    }

    function test_Revert_ZeroAmount() public {
        vm.prank(alice);
        vm.expectRevert(IPrediXRouter.ZeroAmount.selector);
        router.sellNo(MARKET_ID, 0, 0, alice, 5, _deadline());
    }
}
