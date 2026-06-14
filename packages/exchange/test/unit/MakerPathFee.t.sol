// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import {IPrediXExchange} from "../../src/IPrediXExchange.sol";
import {Roles} from "@predix/shared/constants/Roles.sol";
import {ExchangeTestBase} from "../base/ExchangeTestBase.sol";
import {MockBuilderRegistry} from "../mocks/MockBuilderRegistry.sol";

/// @notice Maker-path fee PREFUND + REFUND lifecycle (Task 8 part 1). Asserts via observable USDC balance
///         deltas + accrued getters (the fee budgets live in ERC-7201 storage with no getter). Also proves
///         the resting-maker builder fee (wired in Task 7, dormant) activates once the prefund snapshots
///         orderMakerBps + makerFeeLocked. The maker-vs-maker fee CHARGING (placer protocol fee on
///         placeOrder crosses) is Task 8 part 2 — here the placer's reserve round-trips via the refund sites.
abstract contract MakerFeeBase is ExchangeTestBase {
    MockBuilderRegistry internal registry;
    address internal maker = makeAddr("makerFee");
    address internal taker = makeAddr("takerFee2");
    address internal mRecipient = makeAddr("mRecipient");
    address internal treasury = makeAddr("protoTreasury2");
    bytes32 internal constant MCODE = keccak256("maker-builder");

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

    function _placeBuyYesB(address owner_, uint256 price, uint256 amount, bytes32 builder)
        internal
        returns (bytes32 id)
    {
        _giveUsdc(owner_, 1000e6);
        vm.prank(owner_);
        (id,) = exchange.placeOrder(MARKET_ID, IPrediXExchange.Side.BUY_YES, price, amount, builder);
    }

    function _placeSellYesB(address owner_, uint256 price, uint256 amount, bytes32 builder)
        internal
        returns (bytes32 id)
    {
        _giveYesNo(owner_, amount);
        vm.prank(owner_);
        (id,) = exchange.placeOrder(MARKET_ID, IPrediXExchange.Side.SELL_YES, price, amount, builder);
    }
}

contract MakerPathPrefundTest is MakerFeeBase {
    // BUY_YES @0.50 100sh: deposit 50, makerFeeLocked = 50*0.5% = 0.25, protocolBudget = curve(1e8,700,500000) = 1.75.
    function test_placeOrder_BUY_prefunds_bothBudgets() public {
        registry.set(MCODE, 0, 50, mRecipient); // makerBps = 50
        _enableProtocol(700, 0);
        uint256 exBefore = _usdcBalance(address(exchange));
        _placeBuyYesB(maker, 500_000, 1e8, MCODE); // empty book → rests
        assertEq(
            _usdcBalance(address(exchange)) - exBefore,
            50e6 + 250_000 + 1_750_000,
            "pulled deposit + makerFeeLocked + placerProtocolBudget"
        );
    }

    function test_placeOrder_SELL_noPrefund() public {
        registry.set(MCODE, 0, 50, mRecipient);
        _enableProtocol(700, 0);
        uint256 exBefore = _usdcBalance(address(exchange));
        _placeSellYesB(maker, 500_000, 1e8, MCODE); // SELL: token deposit only
        assertEq(_usdcBalance(address(exchange)) - exBefore, 0, "SELL pulls no USDC prefund");
    }

    function test_P10_maker_byteIdentical() public {
        // no builder + coef 0 ⇒ feeActive false ⇒ no prefund pull, no storage writes
        _giveUsdc(maker, 1000e6);
        uint256 exBefore = _usdcBalance(address(exchange));
        vm.prank(maker);
        exchange.placeOrder(MARKET_ID, IPrediXExchange.Side.BUY_YES, 500_000, 1e8, bytes32(0));
        assertEq(_usdcBalance(address(exchange)) - exBefore, 50e6, "deposit only, no fee prefund");
    }
}

