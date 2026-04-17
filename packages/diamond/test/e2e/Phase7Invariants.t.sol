// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {IMarketFacet} from "@predix/shared/interfaces/IMarketFacet.sol";
import {IPrediXExchange} from "@predix/exchange/IPrediXExchange.sol";
import {IManualOracle} from "@predix/oracle/interfaces/IManualOracle.sol";

import {Phase7ForkBase} from "./Phase7ForkBase.t.sol";

/// @notice State invariants I-1..I-4 asserted end-to-end against live Phase 7
///         contracts. Each test walks a flow and snapshots balances before /
///         after, proving the invariant holds across the operation.
contract Phase7Invariants is Phase7ForkBase {
    IMarketFacet internal market;
    IPrediXExchange internal exchange;
    IManualOracle internal manualOracle;

    function setUp() public virtual override {
        super.setUp();
        market = IMarketFacet(DIAMOND);
        exchange = IPrediXExchange(EXCHANGE);
        manualOracle = IManualOracle(MANUAL_ORACLE);
    }

    // =================================================================
    // I-1 — YES.totalSupply == NO.totalSupply == market.totalCollateral
    //        pre-resolution (outcome tokens strictly paired)
    // =================================================================

    function test_Invariant_I1_YesNoCollateralPaired() public {
        vm.prank(MULTISIG);
        uint256 marketId = market.createMarket("I-1 paired", block.timestamp + 1 days, MANUAL_ORACLE);
        IMarketFacet.MarketView memory mkt = market.getMarket(marketId);

        address u1 = makeAddr("i1_u1");
        address u2 = makeAddr("i1_u2");
        _splitAs(u1, marketId, 40e6);
        _splitAs(u2, marketId, 25e6);

        IMarketFacet.MarketView memory m = market.getMarket(marketId);
        uint256 yesSupply = IERC20(mkt.yesToken).totalSupply();
        uint256 noSupply = IERC20(mkt.noToken).totalSupply();

        assertEq(yesSupply, noSupply, "YES.totalSupply == NO.totalSupply");
        assertEq(yesSupply, m.totalCollateral, "YES.totalSupply == market.totalCollateral");
    }

    // =================================================================
    // I-2 — exchange.usdc.balanceOf grows by the escrow of a BUY order
    //        (deposit locked == price * amount for BUY)
    // =================================================================

    function test_Invariant_I2_ExchangeEscrowsOnBuy() public {
        vm.prank(MULTISIG);
        uint256 marketId = market.createMarket("I-2 escrow", block.timestamp + 1 days, MANUAL_ORACLE);

        address maker = makeAddr("i2_maker");
        uint256 budget = 50e6;
        deal(USDC, maker, budget);

        uint256 exBefore = IERC20(USDC).balanceOf(EXCHANGE);

        uint256 price = 0.4e6;
        uint256 amount = 10e6;
        // Expected escrow for a BUY: price * amount / 1e6 = 4 USDC.
        uint256 expectedEscrow = price * amount / 1e6;

        vm.startPrank(maker);
        IERC20(USDC).approve(EXCHANGE, budget);
        exchange.placeOrder(marketId, IPrediXExchange.Side.BUY_YES, price, amount);
        vm.stopPrank();

        uint256 exAfter = IERC20(USDC).balanceOf(EXCHANGE);
        assertEq(exAfter - exBefore, expectedEscrow, "exchange escrow delta != price*amount");
    }

    // =================================================================
    // I-3 — router.usdc.balanceOf == 0 at rest (Router is stateless)
    // =================================================================

    function test_Invariant_I3_RouterIsStateless() public view {
        // Live on-chain state read at FORK_BLOCK — no prior interaction with
        // Router has taken place (testnet deploy just finished). The invariant
        // is that Router must never hold user funds between txs.
        assertEq(IERC20(USDC).balanceOf(ROUTER), 0, "router USDC not zero");
    }

    // =================================================================
    // I-4 — Post-resolve, winning side redeem sum == market.totalCollateral
    //        under the default testnet zero-fee config.
    // =================================================================

    function test_Invariant_I4_WinnersRedeemFullCollateral() public {
        vm.prank(MULTISIG);
        uint256 marketId = market.createMarket("I-4 redeem sum", block.timestamp + 1 hours, MANUAL_ORACLE);

        address a = makeAddr("i4_a");
        address b = makeAddr("i4_b");
        _splitAs(a, marketId, 30e6);
        _splitAs(b, marketId, 20e6);

        IMarketFacet.MarketView memory mkt = market.getMarket(marketId);

        vm.warp(mkt.endTime + 1);
        vm.prank(REPORTER_ADDR);
        manualOracle.report(marketId, true);
        market.resolveMarket(marketId);

        uint256 totalBefore = mkt.totalCollateral;

        vm.prank(a);
        uint256 payA = market.redeem(marketId);
        vm.prank(b);
        uint256 payB = market.redeem(marketId);

        assertEq(payA + payB, totalBefore, "sum of payouts != total collateral at zero fee");
    }

    // ==================================================================
    // Internal helpers
    // ==================================================================

    function _splitAs(address user, uint256 marketId, uint256 amount) internal {
        deal(USDC, user, amount);
        vm.startPrank(user);
        IERC20(USDC).approve(DIAMOND, amount);
        market.splitPosition(marketId, amount);
        vm.stopPrank();
    }
}
