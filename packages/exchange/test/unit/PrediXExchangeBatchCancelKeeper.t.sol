// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {IPrediXExchange} from "../../src/IPrediXExchange.sol";
import {ExchangeTestBase} from "../base/ExchangeTestBase.sol";

/// @notice Pins the batch-cancel keeper path: on a terminal market (resolved /
///         refund / expired) anyone may `cancelOrders` others' resting orders,
///         returning the locked escrow to each order owner — not the caller.
///         On an active market non-owner entries are still skipped.
contract PrediXExchangeBatchCancelKeeper is ExchangeTestBase {
    address internal keeper = carol; // no role — keeper cancel is permissionless

    function _cancelledFlag(bytes32 id) internal view returns (bool cancelled) {
        (,, , cancelled,,,,,,) = exchange.orders(id);
    }

    function test_Keeper_ResolvedMarket_CancelsAndRefundsOwners() public {
        // 0.5 USDC deposit each (1 share @ $0.50).
        bytes32 aliceId = _placeBuyYes(alice, 500_000, ONE_SHARE);
        bytes32 bobId = _placeBuyYes(bob, 500_000, ONE_SHARE);
        // Escrowed: owners hold 0 USDC after placing.
        assertEq(_usdcBalance(alice), 0);
        assertEq(_usdcBalance(bob), 0);

        diamond.setMarketResolved(MARKET_ID, true);

        bytes32[] memory ids = new bytes32[](2);
        ids[0] = aliceId;
        ids[1] = bobId;

        vm.prank(keeper);
        uint256 count = exchange.cancelOrders(ids);

        assertEq(count, 2, "keeper cancels both on resolved market");
        assertTrue(_cancelledFlag(aliceId));
        assertTrue(_cancelledFlag(bobId));
        // Refund goes to each OWNER, never the keeper.
        assertEq(_usdcBalance(alice), 500_000, "alice refunded");
        assertEq(_usdcBalance(bob), 500_000, "bob refunded");
        assertEq(_usdcBalance(keeper), 0, "keeper gets nothing");
    }

    function test_Keeper_ExpiredMarket_Cancels() public {
        bytes32 aliceId = _placeBuyYes(alice, 400_000, ONE_SHARE);

        vm.warp(block.timestamp + 8 days); // past the 7-day endTime

        bytes32[] memory ids = new bytes32[](1);
        ids[0] = aliceId;

        vm.prank(keeper);
        uint256 count = exchange.cancelOrders(ids);

        assertEq(count, 1, "keeper cancels on expired market");
        assertTrue(_cancelledFlag(aliceId));
        assertEq(_usdcBalance(alice), 400_000, "alice refunded full deposit");
    }

    function test_Keeper_RefundMode_CancelsAndRefundsSellToken() public {
        // SELL escrows the outcome token; verify the token leg refunds to owner.
        bytes32 aliceId = _placeSellYes(alice, 600_000, ONE_SHARE);
        assertEq(_yesBalance(alice), 0, "YES escrowed");

        diamond.setMarketRefundMode(MARKET_ID, true);

        bytes32[] memory ids = new bytes32[](1);
        ids[0] = aliceId;

        vm.prank(keeper);
        uint256 count = exchange.cancelOrders(ids);

        assertEq(count, 1, "keeper cancels on refund-mode market");
        assertTrue(_cancelledFlag(aliceId));
        assertEq(_yesBalance(alice), ONE_SHARE, "alice YES refunded");
        assertEq(_yesBalance(keeper), 0, "keeper gets no token");
    }

    function test_Keeper_ActiveMarket_SkipsOthersOrders() public {
        bytes32 aliceId = _placeBuyYes(alice, 500_000, ONE_SHARE);
        bytes32 bobId = _placeBuyYes(bob, 500_000, ONE_SHARE);

        bytes32[] memory ids = new bytes32[](2);
        ids[0] = aliceId;
        ids[1] = bobId;

        // Market still active — keeper cannot cancel others' orders.
        vm.prank(keeper);
        uint256 count = exchange.cancelOrders(ids);

        assertEq(count, 0, "no cancellation on active market");
        assertFalse(_cancelledFlag(aliceId));
        assertFalse(_cancelledFlag(bobId));
        assertEq(_usdcBalance(alice), 0, "escrow untouched");
    }

    function test_Owner_ActiveMarket_StillCancelsOwn() public {
        // Regression on the touched path: owner cancel on an active market works.
        bytes32 aliceId = _placeBuyYes(alice, 500_000, ONE_SHARE);

        bytes32[] memory ids = new bytes32[](1);
        ids[0] = aliceId;

        vm.prank(alice);
        uint256 count = exchange.cancelOrders(ids);

        assertEq(count, 1, "owner cancels own on active market");
        assertTrue(_cancelledFlag(aliceId));
        assertEq(_usdcBalance(alice), 500_000, "alice refunded");
    }
}
