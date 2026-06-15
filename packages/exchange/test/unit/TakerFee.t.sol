// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import {Vm} from "forge-std/Vm.sol";
import {IPrediXExchange} from "../../src/IPrediXExchange.sol";
import {Roles} from "@predix/shared/constants/Roles.sol";
import {ExchangeTestBase} from "../base/ExchangeTestBase.sol";
import {MockBuilderRegistry} from "../mocks/MockBuilderRegistry.sol";

/// @notice Shared rig for taker-fee tests: protocol-rate seeding + a builder registry + a fill helper.
abstract contract TakerFeeBase is ExchangeTestBase {
    MockBuilderRegistry internal registry;
    address internal taker = makeAddr("takerFee");
    address internal builderRecipient = makeAddr("builderRecipient");
    address internal treasury = makeAddr("protoTreasury");
    bytes32 internal constant TCODE = keccak256("taker-builder");

    function setUp() public virtual override {
        super.setUp();
        diamond.grantRole(Roles.ADMIN_ROLE, address(this));
        registry = new MockBuilderRegistry();
        exchange.setBuilderRegistry(address(registry));
        exchange.setProtocolFeeRecipient(treasury);
    }

    function _enableProtocol(uint16 coef, uint16 rebate) internal {
        diamond.setProtocolFee(MARKET_ID, coef, rebate);
    }

    function _setTakerBuilder(uint16 takerBps) internal {
        registry.set(TCODE, takerBps, 0, builderRecipient);
    }

    function _fillBuyYes(uint256 limit, uint256 amountIn, bytes32 builder) internal returns (uint256 f, uint256 c) {
        _giveUsdc(taker, amountIn);
        vm.prank(taker);
        (f, c) = exchange.fillMarketOrder(
            MARKET_ID, IPrediXExchange.Side.BUY_YES, limit, amountIn, taker, taker, 0, _deadline(), builder
        );
    }

    function _fillSellYes(uint256 limit, uint256 shares, bytes32 builder) internal returns (uint256 f, uint256 c) {
        _giveYesNo(taker, shares);
        vm.prank(taker);
        (f, c) = exchange.fillMarketOrder(
            MARKET_ID, IPrediXExchange.Side.SELL_YES, limit, shares, taker, taker, 0, _deadline(), builder
        );
    }
}

contract TakerFeeBuyTest is TakerFeeBase {
    // 100 shares @ 0.50, coef 700 ⇒ F = 1e8*700*5e5*5e5/1e16 = 1.75 USDC.
    function test_takerBuy_protocolOnly_perFill() public {
        _placeSellYes(bob, 500_000, 1e8);
        _enableProtocol(700, 0);
        (, uint256 cost) = _fillBuyYes(500_000, 100e6, bytes32(0));
        assertEq(cost, 50e6 + 1_750_000, "cost = notional + F");
        assertEq(exchange.accruedProtocolFee(), 1_750_000, "T accrued (rebate 0)");
    }

    // ProtocolFeeCharged fields verified via recordLogs (event ordering in a multi-transfer fill is fragile).
    function test_ProtocolFeeCharged_fields() public {
        bytes32 oid = _placeSellYes(bob, 500_000, 1e8);
        _enableProtocol(700, 2000); // F=1.75, R=0.35, T=1.40
        vm.recordLogs();
        _fillBuyYes(500_000, 100e6, bytes32(0));
        Vm.Log[] memory logs = vm.getRecordedLogs();
        bytes32 sig = keccak256(
            "ProtocolFeeCharged(uint256,address,address,bytes32,uint256,uint256,uint256,uint256,uint8,bytes32,bytes32)"
        );
        bool found;
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].topics[0] != sig) continue;
            found = true;
            assertEq(uint256(logs[i].topics[1]), MARKET_ID, "marketId");
            (
                address t,
                address m,
                bytes32 mid,
                uint256 fee,
                uint256 reb,
                uint256 tre,
                uint256 p,
                uint8 mt,
                bytes32 tb,
                bytes32 mb
            ) = abi.decode(
                logs[i].data, (address, address, bytes32, uint256, uint256, uint256, uint256, uint8, bytes32, bytes32)
            );
            assertEq(t, taker, "taker");
            assertEq(m, bob, "maker");
            assertEq(fee, 1_750_000, "F");
            assertEq(reb, 350_000, "R");
            assertEq(tre, 1_400_000, "T");
            assertEq(p, 500_000, "p");
            assertEq(mt, 0, "matchType COMP");
            assertEq(tb, bytes32(0), "takerBuilder");
            assertEq(mb, bytes32(0), "makerBuilder");
            assertEq(mid, oid, "makerOrderId = the resting maker order");
        }
        assertTrue(found, "ProtocolFeeCharged emitted");
    }

    function test_takerBuy_builderOnly_costFolded() public {
        _placeSellYes(bob, 500_000, 1e8);
        _setTakerBuilder(100); // 1%
        (, uint256 cost) = _fillBuyYes(500_000, 100e6, TCODE);
        uint256 builderFee = (50e6 * 100) / 10_000; // 0.5 USDC
        assertEq(cost, 50e6 + builderFee, "cost = notional + builder fee");
        assertEq(exchange.accruedBuilderFee(TCODE), builderFee);
        assertEq(exchange.accruedProtocolFee(), 0);
    }

    function test_takerBuy_bothLayers_additive() public {
        _placeSellYes(bob, 500_000, 1e8);
        _enableProtocol(700, 0);
        _setTakerBuilder(100);
        (, uint256 cost) = _fillBuyYes(500_000, 100e6, TCODE);
        assertEq(cost, 50e6 + 1_750_000 + (50e6 * 100) / 10_000, "cost = notional + protocol + builder");
    }

    // amountIn sized so the fee would overflow it: notional+fee for 100sh = 51.75; give only 51.0.
    function test_takerBuy_marginalClamp_neverOverspends() public {
        _placeSellYes(bob, 500_000, 1e8);
        _enableProtocol(700, 0);
        uint256 amountIn = 51e6; // < 51.75 needed for the full 100 shares
        (uint256 filled, uint256 cost) = _fillBuyYes(500_000, amountIn, bytes32(0));
        assertLe(cost, amountIn, "never overspends amountIn");
        // F3-1 TIGHTNESS (executed, not just commented): cost(s) = s/2 + s*1.75% ⇒ s*0.5175. The MAX s with
        // cost ≤ 51e6 is ≈ 98.55e6, so the clamp must land in (98e6, 99e6) — NOT clamp-to-0 and NOT overfill —
        // and the budget must be all but exhausted (leftover < one share's marginal cost ≈ 0.5175 USDC).
        assertGt(filled, 98e6, "clamp filled ~max affordable (not clamp-to-0)");
        assertLt(filled, 99e6, "clamp did not overfill past the affordable max");
        assertLt(amountIn - cost, 520_000, "leftover < one more share marginal cost: clamp is tight");
    }

    function test_takerBuy_P10_byteIdentical() public {
        _placeSellYes(bob, 500_000, 1e8);
        // coef 0 + no builder ⇒ feeActive false
        (, uint256 cost) = _fillBuyYes(500_000, 100e6, bytes32(0));
        assertEq(cost, 50e6, "cost == notional exactly");
        assertEq(exchange.accruedProtocolFee(), 0);
        assertEq(exchange.accruedBuilderFee(bytes32(0)), 0);
    }
}

