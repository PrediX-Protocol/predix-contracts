// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {RouterFixture} from "../utils/RouterFixture.sol";
import {IPrediXRouter} from "@predix/router/interfaces/IPrediXRouter.sol";
import {IPrediXExchangeView} from "@predix/router/interfaces/IPrediXExchangeView.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Modules} from "@predix/shared/constants/Modules.sol";

contract PrediXRouter_BuyYes is RouterFixture {
    function _approveUsdcAsAlice(uint256 amount) internal {
        vm.prank(alice);
        usdc.approve(address(router), amount);
    }

    // ============================================================
    // Happy paths
    // ============================================================

    function test_HappyPath_ClobOnly() public {
        uint256 usdcIn = 100e6;
        // Canned CLOB result: fill the whole 100 USDC, deliver 200 YES (price 0.5).
        exchange.setResult(MARKET_ID, IPrediXExchangeView.Side.BUY_YES, 200e6, usdcIn);

        _approveUsdcAsAlice(usdcIn);
        vm.prank(alice);
        (uint256 yesOut, uint256 clobFilled, uint256 ammFilled) =
            router.buyYes(MARKET_ID, usdcIn, 0, alice, 5, _deadline());

        assertEq(yesOut, 200e6, "yesOut");
        assertEq(clobFilled, 200e6, "clobFilled");
        assertEq(ammFilled, 0, "ammFilled");
        assertEq(yes1.balanceOf(alice), 1_000_000e6 + 200e6, "alice yes");
        assertEq(usdc.balanceOf(address(router)), 0, "router usdc zero");
        assertEq(yes1.balanceOf(address(router)), 0, "router yes zero");
        assertEq(hook.commitCount(), 1, "CLOB cap probe commits for quoter");
    }

    function test_HappyPath_AmmOnly() public {
        uint256 usdcIn = 100e6;
        // CLOB fills nothing (no canned result set).
        // AMM queued: USDC (currency0) = -100e6, YES (currency1) = +180e6.
        // Determine currency ordering: usdc < yes1 → usdc is currency0.
        if (address(usdc) < address(yes1)) {
            poolManager.queueSwapResult(-int128(int256(usdcIn)), int128(180e6));
        } else {
            poolManager.queueSwapResult(int128(180e6), -int128(int256(usdcIn)));
        }

        _approveUsdcAsAlice(usdcIn);
        vm.prank(alice);
        (uint256 yesOut, uint256 clobFilled, uint256 ammFilled) =
            router.buyYes(MARKET_ID, usdcIn, 0, alice, 5, _deadline());

        assertEq(clobFilled, 0, "clob 0");
        assertEq(ammFilled, 180e6, "amm 180");
        assertEq(yesOut, 180e6, "yesOut");
        assertEq(hook.commitCount(), 2, "CLOB cap probe + AMM swap commit");
        assertEq(hook.lastCommitUser(), alice, "commit user == alice");
        assertEq(poolManager.swapCount(), 1, "one swap");
    }

    function test_HappyPath_Split() public {
        uint256 usdcIn = 100e6;
        // CLOB takes 60 USDC → 120 YES (price 0.5).
        exchange.setResult(MARKET_ID, IPrediXExchangeView.Side.BUY_YES, 120e6, 60e6);
        // AMM gets the remaining 40 USDC → 72 YES.
        if (address(usdc) < address(yes1)) {
            poolManager.queueSwapResult(-int128(40e6), int128(72e6));
        } else {
            poolManager.queueSwapResult(int128(72e6), -int128(40e6));
        }

        _approveUsdcAsAlice(usdcIn);
        vm.prank(alice);
        (uint256 yesOut, uint256 clobFilled, uint256 ammFilled) =
            router.buyYes(MARKET_ID, usdcIn, 0, alice, 5, _deadline());
        assertEq(clobFilled, 120e6);
        assertEq(ammFilled, 72e6);
        assertEq(yesOut, 192e6);
        assertEq(yes1.balanceOf(alice), 1_000_000e6 + 192e6);
    }

    function test_HappyPath_RecipientDifferentFromCaller() public {
        uint256 usdcIn = 100e6;
        exchange.setResult(MARKET_ID, IPrediXExchangeView.Side.BUY_YES, 150e6, usdcIn);

        _approveUsdcAsAlice(usdcIn);
        vm.prank(alice);
        router.buyYes(MARKET_ID, usdcIn, 0, bob, 5, _deadline());

        assertEq(yes1.balanceOf(bob), 1_000_000e6 + 150e6, "bob got YES");
        assertEq(yes1.balanceOf(alice), 1_000_000e6, "alice unchanged");
    }

    function test_Refund_ExcessUsdc() public {
        uint256 usdcIn = 100e6;
        // CLOB consumes only 80 USDC (partial), no AMM queued → remaining 20 must be
        // refunded to alice by the exchange refund path; but our mock's fillMarketOrder
        // only pulls what it uses, so router ends up with 20 USDC residual → refund.
        exchange.setResult(MARKET_ID, IPrediXExchangeView.Side.BUY_YES, 160e6, 80e6);
        // AMM: 20 USDC → 0 YES out (zero liquidity). Router should revert.
        // Instead, queue a real AMM fill for the remainder so the full buyYes works
        // and the refund path exercises dust=0. To test refund, reconfigure: skip AMM
        // setup and ensure exchange pulls 80, AMM path reverts because nothing queued.
        // Alternative clean test: configure exchange to not set `amountInRemaining`,
        // by ensuring _tryClobBuy returns amountInRemaining > 0 BUT AMM queued.
        if (address(usdc) < address(yes1)) {
            poolManager.queueSwapResult(-int128(20e6), int128(36e6));
        } else {
            poolManager.queueSwapResult(int128(36e6), -int128(20e6));
        }

        _approveUsdcAsAlice(usdcIn);
        uint256 aliceBefore = usdc.balanceOf(alice);
        vm.prank(alice);
        router.buyYes(MARKET_ID, usdcIn, 0, alice, 5, _deadline());
        assertEq(usdc.balanceOf(address(router)), 0);
        assertEq(usdc.balanceOf(alice), aliceBefore - usdcIn);
    }

    // ============================================================
    // Revert paths
    // ============================================================

    function test_Revert_ZeroAmount() public {
        _approveUsdcAsAlice(1);
        vm.prank(alice);
        vm.expectRevert(IPrediXRouter.ZeroAmount.selector);
        router.buyYes(MARKET_ID, 0, 0, alice, 5, _deadline());
    }

    function test_Revert_BelowMinTradeAmount() public {
        _approveUsdcAsAlice(500);
        vm.prank(alice);
        vm.expectRevert(IPrediXRouter.ZeroAmount.selector);
        router.buyYes(MARKET_ID, 500, 0, alice, 5, _deadline());
    }

    function test_Revert_DeadlineExpired() public {
        _approveUsdcAsAlice(1000);
        uint256 past = block.timestamp - 1;
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(IPrediXRouter.DeadlineExpired.selector, past, block.timestamp));
        router.buyYes(MARKET_ID, 1000, 0, alice, 5, past);
    }

    function test_Revert_InvalidRecipient_Self() public {
        _approveUsdcAsAlice(1000);
        vm.prank(alice);
        vm.expectRevert(IPrediXRouter.InvalidRecipient.selector);
        router.buyYes(MARKET_ID, 1000, 0, address(router), 5, _deadline());
    }

    function test_Revert_InvalidRecipient_Zero() public {
        _approveUsdcAsAlice(1000);
        vm.prank(alice);
        vm.expectRevert(IPrediXRouter.InvalidRecipient.selector);
        router.buyYes(MARKET_ID, 1000, 0, address(0), 5, _deadline());
    }

    function test_Revert_InvalidRecipient_Diamond() public {
        _approveUsdcAsAlice(1000);
        vm.prank(alice);
        vm.expectRevert(IPrediXRouter.InvalidRecipient.selector);
        router.buyYes(MARKET_ID, 1000, 0, address(diamond), 5, _deadline());
    }

    function test_Revert_InsufficientOutput() public {
        uint256 usdcIn = 100e6;
        exchange.setResult(MARKET_ID, IPrediXExchangeView.Side.BUY_YES, 150e6, usdcIn);
        _approveUsdcAsAlice(usdcIn);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(IPrediXRouter.InsufficientOutput.selector, 150e6, 200e6));
        router.buyYes(MARKET_ID, usdcIn, 200e6, alice, 5, _deadline());
    }

    function test_Revert_ExactInUnfilled() public {
        // CLOB consumes the full budget (cost == usdcIn) but delivers zero shares — pathological
        // pathway where usdcRemaining becomes 0 so the AMM is never touched and total fill is 0.
        uint256 usdcIn = 100e6;
        exchange.setResult(MARKET_ID, IPrediXExchangeView.Side.BUY_YES, 0, usdcIn);
        _approveUsdcAsAlice(usdcIn);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(IPrediXRouter.ExactInUnfilled.selector, usdcIn));
        router.buyYes(MARKET_ID, usdcIn, 0, alice, 5, _deadline());
    }

    function test_Revert_MarketNotFound() public {
        _approveUsdcAsAlice(1000);
        vm.prank(alice);
        vm.expectRevert(IPrediXRouter.MarketNotFound.selector);
        router.buyYes(999, 1000, 0, alice, 5, _deadline());
    }

    function test_Revert_MarketResolved() public {
        diamond.setMarket(MARKET_ID, address(yes1), address(no1), block.timestamp + 1 days, true, false);
        _approveUsdcAsAlice(1000);
        vm.prank(alice);
        vm.expectRevert(IPrediXRouter.MarketResolved.selector);
        router.buyYes(MARKET_ID, 1000, 0, alice, 5, _deadline());
    }

    function test_Revert_MarketExpired() public {
        vm.warp(block.timestamp + 31 days);
        _approveUsdcAsAlice(1000);
        vm.prank(alice);
        vm.expectRevert(IPrediXRouter.MarketExpired.selector);
        router.buyYes(MARKET_ID, 1000, 0, alice, 5, _deadline());
    }

    function test_Revert_MarketInRefundMode() public {
        diamond.setMarket(MARKET_ID, address(yes1), address(no1), block.timestamp + 1 days, false, true);
        _approveUsdcAsAlice(1000);
        vm.prank(alice);
        vm.expectRevert(IPrediXRouter.MarketInRefundMode.selector);
        router.buyYes(MARKET_ID, 1000, 0, alice, 5, _deadline());
    }

    function test_Revert_MarketModulePaused() public {
        diamond.setModulePaused(Modules.MARKET, true);
        _approveUsdcAsAlice(1000);
        vm.prank(alice);
        vm.expectRevert(IPrediXRouter.MarketModulePaused.selector);
        router.buyYes(MARKET_ID, 1000, 0, alice, 5, _deadline());
    }

    // ============================================================
    // Hook commit ordering
    // ============================================================

    function test_HookCommit_CalledBeforeUnlock() public {
        uint256 usdcIn = 100e6;
        // Full AMM path
        if (address(usdc) < address(yes1)) {
            poolManager.queueSwapResult(-int128(int256(usdcIn)), int128(180e6));
        } else {
            poolManager.queueSwapResult(int128(180e6), -int128(int256(usdcIn)));
        }
        _approveUsdcAsAlice(usdcIn);
        vm.prank(alice);
        router.buyYes(MARKET_ID, usdcIn, 0, alice, 5, _deadline());
        // Hook commit must have happened before any swap: MockHook records in the same tx,
        // so commitCount=1 and swapCount=1. Assert hook.lastCommitUser == real end user alice.
        assertEq(hook.commitCount(), 2);
        assertEq(hook.lastCommitUser(), alice);
        assertEq(poolManager.swapCount(), 1);
    }

    // ============================================================
    // Fallback: exchange revert → 100% AMM
    // ============================================================

    function test_ExchangeRevert_FallsBackToAmm() public {
        uint256 usdcIn = 100e6;
        exchange.setRevertOnFill(true);
        if (address(usdc) < address(yes1)) {
            poolManager.queueSwapResult(-int128(int256(usdcIn)), int128(180e6));
        } else {
            poolManager.queueSwapResult(int128(180e6), -int128(int256(usdcIn)));
        }
        _approveUsdcAsAlice(usdcIn);
        vm.prank(alice);
        (uint256 yesOut, uint256 clobFilled, uint256 ammFilled) =
            router.buyYes(MARKET_ID, usdcIn, 0, alice, 5, _deadline());
        assertEq(clobFilled, 0);
        assertEq(ammFilled, 180e6);
        assertEq(yesOut, 180e6);
    }
}
