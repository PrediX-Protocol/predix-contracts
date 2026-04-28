// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {IMarketFacet} from "@predix/shared/interfaces/IMarketFacet.sol";
import {IAccessControlFacet} from "@predix/shared/interfaces/IAccessControlFacet.sol";
import {Roles} from "@predix/shared/constants/Roles.sol";
import {Modules} from "@predix/shared/constants/Modules.sol";

import {IPrediXExchange} from "@predix/exchange/IPrediXExchange.sol";
import {PrediXExchange} from "@predix/exchange/PrediXExchange.sol";

import {MarketFixture} from "../utils/MarketFixture.sol";

/// @title ExchangeIntegrationTest
/// @notice End-to-end integration: real `Diamond` + `MarketFacet` + `PausableFacet` +
///         `AccessControlFacet` + a freshly deployed `PrediXExchange`. Proves that:
///         - Exchange can be wired against the production diamond cuts (no shims, no mocks).
///         - `placeOrder` / `cancelOrder` / `fillMarketOrder` round-trip through the real
///           `splitPosition` / `mergePositions` codepath.
///         - The diamond's `Modules.MARKET` pause halts the taker path via Exchange's
///           `_validateMarketActive`.
///         - `Roles.PAUSER_ROLE` granted on the diamond authorises Exchange-level pause.
///         - Solvency: every active BUY order's `depositLocked` matches Exchange's USDC
///           balance after a multi-step session (post-audit dust filter holds against
///           the real diamond, not just the mock).
contract ExchangeIntegrationTest is MarketFixture {
    PrediXExchange internal exchange;

    address internal exchangeAdmin = makeAddr("exchangeAdmin");
    address internal pauser = makeAddr("pauser");
    address internal taker = makeAddr("taker");
    address internal recipient = makeAddr("recipient");

    uint256 internal constant ONE_SHARE = 1e6;

    function setUp() public override {
        super.setUp();

        exchange = new PrediXExchange();
        exchange.initialize(address(diamond), address(usdc), feeRecipient);
    }

    // ============ Helpers ============

    function _giveUsdc(address to, uint256 amount) internal {
        usdc.mint(to, amount);
        vm.prank(to);
        usdc.approve(address(exchange), type(uint256).max);
    }

    /// @dev Mint USDC, split into YES + NO via the real diamond, approve Exchange.
    function _giveYesNo(address to, uint256 marketId, uint256 amount) internal {
        usdc.mint(to, amount);
        vm.startPrank(to);
        usdc.approve(address(diamond), amount);
        market.splitPosition(marketId, amount);
        IERC20(market.getMarket(marketId).yesToken).approve(address(exchange), type(uint256).max);
        IERC20(market.getMarket(marketId).noToken).approve(address(exchange), type(uint256).max);
        vm.stopPrank();
    }

    function _grantPauser(address who) internal {
        vm.prank(admin);
        accessControl.grantRole(Roles.PAUSER_ROLE, who);
    }

    function _solvency_usdc(
        uint256 /*marketId*/
    )
        internal
        view
        returns (uint256 bal)
    {
        bal = usdc.balanceOf(address(exchange));
    }

    // ============ 1. Pure complementary fill against real diamond ============

    function test_Integration_FillMarketOrder_Complementary() public {
        uint256 marketId = _createMarket(block.timestamp + 7 days);

        // Alice places SELL_YES @ $0.50 × 100 (locks 100 YES via real diamond split).
        _giveYesNo(alice, marketId, 100 * ONE_SHARE);
        vm.prank(alice);
        exchange.placeOrder(marketId, IPrediXExchange.Side.SELL_YES, 500_000, 100 * ONE_SHARE);

        // Taker buys 100 YES with 100 USDC budget (will use only 50).
        _giveUsdc(taker, 100 * ONE_SHARE);
        vm.prank(taker);
        (uint256 filled, uint256 cost) = exchange.fillMarketOrder(
            marketId, IPrediXExchange.Side.BUY_YES, 600_000, 100 * ONE_SHARE, taker, recipient, 0, block.timestamp + 60
        );

        assertEq(filled, 100 * ONE_SHARE, "filled 100 YES");
        assertEq(cost, 50 * ONE_SHARE, "cost 50 USDC");
        assertEq(IERC20(market.getMarket(marketId).yesToken).balanceOf(recipient), 100 * ONE_SHARE, "recipient YES");
        assertEq(usdc.balanceOf(taker), 50 * ONE_SHARE, "taker refund");
        assertEq(usdc.balanceOf(alice), 50 * ONE_SHARE, "alice payout");

        // Solvency: no active BUY orders → exchange holds 0 USDC.
        assertEq(usdc.balanceOf(address(exchange)), 0, "exchange solvent");
    }

    // ============ 2. Synthetic MINT against real splitPosition ============

    function test_Integration_FillMarketOrder_Mint_RealSplit() public {
        uint256 marketId = _createMarket(block.timestamp + 7 days);

        _giveUsdc(alice, 40 * ONE_SHARE);
        vm.prank(alice);
        exchange.placeOrder(marketId, IPrediXExchange.Side.BUY_NO, 400_000, 100 * ONE_SHARE);

        _giveUsdc(taker, 100 * ONE_SHARE);
        vm.prank(taker);
        (uint256 filled, uint256 cost) = exchange.fillMarketOrder(
            marketId, IPrediXExchange.Side.BUY_YES, 700_000, 100 * ONE_SHARE, taker, recipient, 0, block.timestamp + 60
        );

        assertEq(filled, 100 * ONE_SHARE, "filled");
        assertEq(cost, 60 * ONE_SHARE, "cost = takerEffective 0.60 * 100");

        // Real splitPosition was called → totalCollateral on the diamond moved.
        IMarketFacet.MarketView memory mkt = market.getMarket(marketId);
        assertEq(mkt.totalCollateral, 100 * ONE_SHARE, "diamond totalCollateral");

        // YES → recipient, NO → maker (alice).
        assertEq(IERC20(mkt.yesToken).balanceOf(recipient), 100 * ONE_SHARE);
        assertEq(IERC20(mkt.noToken).balanceOf(alice), 100 * ONE_SHARE);

        // Zero surplus on taker synthetic → fee recipient empty.
        assertEq(usdc.balanceOf(feeRecipient), 0);

        // Solvency.
        assertEq(usdc.balanceOf(address(exchange)), 0, "exchange solvent");
    }

    // ============ 3. Synthetic MERGE against real mergePositions ============

    function test_Integration_FillMarketOrder_Merge_RealMerge() public {
        uint256 marketId = _createMarket(block.timestamp + 7 days);

        _giveYesNo(alice, marketId, 100 * ONE_SHARE);
        vm.prank(alice);
        exchange.placeOrder(marketId, IPrediXExchange.Side.SELL_NO, 400_000, 100 * ONE_SHARE);

        _giveYesNo(taker, marketId, 100 * ONE_SHARE);
        vm.prank(taker);
        (uint256 filled, uint256 cost) = exchange.fillMarketOrder(
            marketId, IPrediXExchange.Side.SELL_YES, 500_000, 100 * ONE_SHARE, taker, recipient, 0, block.timestamp + 60
        );

        assertEq(filled, 60 * ONE_SHARE, "recipient gets 60 USDC");
        assertEq(cost, 100 * ONE_SHARE, "spent 100 YES");
        assertEq(usdc.balanceOf(recipient), 60 * ONE_SHARE);
        assertEq(usdc.balanceOf(alice), 40 * ONE_SHARE);

        // Real mergePositions burned the YES + NO; diamond totalCollateral down by 100.
        IMarketFacet.MarketView memory mkt = market.getMarket(marketId);
        assertEq(mkt.totalCollateral, 100 * ONE_SHARE, "alice's split + taker's split - merge = 100");

        // Solvency.
        assertEq(IERC20(mkt.yesToken).balanceOf(address(exchange)), 0);
        assertEq(IERC20(mkt.noToken).balanceOf(address(exchange)), 0);
    }

    // ============ 4. placeOrder phase-A complementary auto-match ============

    function test_Integration_PlaceOrder_PhaseA_PriceImprovement() public {
        uint256 marketId = _createMarket(block.timestamp + 7 days);

        _giveYesNo(alice, marketId, 100 * ONE_SHARE);
        vm.prank(alice);
        exchange.placeOrder(marketId, IPrediXExchange.Side.SELL_YES, 500_000, 100 * ONE_SHARE);

        _giveUsdc(bob, 60 * ONE_SHARE);
        vm.prank(bob);
        exchange.placeOrder(marketId, IPrediXExchange.Side.BUY_YES, 600_000, 100 * ONE_SHARE);

        // Bob locked 60, used 50, refunded 10 via _refundPriceImprovement.
        assertEq(usdc.balanceOf(bob), 10 * ONE_SHARE);
        assertEq(IERC20(market.getMarket(marketId).yesToken).balanceOf(bob), 100 * ONE_SHARE);
        assertEq(usdc.balanceOf(alice), 50 * ONE_SHARE);

        // No active orders — exchange should be empty (dust sweep, M5 cleanup).
        assertEq(usdc.balanceOf(address(exchange)), 0, "exchange solvent");
    }

    // ============ 5. Diamond MARKET module pause halts taker path ============

    function test_Integration_FillMarketOrder_Reverts_DiamondMarketPaused() public {
        uint256 marketId = _createMarket(block.timestamp + 7 days);

        _giveYesNo(alice, marketId, 10 * ONE_SHARE);
        vm.prank(alice);
        exchange.placeOrder(marketId, IPrediXExchange.Side.SELL_YES, 500_000, 10 * ONE_SHARE);

        // Diamond admin pauses the MARKET module via the real PausableFacet.
        vm.prank(admin);
        accessControl.grantRole(Roles.PAUSER_ROLE, pauser);
        vm.prank(pauser);
        pausable.pauseModule(Modules.MARKET);

        _giveUsdc(taker, 10 * ONE_SHARE);
        vm.prank(taker);
        vm.expectRevert(IPrediXExchange.MarketPaused.selector);
        exchange.fillMarketOrder(
            marketId, IPrediXExchange.Side.BUY_YES, 600_000, 10 * ONE_SHARE, taker, taker, 0, block.timestamp + 60
        );
    }

    // ============ 6. Exchange-level pause via diamond PAUSER_ROLE ============

    function test_Integration_ExchangePause_GatedByDiamondRole() public {
        // Bob without role cannot pause.
        vm.prank(bob);
        vm.expectRevert(PrediXExchange.OnlyPauser.selector);
        exchange.pause();

        // Diamond admin grants PAUSER_ROLE.
        _grantPauser(pauser);

        vm.prank(pauser);
        exchange.pause();
        assertTrue(exchange.paused(), "exchange paused");

        // placeOrder reverts; cancel and fillMarketOrder remain open.
        uint256 marketId = _createMarket(block.timestamp + 7 days);
        _giveUsdc(alice, 50 * ONE_SHARE);
        vm.prank(alice);
        vm.expectRevert(PrediXExchange.ExchangePaused.selector);
        exchange.placeOrder(marketId, IPrediXExchange.Side.BUY_YES, 500_000, 100 * ONE_SHARE);
    }

    // ============ 7. Multi-step session solvency invariant ============

    /// @notice Multi-step session against the real diamond — assert the strict
    ///         solvency invariant `Exchange USDC balance == carol.depositLocked`
    ///         (the only remaining active BUY) holds exactly after maker matching,
    ///         taker fillMarketOrder, and partial synthetic MINT.
    function test_Integration_Solvency_AfterMultiStepSession() public {
        uint256 marketId = _createMarket(block.timestamp + 7 days);

        // Alice rests SELL_YES @ $0.50 × 100.
        _giveYesNo(alice, marketId, 100 * ONE_SHARE);
        vm.prank(alice);
        exchange.placeOrder(marketId, IPrediXExchange.Side.SELL_YES, 500_000, 100 * ONE_SHARE);

        // Carol rests BUY_NO @ $0.40 × 100 (the partial-fill victim of the
        // taker's synthetic tail).
        _giveUsdc(carol, 40 * ONE_SHARE);
        vm.prank(carol);
        (bytes32 carolId,) = exchange.placeOrder(marketId, IPrediXExchange.Side.BUY_NO, 400_000, 100 * ONE_SHARE);

        // Bob places BUY_YES @ $0.55 × 60 — phase A consumes 60 of alice at $0.50.
        _giveUsdc(bob, 33 * ONE_SHARE);
        vm.prank(bob);
        exchange.placeOrder(marketId, IPrediXExchange.Side.BUY_YES, 550_000, 60 * ONE_SHARE);

        // Taker fillMarketOrder picks up the rest of alice (40 shares @ $0.50)
        // then synthetic-MINTs part of carol with the residual budget.
        _giveUsdc(taker, 25 * ONE_SHARE);
        vm.prank(taker);
        exchange.fillMarketOrder(
            marketId, IPrediXExchange.Side.BUY_YES, 600_000, 25 * ONE_SHARE, taker, taker, 0, block.timestamp + 60
        );

        // Carol is the only active BUY left. Read her stored `depositLocked`
        // directly (not a re-derived formula — over-collateralization dust on
        // partial-fill BUY orders means the storage value is the truth and the
        // strict invariant holds against it, not against `(remaining * price) / 1e6`).
        IPrediXExchange.Order memory carolOrd = exchange.getOrder(carolId);
        assertGt(carolOrd.depositLocked, 0, "carol still partially locked");
        assertEq(
            usdc.balanceOf(address(exchange)),
            uint256(carolOrd.depositLocked),
            "Exchange USDC == carol.depositLocked (strict)"
        );

        // Collateral preserved on the diamond.
        IMarketFacet.MarketView memory mkt = market.getMarket(marketId);
        assertEq(IERC20(mkt.yesToken).totalSupply(), IERC20(mkt.noToken).totalSupply());
    }
}
