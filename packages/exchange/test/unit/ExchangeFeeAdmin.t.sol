// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import {IPrediXExchange} from "../../src/IPrediXExchange.sol";
import {PrediXExchange} from "../../src/PrediXExchange.sol";
import {Roles} from "@predix/shared/constants/Roles.sol";
import {ExchangeTestBase} from "../base/ExchangeTestBase.sol";
import {MockBuilderRegistry} from "../mocks/MockBuilderRegistry.sol";

contract ExchangeFeeAdminTest is ExchangeTestBase {
    MockBuilderRegistry internal registry;
    address internal admin = makeAddr("admin");
    address internal treasury = makeAddr("treasury");
    address internal builderRecipient = makeAddr("builderRecipient");
    bytes32 internal constant CODE = keccak256("phemex");

    function setUp() public override {
        super.setUp();
        diamond.grantRole(Roles.ADMIN_ROLE, admin);
        registry = new MockBuilderRegistry();
        registry.set(CODE, 100, 50, builderRecipient);
    }

    // ---- setBuilderRegistry ----
    function test_setBuilderRegistry_onlyAdmin_andEvent() public {
        vm.expectEmit(true, true, false, false);
        emit IPrediXExchange.BuilderRegistrySet(address(0), address(registry));
        vm.prank(admin);
        exchange.setBuilderRegistry(address(registry));
    }

    function test_setBuilderRegistry_rejectsStranger() public {
        vm.prank(alice);
        vm.expectRevert(PrediXExchange.OnlyAdmin.selector);
        exchange.setBuilderRegistry(address(registry));
    }

    function test_setBuilderRegistry_rejectsZero() public {
        vm.prank(admin);
        vm.expectRevert(IPrediXExchange.ZeroAddress.selector);
        exchange.setBuilderRegistry(address(0));
    }

    // ---- setProtocolFeeRecipient ----
    function test_setProtocolFeeRecipient_onlyAdmin_andEvent() public {
        vm.expectEmit(true, true, false, false);
        emit IPrediXExchange.ProtocolFeeRecipientSet(address(0), treasury);
        vm.prank(admin);
        exchange.setProtocolFeeRecipient(treasury);
    }

    function test_setProtocolFeeRecipient_rejectsStranger() public {
        vm.prank(alice);
        vm.expectRevert(PrediXExchange.OnlyAdmin.selector);
        exchange.setProtocolFeeRecipient(treasury);
    }

    // ---- depositBuilderFee ----
    function test_depositBuilderFee_pullsAndAccrues() public {
        vm.prank(admin);
        exchange.setBuilderRegistry(address(registry));
        _giveUsdc(alice, 5e6);
        vm.prank(alice);
        exchange.depositBuilderFee(CODE, 5e6);
        assertEq(exchange.accruedBuilderFee(CODE), 5e6);
        assertEq(_usdcBalance(address(exchange)), 5e6);
    }

    function test_depositBuilderFee_zeroCode_earlyReturn_pullsNothing() public {
        _giveUsdc(alice, 5e6);
        vm.prank(alice);
        exchange.depositBuilderFee(bytes32(0), 5e6); // must NOT pull
        assertEq(_usdcBalance(alice), 5e6);
        assertEq(_usdcBalance(address(exchange)), 0);
    }

    function test_depositBuilderFee_zeroAmount_earlyReturn() public {
        vm.prank(alice);
        exchange.depositBuilderFee(CODE, 0);
        assertEq(exchange.accruedBuilderFee(CODE), 0);
    }

    // ---- claimBuilderFee ----
    function test_claimBuilderFee_sendsToRegistryRecipient_CEI() public {
        vm.prank(admin);
        exchange.setBuilderRegistry(address(registry));
        _giveUsdc(alice, 5e6);
        vm.prank(alice);
        exchange.depositBuilderFee(CODE, 5e6);

        vm.expectEmit(true, true, false, true);
        emit IPrediXExchange.BuilderFeeClaimed(CODE, builderRecipient, 5e6);
        exchange.claimBuilderFee(CODE); // permissionless
        assertEq(_usdcBalance(builderRecipient), 5e6);
        assertEq(exchange.accruedBuilderFee(CODE), 0);
    }

    function test_claimBuilderFee_nothing_reverts() public {
        vm.prank(admin);
        exchange.setBuilderRegistry(address(registry));
        vm.expectRevert(IPrediXExchange.Exchange_NothingToClaim.selector);
        exchange.claimBuilderFee(CODE);
    }

    function test_claimBuilderFee_noRegistry_reverts() public {
        vm.expectRevert(IPrediXExchange.Exchange_RegistryNotSet.selector);
        exchange.claimBuilderFee(CODE);
    }

    // ---- depositProtocolFee ----
    function test_depositProtocolFee_pullsAndAccrues() public {
        _giveUsdc(alice, 3e6);
        vm.prank(alice);
        exchange.depositProtocolFee(3e6);
        assertEq(exchange.accruedProtocolFee(), 3e6);
        assertEq(_usdcBalance(address(exchange)), 3e6);
    }

    function test_depositProtocolFee_zeroAmount_earlyReturn() public {
        vm.prank(alice);
        exchange.depositProtocolFee(0);
        assertEq(exchange.accruedProtocolFee(), 0);
    }

    // ---- sweepProtocolFee ----
    function test_sweepProtocolFee_sendsAccrued_CEI() public {
        vm.prank(admin);
        exchange.setProtocolFeeRecipient(treasury);
        _giveUsdc(alice, 3e6);
        vm.prank(alice);
        exchange.depositProtocolFee(3e6);

        vm.expectEmit(true, false, false, true);
        emit IPrediXExchange.ProtocolFeeSwept(treasury, 3e6);
        exchange.sweepProtocolFee(); // permissionless
        assertEq(_usdcBalance(treasury), 3e6);
        assertEq(exchange.accruedProtocolFee(), 0);
    }

    function test_sweepProtocolFee_noRecipient_reverts() public {
        _giveUsdc(alice, 3e6);
        vm.prank(alice);
        exchange.depositProtocolFee(3e6);
        vm.expectRevert(IPrediXExchange.Exchange_ProtocolRecipientNotSet.selector);
        exchange.sweepProtocolFee();
    }

    function test_sweepProtocolFee_zeroAccrued_noop() public {
        vm.prank(admin);
        exchange.setProtocolFeeRecipient(treasury);
        exchange.sweepProtocolFee(); // amt==0 -> return, no revert
        assertEq(_usdcBalance(treasury), 0);
    }
}
