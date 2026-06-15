// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import {RouterFixture} from "../utils/RouterFixture.sol";
import {PrediXRouterHarness} from "../utils/PrediXRouterHarness.sol";
import {IPrediXRouter} from "@predix/router/interfaces/IPrediXRouter.sol";
import {IPrediXExchangeView} from "@predix/router/interfaces/IPrediXExchangeView.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IV4Quoter} from "@uniswap/v4-periphery/src/interfaces/IV4Quoter.sol";
import {IAllowanceTransfer} from "permit2/src/interfaces/IAllowanceTransfer.sol";
import {IBuilderRegistry} from "@predix/shared/interfaces/IBuilderRegistry.sol";

/// @notice Sub-plan 04 Tasks 1-2: fee-helper math (`_feeOn`/`_curveFee` via the harness), the
///         `builderRegistry` constructor wiring, and the CLOB-leg `builder` pass-through + `Trade.builder`.
///         The AMM-leg fee carve is Tasks 3-6.
contract PrediXRouter_AmmFee is RouterFixture {
    function _approveUsdcAsAlice(uint256 amount) internal {
        usdc.mint(alice, amount);
        vm.prank(alice);
        IERC20(address(usdc)).approve(address(router), amount);
    }

    // ---- helper-math unit checks (curve correctness, §1 worked example) ----
    function test_curveFee_polymarketParity_100sharesAt50c() public view {
        assertEq(router.exposed_curveFee(1e8, 700, 500_000), 1_750_000, "100sh @50c coef700 = $1.75");
    }

    function test_curveFee_tailFalloff_p10() public view {
        assertEq(router.exposed_curveFee(1e8, 700, 100_000), 630_000, "100sh @10c coef700 = $0.63");
    }

    function test_curveFee_zeroCoef_isZero() public view {
        assertEq(router.exposed_curveFee(1e8, 0, 500_000), 0, "coef 0 => 0");
    }

    function test_curveFee_saturatedP_isZero() public view {
        assertEq(router.exposed_curveFee(1e8, 700, 1_000_000), 0, "p>=1e6 => 0");
        assertEq(router.exposed_curveFee(1e8, 700, 0), 0, "p==0 => 0");
    }

    function test_feeOn_flatBps() public view {
        assertEq(router.exposed_feeOn(100e6, 100), 1e6, "1% of 100 = 1");
        assertEq(router.exposed_feeOn(100e6, 0), 0, "0 bps => 0");
    }

    // ---- constructor + CLOB-forward + Trade.builder (Task 2) ----
    function test_constructor_storesBuilderRegistry() public view {
        assertEq(address(router.builderRegistry()), address(builderRegistry), "registry immutable");
    }

    function test_constructor_rejectsZeroBuilderRegistry() public {
        vm.expectRevert(IPrediXRouter.ZeroAddress.selector);
        new PrediXRouterHarness(
            IPoolManager(address(poolManager)),
            address(diamond),
            address(usdc),
            address(hook),
            address(exchange),
            IV4Quoter(address(quoter)),
            IAllowanceTransfer(address(permit2)),
            LP_FEE_FLAG,
            TICK_SPACING,
            IBuilderRegistry(address(0))
        );
    }

    // builder == 0 + coef 0 (launch) on a pure-CLOB fill: Trade.builder == 0, no AMM fee.
    function test_buyYes_noBuilder_emitsTradeBuilderZero() public {
        uint256 usdcIn = 100e6;
        exchange.setResult(MARKET_ID, IPrediXExchangeView.Side.BUY_YES, 200e6, usdcIn);
        _approveUsdcAsAlice(usdcIn);

        vm.expectEmit(true, true, true, true, address(router));
        emit IPrediXRouter.Trade(
            MARKET_ID, alice, alice, IPrediXRouter.TradeType.BUY_YES, usdcIn, 200e6, 200e6, 0, bytes32(0)
        );
        vm.prank(alice);
        router.buyYes(MARKET_ID, usdcIn, 0, alice, 5, _deadline(), bytes32(0));
    }

    // CLOB leg receives the builder code (charged in-exchange; asserted via the mock's recorded arg).
    function test_buyYes_clobLeg_forwardsBuilder() public {
        uint256 usdcIn = 100e6;
        exchange.setResult(MARKET_ID, IPrediXExchangeView.Side.BUY_YES, 200e6, usdcIn);
        _approveUsdcAsAlice(usdcIn);
        vm.prank(alice);
        router.buyYes(MARKET_ID, usdcIn, 0, alice, 5, _deadline(), BUILDER);
        assertEq(exchange.lastTakerBuilder(), BUILDER, "CLOB leg got builder code");
    }

    function test_sellYes_clobLeg_forwardsBuilder() public {
        uint256 yesIn = 100e6;
        exchange.setResult(MARKET_ID, IPrediXExchangeView.Side.SELL_YES, 50e6, yesIn);
        yes1.mint(alice, yesIn);
        vm.prank(alice);
        yes1.approve(address(router), yesIn);
        vm.prank(alice);
        router.sellYes(MARKET_ID, yesIn, 0, alice, 5, _deadline(), BUILDER);
        assertEq(exchange.lastTakerBuilder(), BUILDER, "SELL CLOB leg got builder code");
    }

    function _queueBuySwap(int128 usdcIn, int128 yesOut) internal {
        if (address(usdc) < address(yes1)) {
            poolManager.queueSwapResult(-usdcIn, yesOut);
        } else {
            poolManager.queueSwapResult(yesOut, -usdcIn);
        }
    }

    function _queueSellSwap(int128 yesIn, int128 usdcOut) internal {
        if (address(yes1) < address(usdc)) {
            poolManager.queueSwapResult(-yesIn, usdcOut);
        } else {
            poolManager.queueSwapResult(usdcOut, -yesIn);
        }
    }

    // ===== Task 3: AMM-leg builder fee (buyYes / sellYes), coef 0 =====

    // buyYes builder 100bps: ammSpend = 100 - 1 = 99; fee 1 forwarded; NO out is gross (fee paid in USDC).
    function test_buyYes_ammLeg_builderFee_forwardedAndNet() public {
        uint256 usdcIn = 100e6;
        builderRegistry.setBuilder(BUILDER, 100, 0, address(0xB111D));
        _queueBuySwap(int128(99e6), int128(1782e5)); // 99 USDC → 178.2 YES
        _approveUsdcAsAlice(usdcIn);
        vm.prank(alice);
        (uint256 yesOut, uint256 clobFilled, uint256 ammFilled) =
            router.buyYes(MARKET_ID, usdcIn, 0, alice, 5, _deadline(), BUILDER);
        assertEq(clobFilled, 0, "clob 0");
        assertEq(ammFilled, 1782e5, "amm filled gross");
        assertEq(yesOut, 1782e5, "yes delivered");
        assertEq(exchange.accruedBuilder(BUILDER), 1e6, "1% of 100 USDC builder fee forwarded");
        assertEq(usdc.balanceOf(address(router)), 0, "canary");
    }

    // sellYes builder 100bps: carve 1% from ammGross 50 = 0.5; net 49.5.
    function test_sellYes_ammLeg_builderFee_carvedFromGross() public {
        uint256 yesIn = 100e6;
        builderRegistry.setBuilder(BUILDER, 100, 0, address(0xB111D));
        _queueSellSwap(int128(100e6), int128(50e6)); // 100 YES → 50 USDC gross
        yes1.mint(alice, yesIn);
        vm.prank(alice);
        yes1.approve(address(router), yesIn);
        vm.prank(alice);
        (uint256 usdcOut,, uint256 ammFilled) = router.sellYes(MARKET_ID, yesIn, 0, alice, 5, _deadline(), BUILDER);
        assertEq(ammFilled, 495e5, "net = gross 50 - 0.5 builder");
        assertEq(usdcOut, 495e5, "net usdc out");
        assertEq(exchange.accruedBuilder(BUILDER), 5e5, "0.5 USDC builder fee forwarded");
        assertEq(usdc.balanceOf(address(router)), 0, "canary");
    }

    function test_buyYes_ammLeg_noBuilder_noFee() public {
        uint256 usdcIn = 100e6;
        _queueBuySwap(int128(100e6), int128(180e6));
        _approveUsdcAsAlice(usdcIn);
        vm.prank(alice);
        router.buyYes(MARKET_ID, usdcIn, 0, alice, 5, _deadline(), bytes32(0));
        assertEq(exchange.accruedBuilder(bytes32(0)), 0, "no fee for builder 0");
        assertEq(usdc.balanceOf(address(router)), 0, "canary");
    }

    // ===== Task 4: AMM-leg protocol fee (buyYes / sellYes) =====

    // sellYes coef 700, no builder: carve protocol fee from gross. p = 50/100 = 0.5; F = curve(100,700,0.5) = 1.75.
    function test_sellYes_ammLeg_protocolFee_carvedFromGross() public {
        uint256 yesIn = 100e6;
        diamond.setProtocolFeeRate(MARKET_ID, 700);
        _queueSellSwap(int128(100e6), int128(50e6));
        yes1.mint(alice, yesIn);
        vm.prank(alice);
        yes1.approve(address(router), yesIn);
        vm.prank(alice);
        (uint256 usdcOut,, uint256 ammFilled) = router.sellYes(MARKET_ID, yesIn, 0, alice, 5, _deadline(), bytes32(0));
        uint256 expFee = router.exposed_curveFee(100e6, 700, 500_000);
        assertEq(ammFilled, 50e6 - expFee, "net = gross - protocol fee");
        assertEq(usdcOut, 50e6 - expFee, "net usdc out");
        assertEq(exchange.accruedProtocol(), expFee, "protocol fee forwarded");
        assertEq(usdc.balanceOf(address(router)), 0, "canary");
    }

    function test_buyYes_ammLeg_zeroCoef_noProtocolFee() public {
        uint256 usdcIn = 100e6;
        _queueBuySwap(int128(100e6), int128(180e6));
        _approveUsdcAsAlice(usdcIn);
        vm.prank(alice);
        router.buyYes(MARKET_ID, usdcIn, 0, alice, 5, _deadline(), bytes32(0));
        assertEq(exchange.accruedProtocol(), 0, "coef 0 => no protocol fee");
    }

    function _approveNoAsAlice(uint256 amount) internal {
        no1.mint(alice, amount);
        vm.prank(alice);
        no1.approve(address(router), amount);
    }

    // ===== Task 6: sellNo combined fee (carve both from gross) =====

    function _queueSellNo(uint256 noIn, uint256 costQuote) internal {
        quoter.setExactOutResult((costQuote * 1e6) / noIn); // per-1e6-YES cost rate
        if (address(usdc) < address(yes1)) {
            poolManager.queueSwapResult(-int128(uint128(costQuote)), int128(uint128(noIn)));
        } else {
            poolManager.queueSwapResult(int128(uint128(noIn)), -int128(uint128(costQuote)));
        }
    }

    function test_sellNo_ammLeg_combinedFee_carvedFromGross() public {
        uint256 noIn = 100e6;
        builderRegistry.setBuilder(BUILDER, 100, 0, address(0xB111D));
        diamond.setProtocolFeeRate(MARKET_ID, 700);
        _queueSellNo(noIn, 50e6); // ammGross = 100 - 50 = 50
        _approveNoAsAlice(noIn);
        vm.prank(alice);
        (uint256 usdcOut,, uint256 ammFilled) = router.sellNo(MARKET_ID, noIn, 0, alice, 5, _deadline(), BUILDER);
        uint256 expProto = router.exposed_curveFee(100e6, 700, 500_000); // p = 50/100 = 0.5 → 1.75
        assertEq(ammFilled, 50e6 - 5e5 - expProto, "net = gross - builder(0.5) - protocol");
        assertEq(usdcOut, 50e6 - 5e5 - expProto, "net usdc");
        assertEq(exchange.accruedBuilder(BUILDER), 5e5, "builder 0.5 forwarded");
        assertEq(exchange.accruedProtocol(), expProto, "protocol fee forwarded");
        assertEq(usdc.balanceOf(address(router)), 0, "canary");
    }

    function test_sellNo_noFees_byteIdentical() public {
        uint256 noIn = 100e6;
        _queueSellNo(noIn, 50e6);
        _approveNoAsAlice(noIn);
        vm.prank(alice);
        (uint256 usdcOut,, uint256 ammFilled) = router.sellNo(MARKET_ID, noIn, 0, alice, 5, _deadline(), bytes32(0));
        assertEq(usdcOut, noIn - 50e6, "P10: gross unchanged");
        assertEq(ammFilled, noIn - 50e6);
        assertEq(exchange.accruedProtocol(), 0, "no protocol fee");
        assertEq(exchange.accruedBuilder(bytes32(0)), 0, "no builder fee");
    }

    // buyYes coef 700, no builder: reserve at p=0.5 (quoter), recompute on realized fill, forward, refund surplus.
    function test_buyYes_ammLeg_protocolFee_reserveThenRecompute() public {
        uint256 usdcIn = 100e6;
        diamond.setProtocolFeeRate(MARKET_ID, 700);
        // quoter canned is PER-1e6-input (scaled): 2e6 ⇒ 2 YES per USDC ⇒ effective p=0.5. For 100 USDC the
        // reserve estimate = 200 YES ⇒ reserve = curve(200,700,0.5) = 3.5.
        quoter.setExactInResult(address(usdc) < address(yes1), 2e6);
        // ammSpend = 100 - 0 - 3.5 = 96.5. Pin the realized swap to p=0.5 ⇒ 193 YES out.
        _queueBuySwap(int128(965e5), int128(193e6));
        _approveUsdcAsAlice(usdcIn);
        vm.prank(alice);
        (, uint256 clobFilled, uint256 ammFilled) =
            router.buyYes(MARKET_ID, usdcIn, 0, alice, 5, _deadline(), bytes32(0));
        assertEq(clobFilled, 0, "clob 0");
        assertEq(ammFilled, 193e6, "gross YES (protocol fee is USDC-side)");
        uint256 expFee = router.exposed_curveFee(193e6, 700, 500_000); // realized p=0.5
        assertEq(exchange.accruedProtocol(), expFee, "recomputed protocol fee forwarded");
        assertLe(expFee, router.exposed_curveFee(200e6, 700, 500_000), "recomputed <= reserve");
        assertEq(usdc.balanceOf(address(router)), 0, "canary - over-reserve refunded");
    }

    // ===== Task 5: buyNo combined fee + balance-delta p =====

    // Proportional quoters: sell YES @0.5 (mintAmount sizing) + buy YES effective 0.5 (reserve estimate),
    // so _computeBuyNoMintAmount + _reserveProtocolFee are deterministic. mintAmount = ammSpend*2 cushioned.
    function _setBuyNoQuoters() internal {
        quoter.setExactInResult(address(yes1) < address(usdc), 500_000); // sell: 0.5 USDC per 1e6 YES
        quoter.setExactInResult(address(usdc) < address(yes1), 2e6); // buy: 2 YES per 1e6 USDC (effective 0.5)
    }

    function _mintFor(uint256 ammSpend) internal pure returns (uint256) {
        return ((ammSpend * 2) * 9950) / 10_000; // size = ammSpend/0.5; × BUY_NO_PRECISION_CUSHION_BPS
    }

    function _queueYesSell(uint256 mintAmount) internal {
        uint256 proceeds = mintAmount / 2; // spot 0.5
        if (address(yes1) < address(usdc)) {
            poolManager.queueSwapResult(-int128(uint128(mintAmount)), int128(uint128(proceeds)));
        } else {
            poolManager.queueSwapResult(int128(uint128(proceeds)), -int128(uint128(mintAmount)));
        }
    }

    // builder 100bps, coef 0: builder fee on the full usdcRemaining; NO out is gross; balance-delta p; no strand.
    function test_buyNo_ammLeg_builderFee_balanceDeltaP() public {
        uint256 usdcIn = 100e6;
        builderRegistry.setBuilder(BUILDER, 100, 0, address(0xB111D));
        _setBuyNoQuoters();
        uint256 mint = _mintFor(usdcIn - (usdcIn * 100) / 10_000); // ammSpend = 99 (no reserve at coef 0)
        _queueYesSell(mint);
        _approveUsdcAsAlice(usdcIn);
        vm.prank(alice);
        (uint256 noOut,, uint256 ammFilled) = router.buyNo(MARKET_ID, usdcIn, 0, alice, 5, _deadline(), BUILDER);
        assertEq(ammFilled, mint, "amm filled = mintAmount");
        assertEq(noOut, ammFilled, "net NO = gross (fee paid in USDC)");
        assertEq(exchange.accruedBuilder(BUILDER), 1e6, "builder fee on full usdcRemaining (100)");
        assertEq(exchange.accruedProtocol(), 0, "coef 0 => no protocol fee");
        assertEq(usdc.balanceOf(address(router)), 0, "canary - no strand");
    }

    // coef 700, no builder: reserve at p=0.5 holds room; protocol fee = curve(mint, 700, balance-delta p=0.5).
    function test_buyNo_ammLeg_protocolFee_balanceDeltaP() public {
        uint256 usdcIn = 100e6;
        diamond.setProtocolFeeRate(MARKET_ID, 700);
        _setBuyNoQuoters();
        uint256 reserve = router.exposed_curveFee(200e6, 700, 500_000); // yesEst 200 @0.5 = 3.5
        uint256 mint = _mintFor(usdcIn - reserve);
        _queueYesSell(mint);
        _approveUsdcAsAlice(usdcIn);
        vm.prank(alice);
        (uint256 noOut,, uint256 ammFilled) = router.buyNo(MARKET_ID, usdcIn, 0, alice, 5, _deadline(), bytes32(0));
        assertEq(ammFilled, mint, "amm filled");
        assertEq(noOut, ammFilled, "net NO = gross");
        assertEq(exchange.accruedProtocol(), router.exposed_curveFee(mint, 700, 500_000), "protocol fee (p=0.5)");
        assertEq(usdc.balanceOf(address(router)), 0, "canary - reserve surplus refunded");
    }

    function test_buyNo_noFees_byteIdentical() public {
        uint256 usdcIn = 100e6;
        _setBuyNoQuoters();
        uint256 mint = _mintFor(usdcIn);
        _queueYesSell(mint);
        _approveUsdcAsAlice(usdcIn);
        vm.prank(alice);
        (uint256 noOut,, uint256 ammFilled) = router.buyNo(MARKET_ID, usdcIn, 0, alice, 5, _deadline(), bytes32(0));
        assertEq(ammFilled, mint, "P10: full mint");
        assertEq(noOut, ammFilled);
        assertEq(exchange.accruedProtocol(), 0, "no protocol fee");
        assertEq(exchange.accruedBuilder(bytes32(0)), 0, "no builder fee");
    }

    // ===== Task 7: no-strand / no-double-charge guards (buyYes path) =====

    // No pool → AMM leg skipped → no AMM fee, CLOB-only, canary holds.
    function test_buyYes_noPool_clobOnly_noAmmFee() public {
        uint256 usdcIn = 100e6;
        builderRegistry.setBuilder(BUILDER, 100, 0, address(0xB111D));
        diamond.setProtocolFeeRate(MARKET_ID, 700);
        _setPoolLiquidity(address(yes1), 0); // no AMM
        exchange.setResult(MARKET_ID, IPrediXExchangeView.Side.BUY_YES, 200e6, usdcIn);
        _approveUsdcAsAlice(usdcIn);
        vm.prank(alice);
        (uint256 yesOut, uint256 clobFilled, uint256 ammFilled) =
            router.buyYes(MARKET_ID, usdcIn, 0, alice, 5, _deadline(), BUILDER);
        assertEq(ammFilled, 0, "no amm");
        assertEq(clobFilled, 200e6, "all clob");
        assertEq(yesOut, 200e6, "no AMM fee deducted (CLOB fee is in-exchange)");
        assertEq(exchange.accruedBuilder(BUILDER), 0, "no AMM builder fee");
        assertEq(exchange.accruedProtocol(), 0, "no AMM protocol fee");
    }

    // usdcRemaining == 0 (CLOB took everything) → AMM skipped → no AMM fee.
    function test_buyYes_clobTakesAll_noAmmFee() public {
        uint256 usdcIn = 100e6;
        builderRegistry.setBuilder(BUILDER, 100, 0, address(0xB111D));
        exchange.setResult(MARKET_ID, IPrediXExchangeView.Side.BUY_YES, 200e6, usdcIn); // cost == usdcIn
        _approveUsdcAsAlice(usdcIn);
        vm.prank(alice);
        router.buyYes(MARKET_ID, usdcIn, 0, alice, 5, _deadline(), BUILDER);
        assertEq(exchange.accruedBuilder(BUILDER), 0, "no AMM fee when usdcRemaining==0");
    }

    // No double-charge: split fill. AMM builder fee is on the AMM input (40) ONLY; CLOB leg charged in-exchange.
    function test_buyYes_split_ammFeeOnAmmFilledOnly() public {
        uint256 usdcIn = 100e6;
        builderRegistry.setBuilder(BUILDER, 100, 0, address(0xB111D));
        exchange.setResult(MARKET_ID, IPrediXExchangeView.Side.BUY_YES, 120e6, 60e6); // CLOB takes 60
        _queueBuySwap(int128(396e5), int128(72e6)); // AMM input 40 - 0.4 builder = 39.6
        _approveUsdcAsAlice(usdcIn);
        vm.prank(alice);
        router.buyYes(MARKET_ID, usdcIn, 0, alice, 5, _deadline(), BUILDER);
        assertEq(exchange.accruedBuilder(BUILDER), (40e6 * 100) / 10_000, "AMM builder fee on AMM input (40) only");
        assertEq(exchange.lastTakerBuilder(), BUILDER, "CLOB leg got builder (charged in-exchange)");
    }
}
