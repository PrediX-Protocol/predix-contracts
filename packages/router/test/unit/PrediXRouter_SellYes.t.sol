// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {RouterFixture} from "../utils/RouterFixture.sol";
import {IPrediXRouter} from "@predix/router/interfaces/IPrediXRouter.sol";
import {IPrediXExchangeView} from "@predix/router/interfaces/IPrediXExchangeView.sol";
import {Modules} from "@predix/shared/constants/Modules.sol";

contract PrediXRouter_SellYes is RouterFixture {
    function _approveYesAsAlice(uint256 amount) internal {
        vm.prank(alice);
        yes1.approve(address(router), amount);
    }

    function test_HappyPath_ClobOnly() public {
        // Selling 200 YES at 0.5 yields 100 USDC.
        exchange.setResult(MARKET_ID, IPrediXExchangeView.Side.SELL_YES, 100e6, 200e6);
        _approveYesAsAlice(200e6);
        uint256 aliceUsdcBefore = usdc.balanceOf(alice);
        vm.prank(alice);
        (uint256 usdcOut, uint256 clobFilled, uint256 ammFilled) =
            router.sellYes(MARKET_ID, 200e6, 0, alice, 5, _deadline());
        assertEq(usdcOut, 100e6);
        assertEq(clobFilled, 100e6);
        assertEq(ammFilled, 0);
        assertEq(usdc.balanceOf(alice), aliceUsdcBefore + 100e6);
        assertEq(yes1.balanceOf(address(router)), 0);
    }

    function test_HappyPath_AmmOnly() public {
        // 100 YES → 55 USDC at AMM
        if (address(yes1) < address(usdc)) {
            poolManager.queueSwapResult(-int128(100e6), int128(55e6));
        } else {
            poolManager.queueSwapResult(int128(55e6), -int128(100e6));
        }
        _approveYesAsAlice(100e6);
        vm.prank(alice);
        (uint256 usdcOut,, uint256 ammFilled) = router.sellYes(MARKET_ID, 100e6, 0, alice, 5, _deadline());
        assertEq(usdcOut, 55e6);
        assertEq(ammFilled, 55e6);
        assertEq(hook.commitCount(), 2);
        assertEq(hook.lastCommitUser(), alice);
    }

    function test_HappyPath_Split() public {
        // CLOB takes 60 YES → 35 USDC. AMM: 40 YES → 22 USDC.
        exchange.setResult(MARKET_ID, IPrediXExchangeView.Side.SELL_YES, 35e6, 60e6);
        if (address(yes1) < address(usdc)) {
            poolManager.queueSwapResult(-int128(40e6), int128(22e6));
        } else {
            poolManager.queueSwapResult(int128(22e6), -int128(40e6));
        }
        _approveYesAsAlice(100e6);
        vm.prank(alice);
        (uint256 usdcOut, uint256 clobFilled, uint256 ammFilled) =
            router.sellYes(MARKET_ID, 100e6, 0, alice, 5, _deadline());
        assertEq(clobFilled, 35e6);
        assertEq(ammFilled, 22e6);
        assertEq(usdcOut, 57e6);
    }

    function test_HappyPath_ClobNearExact_AmmDustYieldsZero() public {
        // Symmetric to BuyYes dust test: CLOB nearly consumes the YES input, leaving 1 wei
        // YES dust. AMM swap returns 0 USDC because the fee eats the sliver (usdcDelta == 0).
        // Router must accept the AMM dust leg as zero and ship the CLOB USDC proceeds.
        uint256 yesIn = 100e6;
        exchange.setResult(MARKET_ID, IPrediXExchangeView.Side.SELL_YES, 55e6, yesIn - 1);
        if (address(yes1) < address(usdc)) {
            poolManager.queueSwapResult(-int128(1), int128(0));
        } else {
            poolManager.queueSwapResult(int128(0), -int128(1));
        }

        _approveYesAsAlice(yesIn);
        vm.prank(alice);
        (uint256 usdcOut, uint256 clobFilled, uint256 ammFilled) =
            router.sellYes(MARKET_ID, yesIn, 0, alice, 5, _deadline());

        assertEq(clobFilled, 55e6, "clobFilled");
        assertEq(ammFilled, 0, "ammFilled dust zero");
        assertEq(usdcOut, 55e6, "usdcOut = clob only");
        assertEq(usdc.balanceOf(address(router)), 0, "router usdc zero");
        assertEq(yes1.balanceOf(address(router)), 0, "router yes zero");
    }

    function test_HappyPath_RecipientDifferentFromCaller() public {
        exchange.setResult(MARKET_ID, IPrediXExchangeView.Side.SELL_YES, 60e6, 100e6);
        _approveYesAsAlice(100e6);
        uint256 bobBefore = usdc.balanceOf(bob);
        vm.prank(alice);
        router.sellYes(MARKET_ID, 100e6, 0, bob, 5, _deadline());
        assertEq(usdc.balanceOf(bob), bobBefore + 60e6);
    }

    function test_Revert_ZeroAmount() public {
        vm.prank(alice);
        vm.expectRevert(IPrediXRouter.ZeroAmount.selector);
        router.sellYes(MARKET_ID, 0, 0, alice, 5, _deadline());
    }

    function test_Revert_DeadlineExpired() public {
        _approveYesAsAlice(1000);
        uint256 past = block.timestamp - 1;
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(IPrediXRouter.DeadlineExpired.selector, past, block.timestamp));
        router.sellYes(MARKET_ID, 1000, 0, alice, 5, past);
    }

    function test_Revert_InvalidRecipient_Self() public {
        _approveYesAsAlice(1000);
        vm.prank(alice);
        vm.expectRevert(IPrediXRouter.InvalidRecipient.selector);
        router.sellYes(MARKET_ID, 1000, 0, address(router), 5, _deadline());
    }

    function test_Revert_InsufficientOutput() public {
        exchange.setResult(MARKET_ID, IPrediXExchangeView.Side.SELL_YES, 60e6, 100e6);
        _approveYesAsAlice(100e6);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(IPrediXRouter.InsufficientOutput.selector, 60e6, 100e6));
        router.sellYes(MARKET_ID, 100e6, 100e6, alice, 5, _deadline());
    }

    function test_Revert_ExactInUnfilled() public {
        exchange.setResult(MARKET_ID, IPrediXExchangeView.Side.SELL_YES, 0, 100e6);
        _approveYesAsAlice(100e6);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(IPrediXRouter.ExactInUnfilled.selector, 100e6));
        router.sellYes(MARKET_ID, 100e6, 0, alice, 5, _deadline());
    }

    function test_Revert_MarketExpired() public {
        vm.warp(block.timestamp + 31 days);
        _approveYesAsAlice(1000);
        vm.prank(alice);
        vm.expectRevert(IPrediXRouter.MarketExpired.selector);
        router.sellYes(MARKET_ID, 1000, 0, alice, 5, _deadline());
    }

    function test_Revert_MarketModulePaused() public {
        diamond.setModulePaused(Modules.MARKET, true);
        _approveYesAsAlice(1000);
        vm.prank(alice);
        vm.expectRevert(IPrediXRouter.MarketModulePaused.selector);
        router.sellYes(MARKET_ID, 1000, 0, alice, 5, _deadline());
    }
}
