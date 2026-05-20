// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {IPrediXExchange} from "@predix/exchange/IPrediXExchange.sol";

import {MainnetForkFixture} from "../utils/MainnetForkFixture.sol";

/// @title RouterHappyPath_Fork
/// @notice End-to-end router trades on a forked mainnet stack: real USDC,
///         real v4 PoolManager, real V4Quoter, real Permit2.
///
/// @dev Coverage:
///   - buyYes via AMM-only (no CLOB liquidity)
///   - sellYes via AMM-only
///   - buyNo via AMM-only (virtual-NO synthesis path)
///   - buyYes mixed with seeded CLOB orders
///   - Deadline and minOut revert paths
///   - Router-stateless invariant across a multi-trade sequence
contract RouterHappyPath_Fork is MainnetForkFixture {
    function test_BuyYes_AmmOnly() public {
        _approveRouterForUsdc(alice);

        uint256 aliceUsdcBefore = usdc.balanceOf(alice);
        uint256 aliceYesBefore = IERC20(yesToken).balanceOf(alice);

        vm.prank(alice);
        (uint256 yesOut, uint256 clobFilled, uint256 ammFilled) =
            router.buyYes(marketId, 1_000e6, 0, alice, 5, block.timestamp + 1 hours);

        assertGt(yesOut, 0, "BuyYes must return YES");
        assertEq(clobFilled, 0, "CLOB is empty - all should be AMM");
        assertGt(ammFilled, 0, "AMM must fill");
        assertEq(yesOut, clobFilled + ammFilled, "Output must equal sum");

        // Alice spent USDC, received YES
        assertEq(usdc.balanceOf(alice), aliceUsdcBefore - 1_000e6, "Alice USDC delta");
        assertEq(IERC20(yesToken).balanceOf(alice) - aliceYesBefore, yesOut, "Alice received YES");

        // Router holds no funds at rest.
        assertEq(usdc.balanceOf(address(router)), 0, "Router USDC must be 0");
        assertEq(IERC20(yesToken).balanceOf(address(router)), 0, "Router YES must be 0");
        assertEq(IERC20(noToken).balanceOf(address(router)), 0, "Router NO must be 0");
    }

    function test_SellYes_AmmOnly() public {
        // Give alice some YES first (split USDC → YES + NO)
        _splitToUser(alice, 5_000e6);
        _approveRouterForYes(alice);

        uint256 aliceYesBefore = IERC20(yesToken).balanceOf(alice);
        uint256 aliceUsdcBefore = usdc.balanceOf(alice);

        vm.prank(alice);
        (uint256 usdcOut, uint256 clobFilled, uint256 ammFilled) =
            router.sellYes(marketId, 1_000e6, 0, alice, 5, block.timestamp + 1 hours);

        assertGt(usdcOut, 0, "SellYes must return USDC");
        assertEq(clobFilled, 0, "CLOB empty");
        assertGt(ammFilled, 0, "AMM filled");
        assertEq(usdcOut, clobFilled + ammFilled, "Output = sum");

        assertEq(aliceYesBefore - IERC20(yesToken).balanceOf(alice), 1_000e6, "Alice YES delta");
        assertEq(usdc.balanceOf(alice), aliceUsdcBefore + usdcOut, "Alice USDC received");

        // Router holds no funds at rest.
        assertEq(usdc.balanceOf(address(router)), 0);
        assertEq(IERC20(yesToken).balanceOf(address(router)), 0);
        assertEq(IERC20(noToken).balanceOf(address(router)), 0);
    }

    function test_BuyNo_AmmOnly_VirtualNoSynthesis() public {
        // Virtual-NO synthesis path:
        //   1. Flash-sell mintAmount YES on AMM, receiving USDC.
        //   2. Combine taker USDC with proceeds to call splitPosition(mintAmount)
        //      and obtain mintAmount YES + mintAmount NO.
        //   3. Settle the borrowed YES; deliver NO to the taker.
        // The trade size is intentionally small so the 2-pass quote stays
        // within the pool's safety margin given fixture-default liquidity.
        _approveRouterForUsdc(alice);

        uint256 aliceUsdcBefore = usdc.balanceOf(alice);
        uint256 aliceNoBefore = IERC20(noToken).balanceOf(alice);

        vm.prank(alice);
        (uint256 noOut, uint256 clobFilled, uint256 ammFilled) =
            router.buyNo(marketId, 100e6, 0, alice, 5, block.timestamp + 1 hours);

        assertGt(noOut, 0, "BuyNo must return NO via virtual synthesis");
        assertEq(clobFilled, 0, "CLOB empty");
        assertGt(ammFilled, 0, "Virtual-NO AMM must fill");
        assertEq(noOut, clobFilled + ammFilled);

        // The 2-pass quote applies a safety-margin downsize and the router
        // refunds unused USDC, so the net spend is bounded by the nominal
        // input with a small dust delta.
        uint256 aliceSpent = aliceUsdcBefore - usdc.balanceOf(alice);
        assertLe(aliceSpent, 100e6, "Alice spent <= 100 USDC nominal");
        assertGt(aliceSpent, 99e6, "Alice spent within 1% of nominal");
        assertEq(IERC20(noToken).balanceOf(alice) - aliceNoBefore, noOut);

        // Router holds no funds at rest.
        assertEq(usdc.balanceOf(address(router)), 0);
        assertEq(IERC20(yesToken).balanceOf(address(router)), 0);
        assertEq(IERC20(noToken).balanceOf(address(router)), 0);
    }

    function test_BuyYes_MixedClobAmm() public {
        // Bob places a SELL_YES order at $0.45 with 500 YES depth.
        // Alice's buyYes(1000 USDC) should fill the cheaper CLOB first, then AMM.
        _splitToUser(bob, 1_000e6);
        _approveExchangeForAll(bob);

        vm.prank(bob);
        exchange.placeOrder(marketId, IPrediXExchange.Side.SELL_YES, 450_000, 500e6, bytes32(0));

        _approveRouterForUsdc(alice);

        vm.prank(alice);
        (uint256 yesOut, uint256 clobFilled, uint256 ammFilled) =
            router.buyYes(marketId, 1_000e6, 0, alice, 10, block.timestamp + 1 hours);

        assertGt(clobFilled, 0, "CLOB should fill first (cheaper price)");
        assertGt(ammFilled, 0, "AMM picks up remainder");
        assertEq(yesOut, clobFilled + ammFilled);
        assertGt(yesOut, 0);

        // Router holds no funds at rest.
        assertEq(usdc.balanceOf(address(router)), 0);
        assertEq(IERC20(yesToken).balanceOf(address(router)), 0);
        assertEq(IERC20(noToken).balanceOf(address(router)), 0);
    }

    function test_BuyYes_Revert_ExpiredDeadline() public {
        _approveRouterForUsdc(alice);
        vm.prank(alice);
        vm.expectRevert();
        router.buyYes(marketId, 1_000e6, 0, alice, 5, block.timestamp - 1);
    }

    function test_BuyYes_Revert_InsufficientOutput() public {
        _approveRouterForUsdc(alice);
        vm.prank(alice);
        vm.expectRevert();
        router.buyYes(marketId, 1_000e6, type(uint256).max, alice, 5, block.timestamp + 1 hours);
    }

    function test_RouterZeroBalance_AfterMultipleTrades() public {
        // Sequence multiple trades across distinct actors and blocks. Each
        // block boundary clears the hook's same-block opposite-direction
        // detection so legitimate flow is not classified as a sandwich.
        _approveRouterForUsdc(alice);
        _approveRouterForUsdc(bob);
        _approveRouterForUsdc(charlie);
        _splitToUser(alice, 5_000e6);
        _splitToUser(bob, 5_000e6);
        _approveRouterForYes(alice);
        _approveRouterForNo(bob);

        // Alice buys YES on AMM
        vm.prank(alice);
        router.buyYes(marketId, 100e6, 0, alice, 5, block.timestamp + 1 hours);

        // Roll to next block to clear sandwich detection.
        vm.roll(block.number + 1);

        // Bob buys NO via virtual synthesis (different direction OK at new block)
        vm.prank(bob);
        router.buyNo(marketId, 50e6, 0, bob, 5, block.timestamp + 1 hours);

        vm.roll(block.number + 1);

        // Charlie buys YES
        vm.prank(charlie);
        router.buyYes(marketId, 200e6, 0, charlie, 5, block.timestamp + 1 hours);

        // Alice (different block from her buy) sells some YES
        vm.roll(block.number + 1);
        vm.prank(alice);
        router.sellYes(marketId, 50e6, 0, alice, 5, block.timestamp + 1 hours);

        assertEq(usdc.balanceOf(address(router)), 0, "Router USDC must remain 0");
        assertEq(IERC20(yesToken).balanceOf(address(router)), 0, "Router YES must remain 0");
        assertEq(IERC20(noToken).balanceOf(address(router)), 0, "Router NO must remain 0");
    }
}