contract TakerFeeSellTest is TakerFeeBase {
    // §13 concavity proof: BUY makers @0.20 + @0.80, taker SELL 200sh, coef 700 ⇒ ΣF = 1.12 + 1.12 = 2.24.
    function test_takerSell_protocol_perFill_2fillProof() public {
        _placeBuyYes(bob, 200_000, 1e8); // 100sh @0.20
        _placeBuyYes(carol, 800_000, 1e8); // 100sh @0.80
        _enableProtocol(700, 0);
        uint256 takerBefore = _usdcBalance(taker);
        _fillSellYes(1, 2e8, bytes32(0)); // limit 1 = accept any; sell 200 shares
        // gross proceeds = 20 + 80 = 100 USDC; net = 100 - 2.24
        assertEq(exchange.accruedProtocolFee(), 2_240_000, "per-fill concave SigmaF (NOT aggregate 3.5)");
        assertEq(_usdcBalance(taker) - takerBefore, 100e6 - 2_240_000, "usdcOut reduced by SigmaF");
    }

    function test_takerSell_builderOnly_perFill() public {
        _placeBuyYes(bob, 500_000, 1e8); // 100sh @0.50 ⇒ taker gets 50 USDC
        _setTakerBuilder(100);
        uint256 takerBefore = _usdcBalance(taker);
        _fillSellYes(1, 1e8, TCODE);
        uint256 builderFee = (50e6 * 100) / 10_000; // 0.5 USDC on the 50 received
        assertEq(exchange.accruedBuilderFee(TCODE), builderFee);
        assertEq(_usdcBalance(taker) - takerBefore, 50e6 - builderFee, "net = gross - builder fee");
    }

    function test_takerSell_P10_byteIdentical() public {
        _placeBuyYes(bob, 500_000, 1e8);
        uint256 takerBefore = _usdcBalance(taker);
        _fillSellYes(1, 1e8, bytes32(0));
        assertEq(_usdcBalance(taker) - takerBefore, 50e6, "gross == net (no fee)");
        assertEq(exchange.accruedProtocolFee(), 0);
    }
}

