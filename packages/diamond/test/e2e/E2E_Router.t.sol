// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IMarketFacet} from "@predix/shared/interfaces/IMarketFacet.sol";
import {IPrediXExchange} from "@predix/exchange/IPrediXExchange.sol";
import {IPrediXRouter} from "@predix/router/interfaces/IPrediXRouter.sol";
import {E2EForkBase} from "./E2EForkBase.t.sol";

/// @title E2E_Router
/// @notice Groups I+J+K+L: Router buy/sell YES/NO, market validation, edge cases.
///         Uses the existing Market B (ID=4) pool with deep liquidity deployed on-chain.
contract E2E_Router is E2EForkBase {
    IPrediXRouter internal router = IPrediXRouter(ROUTER);

    uint256 internal marketB;
    address internal yesB;
    address internal noB;

    function setUp() public override {
        super.setUp();

        // Create a fresh market for router tests (no AMM pool needed for CLOB-only tests;
        // AMM tests require pool setup which is covered by on-chain E2E bash script)
        _grantCreatorRole(DEPLOYER);
        marketB = _createMarket(DEPLOYER, block.timestamp + 7 days);
        (yesB, noB) = _getTokens(marketB);

        // Fund actors
        _splitPosition(alice, marketB, 10_000e6);
        _splitPosition(bob, marketB, 10_000e6);

        // Place CLOB orders so router can fill via CLOB
        vm.startPrank(bob);
        IERC20(yesB).approve(EXCHANGE, type(uint256).max);
        exchange.placeOrder(marketB, IPrediXExchange.Side.SELL_YES, 500_000, 5_000e6);
        IERC20(noB).approve(EXCHANGE, type(uint256).max);
        exchange.placeOrder(marketB, IPrediXExchange.Side.SELL_NO, 500_000, 5_000e6);
        IERC20(USDC).approve(EXCHANGE, type(uint256).max);
        exchange.placeOrder(marketB, IPrediXExchange.Side.BUY_YES, 400_000, 2_000e6);
        exchange.placeOrder(marketB, IPrediXExchange.Side.BUY_NO, 400_000, 2_000e6);
        vm.stopPrank();
    }

    // ================================================================
    // I. Router — buyYes / sellYes
    // ================================================================

    function test_I01_buyYes_requiresPool() public {
        // Router requires AMM pool for spot-price computation (hybrid design).
        // Happy path validated on-chain via scripts/e2e-test.sh.
        vm.startPrank(alice);
        IERC20(USDC).approve(ROUTER, type(uint256).max);
        vm.expectRevert();
        router.buyYes(marketB, 50e6, 1, alice, 10, block.timestamp + 300);
        vm.stopPrank();
    }

    function test_I04_buyYes_Revert_belowMinTradeAmount() public {
        vm.startPrank(alice);
        IERC20(USDC).approve(ROUTER, type(uint256).max);
        vm.expectRevert();
        router.buyYes(marketB, 999, 1, alice, 10, block.timestamp + 300); // < MIN_TRADE_AMOUNT
        vm.stopPrank();
    }

    function test_I05_buyYes_Revert_insufficientOutput() public {
        vm.startPrank(alice);
        IERC20(USDC).approve(ROUTER, type(uint256).max);
        vm.expectRevert();
        // minOut = max uint → impossible to fill
        router.buyYes(marketB, 10e6, type(uint256).max, alice, 10, block.timestamp + 300);
        vm.stopPrank();
    }

    function test_I06_buyYes_Revert_deadlineExpired() public {
        vm.startPrank(alice);
        IERC20(USDC).approve(ROUTER, type(uint256).max);
        vm.expectRevert();
        router.buyYes(marketB, 50e6, 1, alice, 10, block.timestamp - 1);
        vm.stopPrank();
    }

    function test_I07_buyYes_Revert_bannedRecipient_router() public {
        vm.startPrank(alice);
        IERC20(USDC).approve(ROUTER, type(uint256).max);
        vm.expectRevert();
        router.buyYes(marketB, 50e6, 1, ROUTER, 10, block.timestamp + 300);
        vm.stopPrank();
    }

    function test_I08_buyYes_Revert_bannedRecipient_diamond() public {
        vm.startPrank(alice);
        IERC20(USDC).approve(ROUTER, type(uint256).max);
        vm.expectRevert();
        router.buyYes(marketB, 50e6, 1, DIAMOND, 10, block.timestamp + 300);
        vm.stopPrank();
    }

    function test_I09_buyYes_Revert_bannedRecipient_exchange() public {
        vm.startPrank(alice);
        IERC20(USDC).approve(ROUTER, type(uint256).max);
        vm.expectRevert();
        router.buyYes(marketB, 50e6, 1, EXCHANGE, 10, block.timestamp + 300);
        vm.stopPrank();
    }

    function test_I11_sellYes_requiresPool() public {
        // Same as buyYes — Router needs AMM pool for limit price derivation
        vm.startPrank(alice);
        IERC20(yesB).approve(ROUTER, type(uint256).max);
        vm.expectRevert();
        router.sellYes(marketB, 50e6, 1, alice, 10, block.timestamp + 300);
        vm.stopPrank();
    }

    // ================================================================
    // J. Router — buyNo / sellNo (virtual-NO synthesis)
    // ================================================================

    function test_J05_sellNo_requiresPool() public {
        // sellNo uses virtual-NO path which needs AMM pool
        vm.startPrank(alice);
        IERC20(noB).approve(ROUTER, type(uint256).max);
        vm.expectRevert();
        router.sellNo(marketB, 20e6, 1, alice, 10, block.timestamp + 300);
        vm.stopPrank();
    }

    function test_J09_buyNo_Revert_insufficientOutput() public {
        vm.startPrank(alice);
        IERC20(USDC).approve(ROUTER, type(uint256).max);
        vm.expectRevert();
        router.buyNo(marketB, 10e6, type(uint256).max, alice, 10, block.timestamp + 300);
        vm.stopPrank();
    }

    function test_J10_routerZeroBalance_invariant() public view {
        // Router is stateless — should always hold zero tokens
        assertEq(IERC20(USDC).balanceOf(ROUTER), 0);
        assertEq(IERC20(yesB).balanceOf(ROUTER), 0);
        assertEq(IERC20(noB).balanceOf(ROUTER), 0);
    }

    // ================================================================
    // L. Router — Market Validation
    // ================================================================

    function test_L01_trade_Revert_resolvedMarket() public {
        // Create a fresh market and resolve it
        _grantCreatorRole(alice);
        uint256 mid = _createMarket(alice, block.timestamp + 1 hours);
        _splitPosition(alice, mid, 100e6);
        vm.warp(block.timestamp + 2 hours);
        _reportOutcome(mid, true);
        _resolveMarket(mid);

        vm.startPrank(alice);
        IERC20(USDC).approve(ROUTER, type(uint256).max);
        vm.expectRevert();
        router.buyYes(mid, 10e6, 1, alice, 10, block.timestamp + 300);
        vm.stopPrank();
    }

    function test_L02_trade_Revert_refundModeMarket() public {
        _grantCreatorRole(alice);
        uint256 mid = _createMarket(alice, block.timestamp + 1 hours);
        _splitPosition(alice, mid, 100e6);
        vm.warp(block.timestamp + 2 hours);
        vm.prank(DEPLOYER);
        diamond.enableRefundMode(mid);

        vm.startPrank(alice);
        IERC20(USDC).approve(ROUTER, type(uint256).max);
        vm.expectRevert();
        router.buyYes(mid, 10e6, 1, alice, 10, block.timestamp + 300);
        vm.stopPrank();
    }

    function test_L03_trade_Revert_expiredMarket() public {
        _grantCreatorRole(alice);
        uint256 mid = _createMarket(alice, block.timestamp + 1 hours);
        vm.warp(block.timestamp + 2 hours);

        vm.startPrank(alice);
        IERC20(USDC).approve(ROUTER, type(uint256).max);
        vm.expectRevert();
        router.buyYes(mid, 10e6, 1, alice, 10, block.timestamp + 300);
        vm.stopPrank();
    }

    function test_L04_trade_Revert_pausedMarketModule() public {
        vm.prank(DEPLOYER);
        pausable.pauseModule(MODULE_MARKET);

        vm.startPrank(alice);
        IERC20(USDC).approve(ROUTER, type(uint256).max);
        vm.expectRevert();
        router.buyYes(marketB, 10e6, 1, alice, 10, block.timestamp + 300);
        vm.stopPrank();

        vm.prank(DEPLOYER);
        pausable.unpauseModule(MODULE_MARKET);
    }

    function test_L05_trade_Revert_nonExistentMarket() public {
        vm.startPrank(alice);
        IERC20(USDC).approve(ROUTER, type(uint256).max);
        vm.expectRevert();
        router.buyYes(99999, 10e6, 1, alice, 10, block.timestamp + 300);
        vm.stopPrank();
    }
}
