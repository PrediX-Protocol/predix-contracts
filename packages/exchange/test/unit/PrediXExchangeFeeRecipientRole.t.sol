// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import {IPrediXExchange} from "../../src/IPrediXExchange.sol";
import {PrediXExchange} from "../../src/PrediXExchange.sol";

import {ExchangeTestBase} from "../base/ExchangeTestBase.sol";

/// @title PrediXExchangeFeeRecipientRoleTest
/// @notice Asserts `setFeeRecipient` is gated by ADMIN_ROLE, NOT PAUSER_ROLE.
///         The fee recipient controls where CLOB protocol fees accrue, so it
///         must live behind the cold admin key — pauser is a fast hot key
///         intended only for emergency pause/unpause.
contract PrediXExchangeFeeRecipientRoleTest is ExchangeTestBase {
    bytes32 internal constant ADMIN_ROLE = keccak256("predix.role.admin");
    bytes32 internal constant PAUSER_ROLE = keccak256("predix.role.pauser");

    address internal admin = makeAddr("admin");
    address internal newRecipient = makeAddr("newRecipient");

    function _grantAdmin(address who) internal {
        diamond.grantRole(ADMIN_ROLE, who);
    }

    function _grantPauser(address who) internal {
        diamond.grantRole(PAUSER_ROLE, who);
    }

    function test_SetFeeRecipient_ByAdmin() public {
        _grantAdmin(admin);

        vm.expectEmit(true, true, false, false);
        emit PrediXExchange.FeeRecipientUpdated(feeRecipient, newRecipient);

        vm.prank(admin);
        exchange.setFeeRecipient(newRecipient);

        assertEq(exchange.feeRecipient(), newRecipient);
    }

    function test_Revert_SetFeeRecipient_ByPauser() public {
        _grantPauser(pauser);

        vm.prank(pauser);
        vm.expectRevert(PrediXExchange.OnlyAdmin.selector);
        exchange.setFeeRecipient(newRecipient);

        assertEq(exchange.feeRecipient(), feeRecipient);
    }

    function test_Revert_SetFeeRecipient_ByUnprivileged() public {
        vm.prank(carol);
        vm.expectRevert(PrediXExchange.OnlyAdmin.selector);
        exchange.setFeeRecipient(newRecipient);
    }

    function test_Revert_SetFeeRecipient_PauserAndAdminAreDistinctRoles() public {
        // Grant pauser to one address and admin to another. Pauser must NOT be
        // able to call setFeeRecipient even when both roles are active on the
        // diamond at the same time.
        _grantPauser(pauser);
        _grantAdmin(admin);

        vm.prank(pauser);
        vm.expectRevert(PrediXExchange.OnlyAdmin.selector);
        exchange.setFeeRecipient(newRecipient);

        // Admin still works.
        vm.prank(admin);
        exchange.setFeeRecipient(newRecipient);
        assertEq(exchange.feeRecipient(), newRecipient);
    }

    function test_Revert_SetFeeRecipient_ZeroAddress() public {
        _grantAdmin(admin);

        vm.prank(admin);
        vm.expectRevert(IPrediXExchange.ZeroAddress.selector);
        exchange.setFeeRecipient(address(0));
    }
}
