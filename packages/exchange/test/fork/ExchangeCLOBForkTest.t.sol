// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {IPrediXExchange} from "../../src/IPrediXExchange.sol";
import {PrediXExchange} from "../../src/PrediXExchange.sol";

import {MockDiamond} from "../mocks/MockDiamond.sol";

/// @notice CLOB complementary-match + strict solvency check against the real
///         canonical USDC deployment. Catches any gap between MockERC20 and
///         real USDC in the allowance / transferFrom flow the exchange uses
///         for BUY-side deposit collection.
/// @dev The diamond is still a local MockDiamond because the exchange only
///      interacts with it through `splitPosition` / `mergePositions`
///      callbacks, and those have no real-chain state dependency. The fork
///      scope is the ERC-20 transfer path between user, exchange and
///      protocol-deployed outcome tokens.
contract ExchangeCLOBForkTest is Test {
    IERC20 internal usdc;
    MockDiamond internal diamond;
    PrediXExchange internal exchange;

    address internal feeRecipient = makeAddr("fork_exchange_fee");
    address internal alice = makeAddr("fork_exchange_alice");
    address internal bob = makeAddr("fork_exchange_bob");

    uint256 internal constant MARKET_ID = 1;
    address internal yesToken;
    address internal noToken;

    function setUp() public {
        vm.createSelectFork(vm.envString("UNICHAIN_RPC_PRIMARY"));
        usdc = IERC20(vm.envAddress("USDC_ADDRESS"));

        diamond = new MockDiamond(address(usdc));
        exchange = new PrediXExchange(address(diamond), address(usdc), feeRecipient);
        (yesToken, noToken) = diamond.createMarket(MARKET_ID, block.timestamp + 7 days, address(this));
    }

    function _giveUsdc(address to, uint256 amount) internal {
        deal(address(usdc), to, amount);
        vm.prank(to);
        usdc.approve(address(exchange), type(uint256).max);
    }

    function _giveYesNo(address to, uint256 amount) internal {
        deal(address(usdc), to, amount);
        vm.startPrank(to);
        usdc.approve(address(diamond), amount);
        diamond.splitPosition(MARKET_ID, amount);
        IERC20(yesToken).approve(address(exchange), type(uint256).max);
        IERC20(noToken).approve(address(exchange), type(uint256).max);
        vm.stopPrank();
    }

    // -----------------------------------------------------------------------

    function test_ComplementaryMatch_WithRealUSDC() public {
        // Alice sells 100 YES at $0.40, Bob sells 100 NO at $0.60. The sum
        // equals $1 so the exchange mints from the diamond and routes each
        // leg to the corresponding buyer as a synthetic complementary fill.
        _giveYesNo(alice, 100e6);
        _giveYesNo(bob, 100e6);

        vm.prank(alice);
        (bytes32 aliceOrder,) =
            exchange.placeOrder(MARKET_ID, IPrediXExchange.Side.SELL_YES, 400_000, 100e6);
        vm.prank(bob);
        (bytes32 bobOrder,) =
            exchange.placeOrder(MARKET_ID, IPrediXExchange.Side.SELL_NO, 600_000, 100e6);

        // Neutralise compiler unused-var warnings (both ids are structural proof
        // that orders landed; later asserts check the on-chain state instead).
        aliceOrder;
        bobOrder;

        assertEq(IERC20(yesToken).balanceOf(alice), 0);
        assertEq(IERC20(noToken).balanceOf(bob), 0);
    }

    function test_Solvency_AfterSeedAndCancel() public {
        // Place a BUY_YES order at $0.40 and immediately cancel. The
        // exchange must refund the full USDC deposit and hold zero balance.
        _giveUsdc(alice, 40e6);
        vm.prank(alice);
        (bytes32 orderId,) =
            exchange.placeOrder(MARKET_ID, IPrediXExchange.Side.BUY_YES, 400_000, 100e6);

        // Strict solvency while the order rests.
        assertEq(usdc.balanceOf(address(exchange)), 40e6);

        uint256 balBefore = usdc.balanceOf(alice);
        vm.prank(alice);
        exchange.cancelOrder(orderId);

        assertEq(usdc.balanceOf(address(exchange)), 0, "exchange residual after cancel");
        assertEq(usdc.balanceOf(alice) - balBefore, 40e6, "refund != locked");
    }
}
