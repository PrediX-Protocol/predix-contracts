// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";
import {PrediXExchange} from "../../src/PrediXExchange.sol";
import {PrediXExchangeProxy} from "../../src/PrediXExchangeProxy.sol";
import {MockERC20} from "../mocks/MockERC20.sol";
import {MockDiamond} from "../mocks/MockDiamond.sol";

contract PrediXExchangeProxyAdmin is Test {
    PrediXExchangeProxy internal proxy;
    PrediXExchange internal impl;
    MockERC20 internal usdc;
    MockDiamond internal diamond;

    address internal admin = makeAddr("admin");
    address internal newAdmin = makeAddr("newAdmin");
    address internal attacker = makeAddr("attacker");

    function setUp() public {
        usdc = new MockERC20("USDC", "USDC", 6);
        diamond = new MockDiamond(address(usdc));
        impl = new PrediXExchange();
        proxy = new PrediXExchangeProxy(address(impl), admin, address(diamond), address(usdc), makeAddr("feeRecipient"));
    }

    // ======== Constructor ========

    function test_constructor_SetsImplAndAdmin() public view {
        assertEq(proxy.implementation(), address(impl));
        assertEq(proxy.admin(), admin);
    }

    function test_Revert_constructor_ZeroImpl() public {
        vm.expectRevert(PrediXExchangeProxy.Proxy_ZeroAddress.selector);
        new PrediXExchangeProxy(address(0), admin, address(diamond), address(usdc), makeAddr("fee"));
    }

    function test_Revert_constructor_ZeroAdmin() public {
        vm.expectRevert(PrediXExchangeProxy.Proxy_ZeroAddress.selector);
        new PrediXExchangeProxy(address(impl), address(0), address(diamond), address(usdc), makeAddr("fee"));
    }

    function test_Revert_constructor_ImplNotContract() public {
        vm.expectRevert(PrediXExchangeProxy.Proxy_NotAContract.selector);
        new PrediXExchangeProxy(makeAddr("eoa"), admin, address(diamond), address(usdc), makeAddr("fee"));
    }

    // ======== Upgrade flow ========

    function test_proposeUpgrade_SetsReadyAt() public {
        PrediXExchange impl2 = new PrediXExchange();
        vm.prank(admin);
        proxy.proposeUpgrade(address(impl2));

        assertEq(proxy.pendingImplementation(), address(impl2));
        assertEq(proxy.upgradeReadyAt(), block.timestamp + 48 hours);
    }

    function test_Revert_proposeUpgrade_NotAdmin() public {
        vm.prank(attacker);
        vm.expectRevert(PrediXExchangeProxy.Proxy_OnlyAdmin.selector);
        proxy.proposeUpgrade(address(impl));
    }

    function test_Revert_proposeUpgrade_AlreadyPending() public {
        PrediXExchange impl2 = new PrediXExchange();
        vm.prank(admin);
        proxy.proposeUpgrade(address(impl2));

        vm.prank(admin);
        vm.expectRevert(PrediXExchangeProxy.Proxy_AlreadyPendingUpgrade.selector);
        proxy.proposeUpgrade(address(impl2));
    }

    function test_Revert_proposeUpgrade_ZeroAddress() public {
        vm.prank(admin);
        vm.expectRevert(PrediXExchangeProxy.Proxy_ZeroAddress.selector);
        proxy.proposeUpgrade(address(0));
    }

    function test_Revert_proposeUpgrade_NotContract() public {
        vm.prank(admin);
        vm.expectRevert(PrediXExchangeProxy.Proxy_NotAContract.selector);
        proxy.proposeUpgrade(makeAddr("eoa"));
    }

    function test_executeUpgrade_AfterDelay() public {
        PrediXExchange impl2 = new PrediXExchange();
        vm.prank(admin);
        proxy.proposeUpgrade(address(impl2));

        vm.warp(block.timestamp + 48 hours);
        vm.prank(admin);
        proxy.executeUpgrade();

        assertEq(proxy.implementation(), address(impl2));
        assertEq(proxy.pendingImplementation(), address(0));
        assertEq(proxy.upgradeReadyAt(), 0);
    }

    function test_Revert_executeUpgrade_TooEarly() public {
        PrediXExchange impl2 = new PrediXExchange();
        vm.prank(admin);
        proxy.proposeUpgrade(address(impl2));

        vm.warp(block.timestamp + 47 hours);
        vm.prank(admin);
        vm.expectRevert(PrediXExchangeProxy.Proxy_UpgradeNotReady.selector);
        proxy.executeUpgrade();
    }

    function test_Revert_executeUpgrade_NoPending() public {
        vm.prank(admin);
        vm.expectRevert(PrediXExchangeProxy.Proxy_NoPendingUpgrade.selector);
        proxy.executeUpgrade();
    }

    function test_cancelUpgrade() public {
        PrediXExchange impl2 = new PrediXExchange();
        vm.prank(admin);
        proxy.proposeUpgrade(address(impl2));

        vm.prank(admin);
        proxy.cancelUpgrade();

        assertEq(proxy.pendingImplementation(), address(0));
        assertEq(proxy.upgradeReadyAt(), 0);
        assertEq(proxy.implementation(), address(impl));
    }

    function test_Revert_cancelUpgrade_NoPending() public {
        vm.prank(admin);
        vm.expectRevert(PrediXExchangeProxy.Proxy_NoPendingUpgrade.selector);
        proxy.cancelUpgrade();
    }

    // ======== Admin rotation ========

    function test_changeAdmin_TwoStep() public {
        vm.prank(admin);
        proxy.changeAdmin(newAdmin);

        assertEq(proxy.pendingAdmin(), newAdmin);
        assertEq(proxy.admin(), admin);

        vm.warp(block.timestamp + 48 hours);
        vm.prank(newAdmin);
        proxy.acceptAdmin();

        assertEq(proxy.admin(), newAdmin);
        assertEq(proxy.pendingAdmin(), address(0));
    }

    function test_Revert_changeAdmin_NotAdmin() public {
        vm.prank(attacker);
        vm.expectRevert(PrediXExchangeProxy.Proxy_OnlyAdmin.selector);
        proxy.changeAdmin(newAdmin);
    }

    function test_Revert_changeAdmin_ZeroAddress() public {
        vm.prank(admin);
        vm.expectRevert(PrediXExchangeProxy.Proxy_ZeroAddress.selector);
        proxy.changeAdmin(address(0));
    }

    function test_Revert_changeAdmin_AlreadyPending() public {
        vm.prank(admin);
        proxy.changeAdmin(newAdmin);

        vm.prank(admin);
        vm.expectRevert(PrediXExchangeProxy.Proxy_AlreadyPendingAdmin.selector);
        proxy.changeAdmin(makeAddr("another"));
    }

    function test_Revert_acceptAdmin_NotPending() public {
        vm.prank(admin);
        proxy.changeAdmin(newAdmin);

        vm.warp(block.timestamp + 48 hours);
        vm.prank(attacker);
        vm.expectRevert(PrediXExchangeProxy.Proxy_OnlyPendingAdmin.selector);
        proxy.acceptAdmin();
    }

    function test_Revert_acceptAdmin_TooEarly() public {
        vm.prank(admin);
        proxy.changeAdmin(newAdmin);

        vm.warp(block.timestamp + 47 hours);
        vm.prank(newAdmin);
        vm.expectRevert(PrediXExchangeProxy.Proxy_AdminDelayNotElapsed.selector);
        proxy.acceptAdmin();
    }

    function test_cancelAdminChange() public {
        vm.prank(admin);
        proxy.changeAdmin(newAdmin);

        vm.prank(admin);
        proxy.cancelAdminChange();

        assertEq(proxy.pendingAdmin(), address(0));
        assertEq(proxy.admin(), admin);
    }

    function test_Revert_cancelAdminChange_NoPending() public {
        vm.prank(admin);
        vm.expectRevert(PrediXExchangeProxy.Proxy_NoPendingAdmin.selector);
        proxy.cancelAdminChange();
    }

    // ======== Fallback ========

    function test_Revert_fallback_RejectsETH() public {
        vm.deal(attacker, 1 ether);
        vm.prank(attacker);
        vm.expectRevert(PrediXExchangeProxy.Proxy_NoETHAccepted.selector);
        (bool ok,) = address(proxy).call{value: 1 ether}("");
        ok;
    }

    function test_fallback_DelegatesToImpl() public view {
        PrediXExchange exchange = PrediXExchange(address(proxy));
        assertEq(exchange.diamond(), address(diamond));
        assertEq(exchange.usdc(), address(usdc));
    }
}
