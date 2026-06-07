// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {LPFeeLibrary} from "@uniswap/v4-core/src/libraries/LPFeeLibrary.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {IV4Quoter} from "@uniswap/v4-periphery/src/interfaces/IV4Quoter.sol";
import {HookMiner} from "@uniswap/v4-periphery/src/utils/HookMiner.sol";
import {IAllowanceTransfer} from "permit2/src/interfaces/IAllowanceTransfer.sol";

import {IEventFacet} from "@predix/shared/interfaces/IEventFacet.sol";
import {ILinkedEventFacet} from "@predix/shared/interfaces/ILinkedEventFacet.sol";
import {IMarketFacet} from "@predix/shared/interfaces/IMarketFacet.sol";
import {IOutcomeToken} from "@predix/shared/interfaces/IOutcomeToken.sol";

import {PrediXRouter} from "@predix/router/PrediXRouter.sol";
import {PrediXHookV2} from "@predix/hook/hooks/PrediXHookV2.sol";
import {PrediXHookProxyV2} from "@predix/hook/proxy/PrediXHookProxyV2.sol";
import {IPrediXHook} from "@predix/hook/interfaces/IPrediXHook.sol";
import {PrediXExchange} from "@predix/exchange/PrediXExchange.sol";
import {PrediXExchangeProxy} from "@predix/exchange/PrediXExchangeProxy.sol";
import {IPrediXExchange} from "@predix/exchange/IPrediXExchange.sol";

import {LinkedEventFixture} from "../utils/LinkedEventFixture.sol";
import {IntegrationPoolManager, IntegrationQuoter, IntegrationPermit2} from "./RouterIntegration.t.sol";

