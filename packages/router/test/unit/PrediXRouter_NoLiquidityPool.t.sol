// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import {RouterFixture} from "../utils/RouterFixture.sol";
import {IPrediXExchangeView} from "@predix/router/interfaces/IPrediXExchangeView.sol";

/// @notice keyti-jefd: a pool that is registered + initialized (sqrtPrice set) but holds NO active liquidity
///         must NOT be routed to — `_hasPool` now gates on liquidity, so market orders fall back to 100% CLOB
///         instead of reverting NotEnoughLiquidity on the AMM remainder. No swap is queued in these tests, so
///         the OLD `_hasPool` (init-only) would route to the AMM and the mock swap would revert the whole order.
contract PrediXRouter_NoLiquidityPool is RouterFixture {
    function test_BuyYes_InitializedNoLiquidity_FillsClobOnly_SkipsAmm() public {
        _setPoolLiquidity(address(yes1), 0); // initialized (sqrtPrice set in fixture) but drained to 0 liquidity

        uint256 usdcIn = 100e6;
        // CLOB has partial depth: 60 USDC -> 120 YES. The 40 USDC remainder must NOT hit the AMM.
        exchange.setResult(MARKET_ID, IPrediXExchangeView.Side.BUY_YES, 120e6, 60e6);

        vm.prank(alice);
        usdc.approve(address(router), usdcIn);
        vm.prank(alice);
        (uint256 yesOut, uint256 clobFilled, uint256 ammFilled) =
            router.buyYes(MARKET_ID, usdcIn, 0, alice, 5, _deadline());

        assertEq(clobFilled, 120e6, "CLOB fills its depth");
        assertEq(ammFilled, 0, "AMM not routed (no liquidity)");
        assertEq(yesOut, 120e6, "yesOut = CLOB only");
        assertEq(poolManager.swapCount(), 0, "AMM swap never attempted");
        assertEq(usdc.balanceOf(address(router)), 0, "router USDC drained (remainder refunded)");
        assertEq(yes1.balanceOf(address(router)), 0, "router YES zero");
    }

    function test_QuoteBuyYes_InitializedNoLiquidity_ReturnsClobOnly() public {
        _setPoolLiquidity(address(yes1), 0);

        uint256 usdcIn = 100e6;
        exchange.setResult(MARKET_ID, IPrediXExchangeView.Side.BUY_YES, 120e6, 60e6);
        // If the AMM were (wrongly) routed for the 40-USDC remainder, the quoter would return this -> the
        // assertion below pins it to 0, so this leg only passes when `_hasPool` skips the no-liquidity pool.
        quoter.setExactInResult(50e6);

        (uint256 expectedYesOut, uint256 clobPortion, uint256 ammPortion) = router.quoteBuyYes(MARKET_ID, usdcIn, 5);

        assertEq(ammPortion, 0, "no AMM portion (no liquidity)");
        assertEq(clobPortion, 120e6, "CLOB portion");
        assertEq(expectedYesOut, 120e6, "quote = CLOB only, no revert");
    }
}