contract TakerFeeMintMergeTest is TakerFeeBase {
    // MINT: taker BUY_YES crosses a resting BUY_NO maker synthetically. p = 1e6 - makerPrice.
    // maker BUY_NO @0.30 ⇒ taker pays inDelta = 100sh*0.70 = 70 USDC; F = curve(1e8,700,700000)=1.47.
    function test_takerBuy_MINT_protocolFee_perFill() public {
        _placeBuyNo(bob, 300_000, 1e8);
        _enableProtocol(700, 0);
        (, uint256 cost) = _fillBuyYes(900_000, 100e6, bytes32(0));
        assertEq(exchange.accruedProtocolFee(), 1_470_000, "MINT F = curve(1e8,700,700000)");
        assertEq(cost, 70e6 + 1_470_000, "cost = inDelta(0.70) + F");
    }

    // MINT rebate: maker (BUY) gets R as a NEW caller-side USDC transfer.
    function test_takerBuy_MINT_rebate_callerSideTransfer() public {
        _placeBuyNo(bob, 300_000, 1e8);
        _enableProtocol(700, 2000); // R = 1.47*0.2 = 0.294
        uint256 makerBefore = _usdcBalance(bob);
        _fillBuyYes(900_000, 100e6, bytes32(0));
        assertEq(_usdcBalance(bob) - makerBefore, 294_000, "maker (BUY) receives R via new transfer");
        assertEq(exchange.accruedProtocolFee(), 1_470_000 - 294_000, "T = F - R");
    }

    // REGRESSION (review CRITICAL): SYN-MINT clamp must use the real inDelta basis (s - floor(s*makerPrice/1e6)),
    // not floor(s*(1e6-makerPrice)/1e6). A budget-exact MINT BUY at a gap price must NOT revert (no overspend).
    function test_takerBuy_MINT_marginalClamp_noRevert_gapPrice() public {
        _placeBuyNo(bob, 170_000, 1e8); // 0.17 — produces a 1-wei flooring gap on fractional fills
        _setTakerBuilder(11);
        _enableProtocol(251, 0);
        // tiny budget forces the clamp to a fractional-share marginal fill (where the 1-wei gap bites)
        (, uint256 cost) = _fillBuyYes(900_000, 237, TCODE);
        assertLe(cost, 237, "clamp never overspends amountIn (no panic 0x11 underflow)");
    }

    function testFuzz_takerBuy_MINT_clamp_neverOverspends(uint256 amountInRaw) public {
        _placeBuyNo(bob, 170_000, 1e9);
        _setTakerBuilder(11);
        _enableProtocol(251, 0);
        uint256 amountIn = bound(amountInRaw, 100, 50_000); // tiny budgets stress the marginal clamp
        (, uint256 cost) = _fillBuyYes(900_000, amountIn, TCODE);
        assertLe(cost, amountIn, "MINT clamp never overspends for any tiny budget");
    }

    // MERGE: taker SELL_YES crosses a resting SELL_NO maker synthetically. p = 1e6 - makerPrice.
    // maker SELL_NO @0.30 ⇒ taker USDC leg = 70 (1e8 - floor(1e8*0.30)); F = curve(1e8,700,700000) = 1.47.
    function test_takerSell_MERGE_protocolFee_perFill() public {
        _placeSellNo(bob, 300_000, 1e8);
        _enableProtocol(700, 0);
        uint256 takerBefore = _usdcBalance(taker);
        _fillSellYes(1, 1e8, bytes32(0)); // accept any price
        assertEq(exchange.accruedProtocolFee(), 1_470_000, "MERGE F = curve(1e8,700,700000)");
        // taker leg gross = 70 USDC; F skimmed from the TAKER leg only
        assertEq(_usdcBalance(taker) - takerBefore, 70e6 - 1_470_000, "taker net = leg - F (maker untouched)");
    }
}

contract TakerMakerRebateTest is TakerFeeBase {
    // taker BUY vs SELL maker; coef 700 rebate 2000 (20%). F=1.75, R=0.35, T=1.40. Maker (SELL) gets usdc + R.
    function test_comp_takerBuy_makerSell_rebate_R_inline() public {
        _placeSellYes(bob, 500_000, 1e8);
        _enableProtocol(700, 2000);
        uint256 makerBefore = _usdcBalance(bob);
        _fillBuyYes(500_000, 100e6, bytes32(0));
        assertEq(_usdcBalance(bob) - makerBefore, 50e6 + 350_000, "maker = usdcAmount + R");
        assertEq(exchange.accruedProtocolFee(), 1_400_000, "T = F - R");
    }

    // taker SELL vs BUY maker; maker otherwise gets only tokens — R is a NEW usdc transfer.
    function test_comp_takerSell_makerBuy_rebate_newUsdcTransfer() public {
        _placeBuyYes(bob, 500_000, 1e8);
        _enableProtocol(700, 2000);
        uint256 makerBefore = _usdcBalance(bob);
        _fillSellYes(1, 1e8, bytes32(0));
        // F on 100sh @0.50 = 1.75; R = 0.35
        assertEq(_usdcBalance(bob) - makerBefore, 350_000, "maker (BUY) receives exactly R in USDC");
        assertEq(exchange.accruedProtocolFee(), 1_400_000, "T = F - R");
    }

    function test_rebate_dust_F0_R0() public {
        _placeSellYes(bob, 500_000, 1e8);
        _enableProtocol(0, 2000); // coef 0 ⇒ F=0 ⇒ R=0; but feeActive only if builder... so off
        uint256 makerBefore = _usdcBalance(bob);
        _fillBuyYes(500_000, 100e6, bytes32(0));
        assertEq(_usdcBalance(bob) - makerBefore, 50e6, "no rebate when F==0");
        assertEq(exchange.accruedProtocolFee(), 0);
    }
}