/// @title LinkedCrossPackageE2E
/// @notice keyti-3c3g.10 gap 1 — the linked (shared-collateral) TRADING path across packages. Existing
///         linked coverage is diamond-only (facet-direct); this suite drives linked children through the
///         REAL PrediXExchange CLOB (complementary fill, synthetic MINT via `splitPosition`, synthetic
///         MERGE via `mergePositions`) and the REAL PrediXRouter (CLOB leg + virtual-NO split inside the
///         unlock callback), then resolves and drains the shared pool through `redeemLinked` — asserting
///         the solvency identity `eventPool == Σ NO_i + M` (uniform M) after every step and an EXACT
///         drain to 0 at the end. v4 PoolManager/Quoter are the same deterministic stubs RouterIntegration
///         uses (v4-core's concrete PoolManager pins an incompatible solc); the hook's real swap-path
///         behavior is covered by `packages/hook` unit + fork suites and is linked-agnostic by design.
contract LinkedCrossPackageE2ETest is LinkedEventFixture {
    IntegrationPoolManager internal pm;
    IntegrationQuoter internal quoter;
    IntegrationPermit2 internal permit2;

    PrediXHookV2 internal hookImpl;
    PrediXHookProxyV2 internal hookProxy;
    IPrediXHook internal hook;

    PrediXExchange internal exchange;
    PrediXRouter internal router;

    address internal proxyAdmin = makeAddr("proxyAdmin");
    address internal hookAdmin = makeAddr("hookAdmin");
    address internal trader = makeAddr("trader");

    int24 internal constant TICK_SPACING = 60;
    uint24 internal constant FEE_FLAG = LPFeeLibrary.DYNAMIC_FEE_FLAG;

    /// @dev Mirrors `PrediXHookProxyV2.getHookPermissions()` — required by HookMiner salt.
    uint160 internal constant HOOK_FLAGS = uint160(
        Hooks.BEFORE_INITIALIZE_FLAG | Hooks.BEFORE_ADD_LIQUIDITY_FLAG | Hooks.BEFORE_REMOVE_LIQUIDITY_FLAG
            | Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_SWAP_FLAG | Hooks.BEFORE_DONATE_FLAG
    );

    function setUp() public virtual override {
        super.setUp();

        pm = new IntegrationPoolManager();
        quoter = new IntegrationQuoter();
        permit2 = new IntegrationPermit2();

        hookImpl = new PrediXHookV2(IPoolManager(address(pm)), address(quoter), 0x800000, int24(60), 48 hours);
        bytes memory ctorArgs = abi.encode(
            IPoolManager(address(pm)), address(hookImpl), proxyAdmin, hookAdmin, address(diamond), address(usdc)
        );
        (address expected, bytes32 salt) =
            HookMiner.find(address(this), HOOK_FLAGS, type(PrediXHookProxyV2).creationCode, ctorArgs);
        hookProxy = new PrediXHookProxyV2{salt: salt}(
            IPoolManager(address(pm)), address(hookImpl), proxyAdmin, hookAdmin, address(diamond), address(usdc)
        );
        require(address(hookProxy) == expected, "hook proxy salt mismatch");
        hook = IPrediXHook(address(hookProxy));
        pm.setHook(address(hookProxy));

        PrediXExchange exchangeImpl = new PrediXExchange();
        PrediXExchangeProxy exchangeProxy = new PrediXExchangeProxy(
            address(exchangeImpl), address(this), address(diamond), address(usdc), feeRecipient
        );
        exchange = PrediXExchange(address(exchangeProxy));

        router = new PrediXRouter(
            IPoolManager(address(pm)),
            address(diamond),
            address(usdc),
            address(hookProxy),
            address(exchange),
            IV4Quoter(address(quoter)),
            IAllowanceTransfer(address(permit2)),
            FEE_FLAG,
            TICK_SPACING
        );

        vm.startPrank(hookAdmin);
        hook.setTrustedRouter(address(router), true);
        hook.setTrustedRouter(address(quoter), true);
        vm.stopPrank();
    }

    // =========================================================================
    // Helpers
    // =========================================================================

    /// @dev The linked solvency identity, asserted mid-flow: every outcome's margin `y_i - n_i` is the
    ///      SAME M, and `eventPool == Σ NO_i + M`. Trading (CLOB fills, AMM swaps) only moves tokens, so
    ///      any violation here means a cross-package path minted/burned a leg without the pool credit.
    function _assertLinkedSolvent(uint256 eventId) internal view {
        IEventFacet.EventView memory e = eventFacet.getEvent(eventId);
        if (e.isResolved) return;
        uint256 sumNo;
        int256 m0;
        for (uint256 i; i < e.marketIds.length; ++i) {
            IMarketFacet.MarketView memory m = market.getMarket(e.marketIds[i]);
            int256 margin =
                int256(IOutcomeToken(m.yesToken).totalSupply()) - int256(IOutcomeToken(m.noToken).totalSupply());
            if (i == 0) m0 = margin;
            else assertEq(margin, m0, "M not uniform across outcomes");
            sumNo += IOutcomeToken(m.noToken).totalSupply();
        }
        assertEq(int256(linked.eventPoolOf(eventId)), int256(sumNo) + m0, "eventPool != sum(NO_i) + M");
    }

    function _mintSet(address user, uint256 eventId, uint256 amount) internal {
        _fundAndApprove(user, amount);
        vm.prank(user);
        linked.mintCompleteSet(eventId, amount);
    }

    function _giveUsdcForExchange(address to, uint256 amount) internal {
        usdc.mint(to, amount);
        vm.prank(to);
        usdc.approve(address(exchange), type(uint256).max);
    }

    function _approveOutcomeTokens(address who, uint256 marketId, address spender) internal {
        IMarketFacet.MarketView memory m = market.getMarket(marketId);
        vm.startPrank(who);
        IERC20(m.yesToken).approve(spender, type(uint256).max);
        IERC20(m.noToken).approve(spender, type(uint256).max);
        vm.stopPrank();
    }

    function _resolveWinner(uint256 eventId, uint256 endTime, uint256 winIdx) internal {
        vm.warp(endTime + 1);
        eventOracle.setEventResolution(eventId, winIdx);
        eventFacet.resolveEvent(eventId);
    }

    function _registerChildPool(uint256 marketId) internal returns (address yesToken, PoolKey memory key) {
        yesToken = market.getMarket(marketId).yesToken;
        (Currency c0, Currency c1) = address(usdc) < yesToken
            ? (Currency.wrap(address(usdc)), Currency.wrap(yesToken))
            : (Currency.wrap(yesToken), Currency.wrap(address(usdc)));
        key = PoolKey({
            currency0: c0, currency1: c1, fee: FEE_FLAG, tickSpacing: TICK_SPACING, hooks: IHooks(address(hookProxy))
        });
        hook.registerMarketPool(marketId, key);
        bytes32 poolId = keccak256(abi.encode(key));
        bytes32 stateSlot = keccak256(abi.encodePacked(poolId, bytes32(uint256(6))));
        pm.setPoolSlot0(stateSlot, 79228162514264337593543950336);
    }

    // =========================================================================
    // 1. CLOB complementary fill on a linked child → full lifecycle
    // =========================================================================

    function test_E2E_Clob_ComplementaryFill_LinkedChild_PoolDrainsToZero() public {
        uint256 endTime = block.timestamp + 7 days;
        (uint256 eventId, uint256[] memory ids) = _createLinked3(endTime);

        // alice mints a complete set and rests SELL_YES on child0 @ $0.60.
        _mintSet(alice, eventId, 200e6);
        _approveOutcomeTokens(alice, ids[0], address(exchange));
        vm.prank(alice);
        exchange.placeOrder(ids[0], IPrediXExchange.Side.SELL_YES, 600_000, 200e6, bytes32(0));
        _assertLinkedSolvent(eventId);

        // bob takes the whole level — tokens move, supplies don't.
        _giveUsdcForExchange(bob, 120e6);
        vm.prank(bob);
        (uint256 filled, uint256 cost) = exchange.fillMarketOrder(
            ids[0], IPrediXExchange.Side.BUY_YES, 700_000, 120e6, bob, bob, 0, block.timestamp + 60, bytes32(0)
        );
        assertEq(filled, 200e6, "filled 200 YES");
        assertEq(cost, 120e6, "cost 120 USDC at 0.60");
        _assertLinkedSolvent(eventId);
        assertEq(linked.eventPoolOf(eventId), 200e6, "trading must not move the pool");

        // Resolve outcome 0 — bob holds all winner-YES, alice holds only loser-YES (worthless).
        _resolveWinner(eventId, endTime, 0);

        vm.prank(bob);
        uint256 bobPayout = linked.redeemLinked(eventId);
        assertEq(bobPayout, 200e6, "bob claims the full pool via winner-YES");

        vm.prank(alice);
        vm.expectRevert(ILinkedEventFacet.LinkedEvent_NothingToRedeem.selector);
        linked.redeemLinked(eventId);

        assertEq(linked.eventPoolOf(eventId), 0, "pool drains to exactly 0");
        assertEq(market.totalCollateralLocked(), 0, "global lock restored");
    }

    // =========================================================================
    // 2. CLOB synthetic MINT — exchange splitPosition routes to eventPool
    // =========================================================================

    function test_E2E_Clob_SyntheticMint_LinkedChild_RoutesToEventPool() public {
        uint256 endTime = block.timestamp + 7 days;
        (uint256 eventId, uint256[] memory ids) = _createLinked3(endTime);

        // alice rests BUY_NO child0 @ $0.40; bob's BUY_YES taker forces the synthetic MINT:
        // the exchange calls the diamond's splitPosition(child0) with combined funds.
        _giveUsdcForExchange(alice, 40e6);
        vm.prank(alice);
        exchange.placeOrder(ids[0], IPrediXExchange.Side.BUY_NO, 400_000, 100e6, bytes32(0));

        _giveUsdcForExchange(bob, 100e6);
        vm.prank(bob);
        (uint256 filled, uint256 cost) = exchange.fillMarketOrder(
            ids[0], IPrediXExchange.Side.BUY_YES, 700_000, 100e6, bob, bob, 0, block.timestamp + 60, bytes32(0)
        );
        assertEq(filled, 100e6, "synthetic minted 100");
        assertEq(cost, 60e6, "taker pays 1 - makerPrice");

        // The linked branch must credit the EVENT pool, never the child's own collateral.
        assertEq(market.getMarket(ids[0]).totalCollateral, 0, "linked child holds no per-child collateral");
        assertEq(linked.eventPoolOf(eventId), 100e6, "split routed to eventPool");
        assertEq(market.totalCollateralLocked(), 100e6, "lockstep credit");
        _assertLinkedSolvent(eventId);

        // Winner 0: bob's YES0 claims the whole pool; alice's NO0 is the winner's NO (worthless).
        _resolveWinner(eventId, endTime, 0);
        vm.prank(bob);
        assertEq(linked.redeemLinked(eventId), 100e6, "bob drains the pool");
        vm.prank(alice);
        vm.expectRevert(ILinkedEventFacet.LinkedEvent_NothingToRedeem.selector);
        linked.redeemLinked(eventId);
        assertEq(linked.eventPoolOf(eventId), 0, "pool drains to exactly 0");
    }

    // =========================================================================
    // 3. CLOB synthetic MERGE — exchange mergePositions debits eventPool
    // =========================================================================

    function test_E2E_Clob_SyntheticMerge_LinkedChild_DebitsEventPool() public {
        uint256 endTime = block.timestamp + 7 days;
        (uint256 eventId, uint256[] memory ids) = _createLinked3(endTime);

        // alice: complete set + child0 split → she can rest SELL_NO; bob: child0 split → taker SELL_YES.
        _mintSet(alice, eventId, 100e6);
        _split(alice, ids[0], 100e6);
        _split(bob, ids[0], 100e6);
        assertEq(linked.eventPoolOf(eventId), 300e6, "pool after set + two splits");
        _assertLinkedSolvent(eventId);

        _approveOutcomeTokens(alice, ids[0], address(exchange));
        vm.prank(alice);
        exchange.placeOrder(ids[0], IPrediXExchange.Side.SELL_NO, 400_000, 100e6, bytes32(0));

        _approveOutcomeTokens(bob, ids[0], address(exchange));
        vm.prank(bob);
        (uint256 filled, uint256 cost) = exchange.fillMarketOrder(
            ids[0], IPrediXExchange.Side.SELL_YES, 500_000, 100e6, bob, bob, 0, block.timestamp + 60, bytes32(0)
        );
        assertEq(filled, 60e6, "bob receives the taker share of $1");
        assertEq(cost, 100e6, "bob spent 100 YES");

        // Synthetic MERGE burned 100 YES + 100 NO through the diamond → pool debited by exactly 100.
        assertEq(linked.eventPoolOf(eventId), 200e6, "merge debited the eventPool");
        assertEq(market.getMarket(ids[0]).totalCollateral, 0, "child collateral untouched");
        _assertLinkedSolvent(eventId);

        // Winner 1: alice claims YES1 (100); bob claims loser-NO0 (100) — exact drain.
        _resolveWinner(eventId, endTime, 1);
        vm.prank(alice);
        assertEq(linked.redeemLinked(eventId), 100e6, "alice winner-YES claim");
        vm.prank(bob);
        assertEq(linked.redeemLinked(eventId), 100e6, "bob loser-NO claim");
        assertEq(linked.eventPoolOf(eventId), 0, "pool drains to exactly 0");
        assertEq(market.totalCollateralLocked(), 0, "global lock restored");
    }

    // =========================================================================
    // 4. Router → exchange CLOB leg on a linked child
    // =========================================================================

    function test_E2E_Router_BuyYes_ClobLeg_LinkedChild_FullLifecycle() public {
        uint256 endTime = block.timestamp + 7 days;
        (uint256 eventId, uint256[] memory ids) = _createLinked3(endTime);
        _registerChildPool(ids[0]);

        _mintSet(alice, eventId, 200e6);
        _approveOutcomeTokens(alice, ids[0], address(exchange));
        vm.prank(alice);
        exchange.placeOrder(ids[0], IPrediXExchange.Side.SELL_YES, 600_000, 200e6, bytes32(0));

        address yesToken = market.getMarket(ids[0]).yesToken;
        usdc.mint(trader, 120e6);
        vm.prank(trader);
        usdc.approve(address(router), 120e6);
        vm.prank(trader);
        (uint256 yesOut, uint256 clobFilled, uint256 ammFilled) =
            router.buyYes(ids[0], 120e6, 0, trader, 5, block.timestamp + 1 hours);

        assertEq(ammFilled, 0, "no AMM leg");
        assertEq(clobFilled, 200e6, "router CLOB leg filled");
        assertEq(yesOut, 200e6);
        assertEq(IERC20(yesToken).balanceOf(trader), 200e6, "trader holds winner-YES");
        assertEq(usdc.balanceOf(address(router)), 0, "router stateless");
        _assertLinkedSolvent(eventId);

        _resolveWinner(eventId, endTime, 0);
        vm.prank(trader);
        assertEq(linked.redeemLinked(eventId), 200e6, "router-bought YES redeems the pool");
        assertEq(linked.eventPoolOf(eventId), 0, "pool drains to exactly 0");
    }

    // =========================================================================
    // 5. Router virtual-NO — splitPosition INSIDE the unlock callback → eventPool
    // =========================================================================

    function test_E2E_Router_BuyNo_VirtualPath_LinkedChild_SplitsToEventPool() public {
        uint256 endTime = block.timestamp + 30 days;
        (uint256 eventId, uint256[] memory ids) = _createLinked3(endTime);
        (address yesToken,) = _registerChildPool(ids[0]);
        address noToken = market.getMarket(ids[0]).noToken;

        // Same deterministic quoter script as RouterIntegration's virtual-NO path (linear pool, $0.50).
        uint256[] memory sellSeq = new uint256[](5);
        sellSeq[0] = 500_000;
        sellSeq[1] = 40_000_000;
        sellSeq[2] = 500_000;
        sellSeq[3] = 40_000_000;
        sellSeq[4] = 39_800_000;
        quoter.setExactInSequence(sellSeq);

        uint256 usdcIn = 40e6;
        uint256 mintAmount = (((usdcIn * 1e6) / 500_000) * 9950) / 10_000; // 0.5% cushion → 79.6e6
        uint256 proceeds = mintAmount - usdcIn + 1;
        if (yesToken < address(usdc)) {
            pm.queueSwap(-int128(int256(mintAmount)), int128(int256(proceeds)));
        } else {
            pm.queueSwap(int128(int256(proceeds)), -int128(int256(mintAmount)));
        }
        usdc.mint(address(pm), 10_000_000e6);

        usdc.mint(trader, usdcIn);
        vm.prank(trader);
        usdc.approve(address(router), usdcIn);
        vm.prank(trader);
        (uint256 noOut,, uint256 ammFilled) = router.buyNo(ids[0], usdcIn, 0, trader, 5, block.timestamp + 1 hours);

        assertEq(ammFilled, mintAmount, "virtual-NO minted via AMM leg");
        assertEq(noOut, mintAmount);
        assertEq(IERC20(noToken).balanceOf(trader), mintAmount, "trader holds NO");

        // The split inside the router's unlock callback must credit the EVENT pool.
        assertEq(market.getMarket(ids[0]).totalCollateral, 0, "linked child holds no per-child collateral");
        assertEq(linked.eventPoolOf(eventId), mintAmount, "callback split routed to eventPool");
        _assertLinkedSolvent(eventId);

        // Full drain: the YES leg sits in the PM stub — hand it to carol (plain ERC20 transfer),
        // resolve winner 0, and the pool must drain to exactly 0 via her winner-YES claim.
        vm.prank(address(pm));
        IERC20(yesToken).transfer(carol, mintAmount);
        _resolveWinner(eventId, endTime, 0);
        vm.prank(carol);
        assertEq(linked.redeemLinked(eventId), mintAmount, "carol claims the pool");
        vm.prank(trader);
        vm.expectRevert(ILinkedEventFacet.LinkedEvent_NothingToRedeem.selector);
        linked.redeemLinked(eventId);
        assertEq(linked.eventPoolOf(eventId), 0, "pool drains to exactly 0");
        assertEq(market.totalCollateralLocked(), 0, "global lock restored");
    }
}
