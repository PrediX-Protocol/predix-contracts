// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import {RouterFixture} from "../utils/RouterFixture.sol";
import {IPrediXExchangeView} from "@predix/router/interfaces/IPrediXExchangeView.sol";

/// @notice A pool WITH active liquidity (so `_hasPool` is true) can still fail the v4 Quoter's
///         full-fill requirement at a given size — the Quoter reverts `NotEnoughLiquidity(bytes32)`
///         (0x7a5ed734), re-wrapped as `UnexpectedRevertBytes(bytes)` (0x6190b2b0). The router must
///         degrade to the CLOB-only fill instead of propagating that revert and killing a trade the
///         orderbook can satisfy — mirroring the CLOB-side graceful contract (`_tryClobBuy`). Every
///         OTHER quoter revert (including an `UnexpectedRevertBytes` wrapping a NON-liquidity inner)
///         MUST still propagate (fail-loud preserved). Partial-liquidity sibling of the no-liquidity
///         gate exercised in `PrediXRouter_NoLiquidityPool`.
contract PrediXRouter_AmmGracefulFallback is RouterFixture {
    /// @dev Local mirror of IPrediXRouter.AmmQuoteUnfillable for `vm.expectEmit` (matched by signature).
    event AmmQuoteUnfillable(bytes32 indexed poolId, bytes4 reason);

    /// @dev The exact payload the production V4Quoter bubbles up when a probe cannot be filled:
    ///      UnexpectedRevertBytes(NotEnoughLiquidity(poolId)).
    function _wrappedNotEnoughLiquidity() internal pure returns (bytes memory) {
        bytes memory inner = abi.encodeWithSelector(bytes4(0x7a5ed734), bytes32(0));
        return abi.encodeWithSelector(bytes4(0x6190b2b0), inner);
    }

    function test_QuoteBuyYes_LiquidityPresent_QuoterReverts_FallsBackClobOnly() public {
        // Pool keeps its fixture liquidity (1e18) so `_hasPool` is true — NOT the no-liquidity case.
        quoter.setRevert(_wrappedNotEnoughLiquidity());
        exchange.setResult(MARKET_ID, IPrediXExchangeView.Side.BUY_YES, 120e6, 60e6);

        (uint256 expectedYesOut, uint256 clobPortion, uint256 ammPortion) = router.quoteBuyYes(MARKET_ID, 100e6, 5);

        assertEq(ammPortion, 0, "AMM portion skipped (quoter reverted on cap + remainder)");
        assertEq(clobPortion, 120e6, "CLOB portion");
        assertEq(expectedYesOut, 120e6, "quote = CLOB only, no revert");
    }

    function test_QuoteBuyYes_BareNotEnoughLiquidity_FallsBackClobOnly() public {
        // The un-wrapped NotEnoughLiquidity selector is also in the graceful set.
        quoter.setRevert(abi.encodeWithSelector(bytes4(0x7a5ed734), bytes32(0)));
        exchange.setResult(MARKET_ID, IPrediXExchangeView.Side.BUY_YES, 120e6, 60e6);

        (uint256 expectedYesOut, uint256 clobPortion, uint256 ammPortion) = router.quoteBuyYes(MARKET_ID, 100e6, 5);

        assertEq(ammPortion, 0, "AMM skipped");
        assertEq(clobPortion, 120e6, "CLOB portion");
        assertEq(expectedYesOut, 120e6, "CLOB only");
    }

    function test_QuoteSellYes_LiquidityPresent_QuoterReverts_FallsBackClobOnly() public {
        quoter.setRevert(_wrappedNotEnoughLiquidity());
        // Sell 120 YES; CLOB takes 100 shares for 60 USDC, leaving a 20-share AMM remainder.
        exchange.setResult(MARKET_ID, IPrediXExchangeView.Side.SELL_YES, 60e6, 100e6);

        (uint256 expectedUsdcOut, uint256 clobPortion, uint256 ammPortion) = router.quoteSellYes(MARKET_ID, 120e6, 5);

        assertEq(ammPortion, 0, "AMM skipped");
        assertEq(clobPortion, 60e6, "CLOB USDC out");
        assertEq(expectedUsdcOut, 60e6, "CLOB only");
    }

    function test_QuoteBuyNo_LiquidityPresent_QuoterReverts_FallsBackClobOnly() public {
        // buyNo routes through `_computeBuyNoMintAmount` + the spot probe `_ammSpotPriceForSell`.
        quoter.setRevert(_wrappedNotEnoughLiquidity());
        exchange.setResult(MARKET_ID, IPrediXExchangeView.Side.BUY_NO, 80e6, 50e6);

        (uint256 expectedNoOut, uint256 clobPortion, uint256 ammPortion) = router.quoteBuyNo(MARKET_ID, 100e6, 5);

        assertEq(ammPortion, 0, "AMM skipped");
        assertEq(clobPortion, 80e6, "CLOB NO out");
        assertEq(expectedNoOut, 80e6, "CLOB only");
    }

    function test_QuoteSellNo_LiquidityPresent_QuoterReverts_FallsBackClobOnly() public {
        // sellNo routes through `_computeSellNoMaxCost` (quoteExactOutputSingle).
        quoter.setRevert(_wrappedNotEnoughLiquidity());
        // Sell 100 NO; CLOB takes 80 shares for 40 USDC, leaving a 20-share AMM remainder.
        exchange.setResult(MARKET_ID, IPrediXExchangeView.Side.SELL_NO, 40e6, 80e6);

        (uint256 expectedUsdcOut, uint256 clobPortion, uint256 ammPortion) = router.quoteSellNo(MARKET_ID, 100e6, 5);

        assertEq(ammPortion, 0, "AMM skipped");
        assertEq(clobPortion, 40e6, "CLOB USDC out");
        assertEq(expectedUsdcOut, 40e6, "CLOB only");
    }

    function test_BuyYes_LiquidityPresent_QuoterReverts_ClobFillsAll_NoRevert() public {
        quoter.setRevert(_wrappedNotEnoughLiquidity());
        // CLOB absorbs the whole budget -> no AMM remainder -> swap never attempted.
        exchange.setResult(MARKET_ID, IPrediXExchangeView.Side.BUY_YES, 200e6, 100e6);

        vm.prank(alice);
        usdc.approve(address(router), 100e6);
        vm.prank(alice);
        (uint256 yesOut, uint256 clobFilled, uint256 ammFilled) =
            router.buyYes(MARKET_ID, 100e6, 0, alice, 5, _deadline());

        assertEq(clobFilled, 200e6, "CLOB fills full budget");
        assertEq(ammFilled, 0, "AMM skipped (quoter reverted on cap)");
        assertEq(yesOut, 200e6, "yesOut = CLOB only");
        assertEq(poolManager.swapCount(), 0, "AMM swap never attempted");
        assertEq(usdc.balanceOf(address(router)), 0, "router USDC drained");
        assertEq(yes1.balanceOf(address(router)), 0, "router YES zero");
    }

    function test_BuyYes_QuoterReverts_ClobPartial_AmmRealSwapFillsRemainder() public {
        // The quoter (cap derivation) reverts, but the EXECUTE real swap still fills the
        // CLOB remainder — graceful cap derivation must not break actual AMM execution.
        quoter.setRevert(_wrappedNotEnoughLiquidity());
        exchange.setResult(MARKET_ID, IPrediXExchangeView.Side.BUY_YES, 120e6, 60e6);
        // Real swap: spend the 40-USDC remainder for 72 YES.
        if (address(usdc) < address(yes1)) {
            poolManager.queueSwapResult(-int128(40e6), int128(72e6));
        } else {
            poolManager.queueSwapResult(int128(72e6), -int128(40e6));
        }

        vm.prank(alice);
        usdc.approve(address(router), 100e6);
        vm.prank(alice);
        (uint256 yesOut, uint256 clobFilled, uint256 ammFilled) =
            router.buyYes(MARKET_ID, 100e6, 0, alice, 5, _deadline());

        assertEq(clobFilled, 120e6, "CLOB fills its depth");
        assertEq(ammFilled, 72e6, "AMM real swap fills the remainder");
        assertEq(yesOut, 192e6, "yesOut = CLOB + AMM");
        assertEq(poolManager.swapCount(), 1, "exactly one AMM swap");
        assertEq(usdc.balanceOf(address(router)), 0, "router USDC drained");
    }

    function test_BuyNo_LiquidityPresent_QuoterReverts_ClobPartial_SkipsAmm() public {
        quoter.setRevert(_wrappedNotEnoughLiquidity());
        // CLOB fills 80 NO for 40 USDC; the 60-USDC remainder must NOT abort on the AMM sizing probe.
        exchange.setResult(MARKET_ID, IPrediXExchangeView.Side.BUY_NO, 80e6, 40e6);

        vm.prank(alice);
        usdc.approve(address(router), 100e6);
        vm.prank(alice);
        (uint256 noOut, uint256 clobFilled, uint256 ammFilled) =
            router.buyNo(MARKET_ID, 100e6, 0, alice, 5, _deadline());

        assertEq(clobFilled, 80e6, "CLOB fills its depth");
        assertEq(ammFilled, 0, "AMM skipped (sizing probe reverted)");
        assertEq(noOut, 80e6, "noOut = CLOB only");
        assertEq(poolManager.swapCount(), 0, "AMM swap never attempted");
        assertEq(usdc.balanceOf(address(router)), 0, "router USDC drained (remainder refunded)");
    }

    function test_BuyYes_QuoterRevertsNonGraceful_Propagates() public {
        // A non-liquidity revert selector must NOT be swallowed — fail loud.
        quoter.setRevert(abi.encodeWithSelector(bytes4(0xdeadbeef)));
        exchange.setResult(MARKET_ID, IPrediXExchangeView.Side.BUY_YES, 200e6, 100e6);

        vm.prank(alice);
        usdc.approve(address(router), 100e6);
        vm.prank(alice);
        vm.expectRevert(bytes4(0xdeadbeef));
        router.buyYes(MARKET_ID, 100e6, 0, alice, 5, _deadline());
    }

    function test_QuoterReverts_UnexpectedWrappingNonLiquidity_Propagates() public {
        // The narrow catch decodes the inner selector: an UnexpectedRevertBytes wrapping a
        // NON-NotEnoughLiquidity inner (e.g. a hook fault) must NOT be mistaken for a liquidity skip.
        bytes memory innerOther = abi.encodeWithSelector(bytes4(0xdeadbeef));
        bytes memory wrapped = abi.encodeWithSelector(bytes4(0x6190b2b0), innerOther);
        quoter.setRevert(wrapped);
        exchange.setResult(MARKET_ID, IPrediXExchangeView.Side.BUY_YES, 200e6, 100e6);

        vm.prank(alice);
        usdc.approve(address(router), 100e6);
        vm.prank(alice);
        // The FULL payload propagates verbatim — not swallowed as a liquidity skip.
        vm.expectRevert(wrapped);
        router.buyYes(MARKET_ID, 100e6, 0, alice, 5, _deadline());
    }

    function test_QuoteBuyYes_QuoterReverts_EmitsAmmQuoteUnfillable() public {
        quoter.setRevert(_wrappedNotEnoughLiquidity());
        exchange.setResult(MARKET_ID, IPrediXExchangeView.Side.BUY_YES, 120e6, 60e6);

        // poolId not checked (false); reason (NotEnoughLiquidity selector) checked.
        vm.expectEmit(false, false, false, true, address(router));
        emit AmmQuoteUnfillable(bytes32(0), bytes4(0x7a5ed734));
        router.quoteBuyYes(MARKET_ID, 100e6, 5);
    }
}