contract MakerPathRefundTest is MakerFeeBase {
    // Refund SITE-2: cancelling a resting BUY returns deposit + BOTH fee budgets to the owner.
    function test_refund_site2_cancel_returnsBothBudgets() public {
        registry.set(MCODE, 0, 50, mRecipient);
        _enableProtocol(700, 0);
        _giveUsdc(maker, 1000e6);
        uint256 mBefore = _usdcBalance(maker);
        vm.prank(maker);
        (bytes32 id,) = exchange.placeOrder(MARKET_ID, IPrediXExchange.Side.BUY_YES, 500_000, 1e8, MCODE);
        assertEq(mBefore - _usdcBalance(maker), 52_000_000, "pulled deposit + both budgets");
        vm.prank(maker);
        exchange.cancelOrder(id);
        assertEq(_usdcBalance(maker), mBefore, "cancel refunds deposit + both fee budgets fully");
    }

    // Refund SITE-3 with price improvement: a BUY placer @0.50 crossing a cheaper SELL maker @0.30 consumes
    // F(@0.30) < reserve(@0.50), so the unused reserve residual is refunded to the OWNER (3b + SITE-3).
    function test_refund_site3_priceImprovement_refundsReserveResidual() public {
        registry.set(MCODE, 0, 0, mRecipient); // placer no builder (isolate the protocol reserve refund)
        _enableProtocol(700, 0);
        _placeSellYes(bob, 300_000, 1e8); // resting SELL maker @0.30, no builder
        _giveUsdc(maker, 1000e6);
        uint256 mBefore = _usdcBalance(maker);
        vm.prank(maker);
        (, uint256 filled) = exchange.placeOrder(MARKET_ID, IPrediXExchange.Side.BUY_YES, 500_000, 1e8, MCODE);
        assertEq(filled, 1e8, "fully crossed");
        // notional @0.30 = 30; F @0.30 = curve(1e8,700,300000) = 1.47; reserve @0.50 = 1.75 → residual 0.28 refunded
        assertEq(exchange.accruedProtocolFee(), 1_470_000, "T = F(@0.30), rebate 0");
        assertEq(mBefore - _usdcBalance(maker), 30e6 + 1_470_000, "notional + F charged; reserve residual refunded");
        assertEq(_yesBalance(maker), 1e8, "received YES shares");
    }
}

