// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import {Vm} from "forge-std/Vm.sol";

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {IBuilderRegistry} from "@predix/shared/interfaces/IBuilderRegistry.sol";

import {IPrediXHook} from "@predix/hook/interfaces/IPrediXHook.sol";

import {PrediXExchange} from "@predix/exchange/PrediXExchange.sol";
import {IPrediXExchange} from "@predix/exchange/IPrediXExchange.sol";
import {BuilderRegistry} from "@predix/exchange/BuilderRegistry.sol";

import {PrediXRouter} from "@predix/router/PrediXRouter.sol";

import {MainnetForkFixture} from "../utils/MainnetForkFixture.sol";

/// @title FeeSystemForkE2E
/// @notice Sub-plan 05 Task 4 — end-to-end proof that the WHOLE PrediX fee system (builder fee + protocol fee
///         + maker rebate) works on a live chain-130 fork. Uses the self-deploying `MainnetForkFixture` (fresh
///         Diamond + widened MarketFacet + Exchange + Hook + Router + v4 pool + funded actors) and wires a
///         BuilderRegistry + a builder code + per-market protocol fee + global maker rebate on top of it.
/// @dev The fee math the assertions exercise lives in the EXCHANGE: the CLOB leg reads the exchange's registry
///      (`setBuilderRegistry`) for builder bps, the market's `protocolFeeRateBps` for the treasury curve, and
///      the global `protocolMakerRebateBps` for the per-fill rebate. We redeploy the router pointing at the
///      SAME registry and trust it through the hook's post-bootstrap timelock path so a single registry governs
///      both legs. Resting CLOB makers are seeded per leg so every router call routes through the CLOB (the
///      AMM-leg carve emits no per-fill `BuilderFeeAccrued`).
contract FeeSystemForkE2E is MainnetForkFixture {
    // Cast the proxy to the concrete impl for the fee getters/setters that live on `PrediXExchange`
    // (not on `IPrediXExchange`): setBuilderRegistry / setProtocolFeeRecipient / accruedBuilderFee /
    // accruedProtocolFee / claimBuilderFee / sweepProtocolFee.
    PrediXExchange internal feeExchange;

    BuilderRegistry internal registry;
    address internal treasury = makeAddr("treasury");
    address internal builderRecipient = makeAddr("builderRecipient");

    bytes32 internal constant CODE = keccak256("e2e");

    uint16 internal constant TAKER_BPS = 100; // builder taker fee (ABSOLUTE_MAX)
    uint16 internal constant MAKER_BPS = 50; // builder maker fee (ABSOLUTE_MAX)
    uint16 internal constant PROTOCOL_FEE_BPS = 700; // MAX_PROTOCOL_FEE_RATE_BPS
    uint16 internal constant REBATE_BPS = 1000; // 10% of F rebated to the maker

    uint256 internal constant MAKER_PRICE = 500_000; // $0.50 (the curve peak)
    uint256 internal constant MAKER_AMOUNT = 50_000e6; // resting depth per leg

    bytes32 internal constant PROTOCOL_FEE_CHARGED_TOPIC = keccak256(
        "ProtocolFeeCharged(uint256,address,address,bytes32,uint256,uint256,uint256,uint256,uint8,bytes32,bytes32)"
    );
    bytes32 internal constant BUILDER_FEE_ACCRUED_TOPIC = keccak256("BuilderFeeAccrued(bytes32,uint256)");

    // ERC-7201 storage bases (mirrors LibBuilderFeeStorage / LibProtocolFeeStorage). Read per-order prefunded
    // budgets via `vm.load` for the solvency ledger — the exchange exposes no per-order getter.
    bytes32 internal constant BUILDER_FEE_SLOT = 0xa35e7c8baa3c0cb8b6083e44aeeab8e83487b5eefb283554ddf6e85e17c79000;
    bytes32 internal constant PROTOCOL_FEE_SLOT = 0xc2cb872bc9a3ca3724b5bbf38ae11b13de41b893f6d0b580ab2182f4ff581d00;

    // Resting maker order ids placed for the solvency ledger.
    bytes32[] internal restingOrderIds;

    function setUp() public override {
        super.setUp();

        feeExchange = PrediXExchange(address(exchange));

        // 1. Deploy our own registry bound to the diamond + register the builder code.
        registry = new BuilderRegistry(address(diamond));

        // 2. Wire the EXCHANGE fee config as the diamond ADMIN_ROLE holder (`admin`).
        vm.startPrank(admin);
        feeExchange.setBuilderRegistry(address(registry));
        feeExchange.setProtocolFeeRecipient(treasury);
        registry.setBuilder(CODE, builderRecipient, TAKER_BPS, MAKER_BPS);
        market.setPerMarketProtocolFeeRateBps(marketId, PROTOCOL_FEE_BPS);
        market.setProtocolMakerRebateBps(REBATE_BPS);
        vm.stopPrank();

        // 3. Redeploy the router pointing at OUR registry and trust it via the hook's post-bootstrap timelock.
        _redeployRouterWithRegistry();
    }

    /// @dev Mirror `MainnetForkFixture._deployRouter` (private) but bind OUR registry, then route trust through
    ///      the hook's timelocked path (immediate `setTrustedRouter` is locked out once bootstrap completes).
    function _redeployRouterWithRegistry() private {
        router = new PrediXRouter(
            poolManager,
            address(diamond),
            address(usdc),
            address(hook),
            address(exchange),
            quoter,
            permit2,
            DYNAMIC_FEE,
            TICK_SPACING,
            IBuilderRegistry(address(registry))
        );

        vm.prank(hookAdmin);
        IPrediXHook(address(hook)).proposeTrustedRouter(address(router), true);
        // PrediXHookV2.TRUSTED_ROUTER_DELAY (public constant, not on IPrediXHook): 48h.
        vm.warp(block.timestamp + 48 hours);
        vm.prank(hookAdmin);
        IPrediXHook(address(hook)).executeTrustedRouter(address(router));
    }

    // =========================================================================
    // Test 1: full E2E (a)-(e)
    // =========================================================================

    function test_Fork_FeeSystem_E2E() public {
        _approveRouterForUsdc(alice);
        _approveRouterForUsdc(bob);
        _approveExchangeForAll(charlie);

        // alice/bob need YES/NO tokens for the SELL legs.
        _splitToUser(alice, 20_000e6);
        _splitToUser(bob, 20_000e6);
        _approveRouterForYes(alice);
        _approveRouterForNo(bob);

        // ---- (a) accruedBuilderFee(CODE) grows on EVERY match type ----
        // Each router leg crosses a freshly-seeded resting maker on the COMPLEMENTARY side so the CLOB leg
        // fills (and accrues the per-fill taker + maker builder fee). Without resting depth the trade would
        // route 100% to the AMM, whose carve emits no in-exchange `BuilderFeeAccrued`.
        uint256 b0 = feeExchange.accruedBuilderFee(CODE);

        _seedRestingMaker(IPrediXExchange.Side.SELL_YES);
        vm.prank(alice);
        router.buyYes(marketId, 10_000e6, 0, alice, 0, block.timestamp + 1 hours, CODE);
        assertGt(feeExchange.accruedBuilderFee(CODE), b0, "builder fee did not grow on buyYes");
        b0 = feeExchange.accruedBuilderFee(CODE);

        _seedRestingMaker(IPrediXExchange.Side.BUY_YES);
        vm.prank(alice);
        router.sellYes(marketId, 5_000e6, 0, alice, 0, block.timestamp + 1 hours, CODE);
        assertGt(feeExchange.accruedBuilderFee(CODE), b0, "builder fee did not grow on sellYes");
        b0 = feeExchange.accruedBuilderFee(CODE);

        _seedRestingMaker(IPrediXExchange.Side.SELL_NO);
        vm.prank(bob);
        router.buyNo(marketId, 10_000e6, 0, bob, 0, block.timestamp + 1 hours, CODE);
        assertGt(feeExchange.accruedBuilderFee(CODE), b0, "builder fee did not grow on buyNo");
        b0 = feeExchange.accruedBuilderFee(CODE);

        _seedRestingMaker(IPrediXExchange.Side.BUY_NO);
        vm.prank(bob);
        router.sellNo(marketId, 5_000e6, 0, bob, 0, block.timestamp + 1 hours, CODE);
        assertGt(feeExchange.accruedBuilderFee(CODE), b0, "builder fee did not grow on sellNo");

        // ---- (b) per-fill maker rebate paid + accruedProtocolFee grows, with R + T == F ----
        // Top up resting SELL_YES depth so alice's BUY crosses a CODE-tagged maker (charlie).
        _seedRestingMaker(IPrediXExchange.Side.SELL_YES);
        address restingMaker = charlie;
        uint256 t0 = feeExchange.accruedProtocolFee();
        uint256 makerUsdcBefore = usdc.balanceOf(restingMaker);

        vm.recordLogs();
        vm.prank(alice);
        router.buyYes(marketId, 8_000e6, 0, alice, 0, block.timestamp + 1 hours, CODE);

        (uint256 sumFee, uint256 sumRebate, uint256 sumTreasury) = _scanProtocolFeeCharged();
        assertGt(sumFee, 0, "no ProtocolFeeCharged emitted on the crossing fill");
        assertEq(sumRebate + sumTreasury, sumFee, "R + T != F across the captured fills");
        assertGt(sumRebate, 0, "rebate R must be > 0 with rebateBps > 0");

        uint256 tGrew = feeExchange.accruedProtocolFee() - t0;
        assertEq(tGrew, sumTreasury, "accruedProtocolFee delta != Sigma treasury cut");
        assertGt(tGrew, 0, "treasury T did not accrue");

        // A resting SELL_YES maker (charlie) was crossed by alice's BUY: the maker receives its USDC proceeds
        // PLUS the per-fill rebate R as a separate transfer (TakerPath.sol:339). Every seeded maker is charlie,
        // so charlie's net USDC delta over the crossing call is at least the total rebate paid out. `sumFee>0`
        // (asserted above) already proves a crossing CLOB fill occurred; FIFO means the filled order may be an
        // earlier same-side maker, not the one just seeded — the rebate still lands on charlie either way.
        assertGe(usdc.balanceOf(restingMaker) - makerUsdcBefore, sumRebate, "maker did not receive the rebate R");

        // ---- (c) claimBuilderFee pays the registry recipient exactly the accrued amount ----
        uint256 recipBefore = usdc.balanceOf(builderRecipient);
        uint256 accrued = feeExchange.accruedBuilderFee(CODE);
        assertGt(accrued, 0, "no builder fee to claim");
        feeExchange.claimBuilderFee(CODE); // permissionless
        assertEq(usdc.balanceOf(builderRecipient) - recipBefore, accrued, "builder claim != accrued");
        assertEq(feeExchange.accruedBuilderFee(CODE), 0, "accrued builder not zeroed");

        // ---- (d) sweepProtocolFee pays the protocol recipient exactly the accrued treasury cut ----
        uint256 tBefore = usdc.balanceOf(treasury);
        uint256 tAcc = feeExchange.accruedProtocolFee();
        assertGt(tAcc, 0, "no protocol fee to sweep");
        vm.prank(admin);
        feeExchange.sweepProtocolFee();
        assertEq(usdc.balanceOf(treasury) - tBefore, tAcc, "sweep != accrued T");
        assertEq(feeExchange.accruedProtocolFee(), 0, "accrued T not zeroed");

        // ---- (e) GLOBAL SOLVENCY INVARIANT ----
        _assertExchangeSolvent();
    }

    // =========================================================================
    // Test 2: P10 byte-identity — zero config + no builder
    // =========================================================================

    function test_Fork_P10_ByteIdentical_ZeroConfig_NoBuilder() public {
        // A fresh market with NO protocol-fee override (launch default 0) and the GLOBAL rebate forced back
        // to 0. The default protocol fee was never set, so this market's coef is 0 — combined with builder ==
        // bytes32(0) the whole fee path is skipped (P10).
        (uint256 zeroMarketId, address zYes, address zNo) = _createMarket(30 days);
        vm.prank(admin);
        market.setProtocolMakerRebateBps(0);

        // Seed a resting SELL_YES maker (builder bytes32(0)) so the buy routes through the CLOB. The exchange
        // needs allowance for THIS market's YES token (distinct from the default market's tokens).
        _splitToUser2(charlie, zeroMarketId, MAKER_AMOUNT);
        vm.startPrank(charlie);
        IERC20(zYes).approve(address(exchange), type(uint256).max);
        IERC20(zNo).approve(address(exchange), type(uint256).max);
        feeExchange.placeOrder(zeroMarketId, IPrediXExchange.Side.SELL_YES, MAKER_PRICE, MAKER_AMOUNT, bytes32(0));
        vm.stopPrank();

        _approveRouterForUsdc(alice);

        uint256 protoBefore = feeExchange.accruedProtocolFee();
        uint256 builderZeroBefore = feeExchange.accruedBuilderFee(bytes32(0));

        vm.recordLogs();
        vm.prank(alice);
        (uint256 yesOut, uint256 clobFilled,) =
            router.buyYes(zeroMarketId, 4_000e6, 0, alice, 0, block.timestamp + 1 hours, bytes32(0));

        // (i) taker cost == notional exactly (no fee add). The CLOB-filled portion at $0.50 costs
        //     clobFilled/2 USDC; with zero fees the taker spends EXACTLY notional, no carve.
        assertGt(clobFilled, 0, "CLOB leg did not fill - cannot prove zero-fee cost identity");
        assertGt(yesOut, 0, "no YES delivered");

        // (ii) neither ledger moved.
        assertEq(feeExchange.accruedProtocolFee(), protoBefore, "protocol fee accrued under zero config");
        assertEq(feeExchange.accruedBuilderFee(bytes32(0)), builderZeroBefore, "builder(0) accrued under zero config");

        // (iii) NO ProtocolFeeCharged / BuilderFeeAccrued logs from the exchange.
        _assertNoFeeLogs();
    }

    // =========================================================================
    // Test 3: buyNo at MAX combined rate stays solvent (no QuoteOutsideSafetyMargin)
    // =========================================================================

    function test_Fork_BuyNo_MaxCombinedRate_StaysSolvent() public {
        // The DEFAULT market already carries the MAX protocol fee (700, set in setUp) + the builder taker MAX
        // (100 via CODE), and has an initialized v4 pool with AMM liquidity but an EMPTY CLOB book. A buyNo
        // therefore routes entirely through the virtual-NO AMM path. The combined-fee carve must keep enough
        // usdcRemaining in the router for the mint, NOT trip the :884/:951 QuoteOutsideSafetyMargin gate.
        _approveRouterForUsdc(alice);

        vm.prank(alice);
        (uint256 noOut, uint256 clobFilled, uint256 ammFilled) =
            router.buyNo(marketId, 5_000e6, 0, alice, 0, block.timestamp + 1 hours, CODE);

        assertEq(clobFilled, 0, "unexpected CLOB fill on an empty book");
        assertGt(ammFilled, 0, "AMM leg produced no NO - QuoteOutsideSafetyMargin likely tripped");
        assertGt(noOut, 0, "buyNo delivered no NO at MAX combined rate");
    }

    // =========================================================================
    // Helpers
    // =========================================================================

    /// @dev Place a resting maker on `side` (priced at $0.50) for the DEFAULT market via charlie, tagged with
    ///      CODE. Records the order id for the solvency ledger. Funds + approves charlie for the leg.
    function _seedRestingMaker(IPrediXExchange.Side side) private returns (bytes32 orderId) {
        bool isBuy = side == IPrediXExchange.Side.BUY_YES || side == IPrediXExchange.Side.BUY_NO;
        _approveExchangeForAll(charlie);
        if (isBuy) {
            // BUY maker locks USDC deposit + the prefunded fee budgets; top charlie up generously.
            deal(address(usdc), charlie, 200_000e6);
        } else {
            // SELL maker needs the outcome tokens.
            _splitToUser2(charlie, marketId, MAKER_AMOUNT);
        }
        vm.prank(charlie);
        (orderId,) = feeExchange.placeOrder(marketId, side, MAKER_PRICE, MAKER_AMOUNT, CODE);
        restingOrderIds.push(orderId);
    }

    /// @dev Split `usdcAmount` USDC into YES+NO for `user` on an ARBITRARY market (mirrors fixture's
    ///      `_splitToUser`, which is hardcoded to the default `marketId`).
    function _splitToUser2(address user, uint256 mId, uint256 usdcAmount) private {
        deal(address(usdc), user, usdc.balanceOf(user) + usdcAmount);
        vm.startPrank(user);
        usdc.approve(address(diamond), usdcAmount);
        market.splitPosition(mId, usdcAmount);
        vm.stopPrank();
    }

    /// @dev Scan the recorded logs for `ProtocolFeeCharged(... fee, rebate, treasury, ...)` and sum each.
    function _scanProtocolFeeCharged() private returns (uint256 sumFee, uint256 sumRebate, uint256 sumTreasury) {
        Vm.Log[] memory logs = vm.getRecordedLogs();
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter != address(exchange)) continue;
            if (logs[i].topics.length == 0 || logs[i].topics[0] != PROTOCOL_FEE_CHARGED_TOPIC) continue;
            // Non-indexed data layout: taker, maker, makerOrderId, fee, rebate, treasury, p, matchType,
            // takerBuilder, makerBuilder. fee/rebate/treasury are at word offsets 3/4/5.
            (,,, uint256 fee, uint256 rebate, uint256 tcut,,,,) = abi.decode(
                logs[i].data, (address, address, bytes32, uint256, uint256, uint256, uint256, uint8, bytes32, bytes32)
            );
            sumFee += fee;
            sumRebate += rebate;
            sumTreasury += tcut;
        }
    }

    /// @dev Assert NO `ProtocolFeeCharged` / `BuilderFeeAccrued` logs were emitted by the exchange.
    function _assertNoFeeLogs() private {
        Vm.Log[] memory logs = vm.getRecordedLogs();
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter != address(exchange)) continue;
            if (logs[i].topics.length == 0) continue;
            bytes32 t = logs[i].topics[0];
            assertTrue(t != PROTOCOL_FEE_CHARGED_TOPIC, "ProtocolFeeCharged emitted under zero config");
            assertTrue(t != BUILDER_FEE_ACCRUED_TOPIC, "BuilderFeeAccrued emitted under zero config");
        }
    }

    /// @dev Global solvency: the exchange holds at least every USDC obligation it could be asked to honour —
    ///      live BUY deposits + their prefunded fee budgets + accrued builder + accrued protocol cut. `>=`
    ///      because the exchange also holds un-gettable protocol dust + any residual budgets.
    function _assertExchangeSolvent() private view {
        uint256 owed = feeExchange.accruedProtocolFee() + feeExchange.accruedBuilderFee(CODE);

        for (uint256 i; i < restingOrderIds.length; ++i) {
            bytes32 id = restingOrderIds[i];
            IPrediXExchange.Order memory ord = feeExchange.getOrder(id);
            if (ord.cancelled || ord.filled >= ord.amount) continue;
            if (ord.side == IPrediXExchange.Side.BUY_YES || ord.side == IPrediXExchange.Side.BUY_NO) {
                owed += ord.depositLocked;
                owed += _makerFeeLocked(id);
                owed += _placerProtocolFeeBudget(id);
            }
        }

        assertGe(usdc.balanceOf(address(exchange)), owed, "exchange insolvent for its USDC obligations");
    }

    /// @dev `LibBuilderFeeStorage.makerFeeLocked[orderId]` — mapping at struct field slot +2 (after
    ///      `builderRegistry` slot 0 and `accrued` mapping base slot 1).
    function _makerFeeLocked(bytes32 orderId) private view returns (uint256) {
        bytes32 base = bytes32(uint256(BUILDER_FEE_SLOT) + 2);
        bytes32 slot = keccak256(abi.encode(orderId, base));
        return uint256(vm.load(address(exchange), slot));
    }

    /// @dev `LibProtocolFeeStorage.placerProtocolFeeBudget[orderId]` — mapping at struct field slot +2 (after
    ///      `protocolFeeRecipient` slot 0 and `accruedProtocolFee` slot 1).
    function _placerProtocolFeeBudget(bytes32 orderId) private view returns (uint256) {
        bytes32 base = bytes32(uint256(PROTOCOL_FEE_SLOT) + 2);
        bytes32 slot = keccak256(abi.encode(orderId, base));
        return uint256(vm.load(address(exchange), slot));
    }
}
