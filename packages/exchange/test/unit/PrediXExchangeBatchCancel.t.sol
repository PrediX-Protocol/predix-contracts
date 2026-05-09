// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {IPrediXExchange} from "../../src/IPrediXExchange.sol";
import {Roles} from "@predix/shared/constants/Roles.sol";
import {ExchangeTestBase} from "../base/ExchangeTestBase.sol";

contract PrediXExchangeBatchCancel is ExchangeTestBase {
    function setUp() public override {
        super.setUp();
        diamond.grantRole(Roles.PAUSER_ROLE, pauser);
    }
    function test_cancelOrders_AllOwned() public {
        bytes32[] memory ids = new bytes32[](10);
        for (uint256 i; i < 10; i++) {
            ids[i] = _placeBuyYes(alice, 500_000, ONE_SHARE);
        }

        vm.prank(alice);
        uint256 count = exchange.cancelOrders(ids);

        assertEq(count, 10, "all 10 cancelled");
        for (uint256 i; i < 10; i++) {
            (,,, bool cancelled,,,,,,) = exchange.orders(ids[i]);
            assertTrue(cancelled, "order cancelled");
        }
    }

    function test_cancelOrders_MixedOwnership() public {
        bytes32[] memory ids = new bytes32[](10);
        for (uint256 i; i < 5; i++) {
            ids[i] = _placeBuyYes(alice, 500_000, ONE_SHARE);
        }
        for (uint256 i = 5; i < 10; i++) {
            ids[i] = _placeBuyYes(bob, 500_000, ONE_SHARE);
        }

        vm.prank(alice);
        uint256 count = exchange.cancelOrders(ids);

        assertEq(count, 5, "only alice's 5 cancelled");
    }

    function test_cancelOrders_AlreadyCancelled() public {
        bytes32 id1 = _placeBuyYes(alice, 500_000, ONE_SHARE);
        bytes32 id2 = _placeBuyYes(alice, 500_000, ONE_SHARE);
        bytes32 id3 = _placeBuyYes(alice, 500_000, ONE_SHARE);

        vm.prank(alice);
        exchange.cancelOrder(id2);

        bytes32[] memory ids = new bytes32[](3);
        ids[0] = id1;
        ids[1] = id2;
        ids[2] = id3;

        vm.prank(alice);
        uint256 count = exchange.cancelOrders(ids);

        assertEq(count, 2, "skip already-cancelled, cancel 2");
    }

    function test_Revert_cancelOrders_EmptyArray() public {
        bytes32[] memory ids = new bytes32[](0);

        vm.prank(alice);
        vm.expectRevert(IPrediXExchange.Exchange_EmptyArray.selector);
        exchange.cancelOrders(ids);
    }

    function test_Revert_cancelOrders_TooLarge() public {
        bytes32[] memory ids = new bytes32[](51);

        vm.prank(alice);
        vm.expectRevert(IPrediXExchange.Exchange_BatchTooLarge.selector);
        exchange.cancelOrders(ids);
    }

    function test_cancelOrders_DuringPause() public {
        bytes32 id1 = _placeBuyYes(alice, 500_000, ONE_SHARE);
        bytes32 id2 = _placeBuyYes(alice, 500_000, ONE_SHARE);

        vm.prank(pauser);
        exchange.pause();

        bytes32[] memory ids = new bytes32[](2);
        ids[0] = id1;
        ids[1] = id2;

        vm.prank(alice);
        uint256 count = exchange.cancelOrders(ids);

        assertEq(count, 2, "cancel works during pause");
    }
}