contract MakerVsMakerCompFeeTest is MakerFeeBase {
    // 3b COMP, placer BUY vs resting SELL maker. Placer pays F (from reserve) + its builder fee; resting
    // maker (SELL, no builder) gets gross USDC; treasury accrues T. Full conservation at @0.50 (reserve exact).
    function test_comp_placerBuy_makerSell_conservation() public {
        registry.set(MCODE, 0, 50, mRecipient); // placer builder makerBps 50
        _enableProtocol(700, 0);
        _placeSellYes(bob, 500_000, 1e8); // resting SELL maker, no builder
        uint256 bobBefore = _usdcBalance(bob);
        _giveUsdc(maker, 1000e6);
        uint256 mBefore = _usdcBalance(maker);
        vm.prank(maker);
        exchange.placeOrder(MARKET_ID, IPrediXExchange.Side.BUY_YES, 500_000, 1e8, MCODE);
        // placer pays: notional 50 + F 1.75 (reserve) + builder 0.25 (makerFeeLocked) = 52
        assertEq(mBefore - _usdcBalance(maker), 52e6, "placer spent notional + F + builder");
        assertEq(_usdcBalance(bob) - bobBefore, 50e6, "SELL maker (no builder) gets gross notional");
        assertEq(exchange.accruedProtocolFee(), 1_750_000, "T = F (rebate 0)");
        assertEq(exchange.accruedBuilderFee(MCODE), 250_000, "placer builder fee at makerBps");
        assertEq(_yesBalance(maker), 1e8, "placer received shares");
    }

    // 3b COMP, placer SELL vs resting BUY maker, with rebate. Maker (BUY) receives R via a NEW USDC transfer;
    // placer (SELL) payout reduced by F. R + T == F.
    function test_comp_placerSell_makerBuy_rebate() public {
        // bob places BUY BEFORE protocol is on ⇒ no reserve prefund ⇒ isolates the rebate transfer (no
        // SITE-1 reserve refund to conflate the delta when bob is fully filled).
        _placeBuyYes(bob, 500_000, 1e8); // deposit 50 only (coef 0 at placement)
        _enableProtocol(700, 2000); // now coef 700, rebate 20% for the cross
        uint256 bobBefore = _usdcBalance(bob);
        _giveYesNo(maker, 1e8);
        uint256 mBefore = _usdcBalance(maker);
        vm.prank(maker);
        exchange.placeOrder(MARKET_ID, IPrediXExchange.Side.SELL_YES, 500_000, 1e8, bytes32(0));
        // F = curve(1e8,700,500000) = 1.75; R = 0.35; T = 1.40. placer SELL net = 50 - 1.75 = 48.25.
        assertEq(_usdcBalance(maker) - mBefore, 50e6 - 1_750_000, "placer SELL payout net of F");
        assertEq(_usdcBalance(bob) - bobBefore, 350_000, "resting BUY maker receives R (new transfer)");
        assertEq(exchange.accruedProtocolFee(), 1_400_000, "T = F - R");
        assertEq(_yesBalance(bob), 1e8, "maker received shares");
    }

    function test_comp_P10_makerVsMaker_byteIdentical() public {
        // coef 0 + no builders ⇒ feeActive false ⇒ no fee, gross transfers
        _placeSellYes(bob, 500_000, 1e8);
        uint256 bobBefore = _usdcBalance(bob);
        _giveUsdc(maker, 1000e6);
        uint256 mBefore = _usdcBalance(maker);
        vm.prank(maker);
        exchange.placeOrder(MARKET_ID, IPrediXExchange.Side.BUY_YES, 500_000, 1e8, bytes32(0));
        assertEq(mBefore - _usdcBalance(maker), 50e6, "only notional");
        assertEq(_usdcBalance(bob) - bobBefore, 50e6, "maker gross");
        assertEq(exchange.accruedProtocolFee(), 0);
    }

    // Refund SITE-1: a resting BUY fully filled by a taker refunds the unused protocol reserve (the maker
    // is the resting side, not the aggressor, so its placerProtocolFeeBudget is never consumed).
    function test_refund_site1_fullyFilled_refundsReserve() public {
        registry.set(MCODE, 0, 50, mRecipient);
        _enableProtocol(700, 0);
        _giveUsdc(maker, 1000e6);
        uint256 mBefore = _usdcBalance(maker);
        _placeBuyYesB2(maker); // BUY_YES @0.50 100sh with MCODE — rests, prefunds 52e6
        // taker SELL fills the whole maker order
        _giveYesNo(taker, 1e8);
        vm.prank(taker);
        exchange.fillMarketOrder(
            MARKET_ID, IPrediXExchange.Side.SELL_YES, 1, 1e8, taker, taker, 0, _deadline(), bytes32(0)
        );
        // maker bought 100sh for 50; makerFeeLocked(0.25) consumed by resting-maker builder fee; reserve(1.75) refunded
        assertEq(_yesBalance(maker), 1e8, "maker received shares");
        // net spent = deposit(50) + consumed builder fee(0.25); reserve(1.75) came back
        assertEq(mBefore - _usdcBalance(maker), 50e6 + 250_000, "reserve refunded; only deposit + builder fee spent");
    }

    function _placeBuyYesB2(address owner_) internal {
        vm.prank(owner_);
        exchange.placeOrder(MARKET_ID, IPrediXExchange.Side.BUY_YES, 500_000, 1e8, MCODE);
    }
}

contract MakerRestingBuilderFeeTest is MakerFeeBase {
    // Proves the resting-maker builder fee (Task 7, gated by feeActive) is now ACTIVE because the Task-8
    // prefund snapshots orderMakerBps + makerFeeLocked. Was dormant (0) before this task.
    function test_restingMakerBuilderFee_nowActive_onTakerFill() public {
        registry.set(MCODE, 0, 50, mRecipient);
        _enableProtocol(700, 0); // coef>0 ⇒ taker feeActive even with no taker builder
        _placeBuyYesB(maker, 500_000, 1e8, MCODE); // rests; prefunds makerFeeLocked = 0.25
        _giveYesNo(taker, 1e8);
        vm.prank(taker);
        exchange.fillMarketOrder(
            MARKET_ID, IPrediXExchange.Side.SELL_YES, 1, 1e8, taker, taker, 0, _deadline(), bytes32(0)
        );
        // resting-maker builder fee = _feeOn(taker USDC 50, makerBps 50) = 0.25, charged from makerFeeLocked
        assertEq(exchange.accruedBuilderFee(MCODE), 250_000, "resting-maker builder fee active via prefund");
    }
}
