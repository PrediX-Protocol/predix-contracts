// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {IPrediXHook} from "@predix/hook/interfaces/IPrediXHook.sol";
import {IPrediXHookProxy} from "@predix/hook/interfaces/IPrediXHookProxy.sol";
import {PrediXExchangeProxy} from "@predix/exchange/PrediXExchangeProxy.sol";
import {PrediXExchange} from "@predix/exchange/PrediXExchange.sol";
import {E2EForkBase} from "./E2EForkBase.t.sol";

/// @title E2E_Governance
/// @notice Groups P (Hook governance) and Q (Exchange proxy governance).
///         Tests propose/execute/cancel timelocked flows.
contract E2E_Governance is E2EForkBase {
    PrediXExchangeProxy internal exchProxy = PrediXExchangeProxy(payable(EXCHANGE));

    // ================================================================
    // Q. Exchange Proxy
    // ================================================================

    function test_Q01_proposeUpgrade_execute() public {
        // Deploy a dummy new impl
        PrediXExchange newImpl = new PrediXExchange();

        vm.prank(OPERATOR);
        exchProxy.proposeUpgrade(address(newImpl));

        // Before 48h: cannot execute
        vm.prank(OPERATOR);
        vm.expectRevert();
        exchProxy.executeUpgrade();

        // After 48h: execute succeeds
        vm.warp(block.timestamp + 48 hours + 1);
        vm.prank(OPERATOR);
        exchProxy.executeUpgrade();

        assertEq(exchProxy.implementation(), address(newImpl));
    }

    function test_Q02_proposeUpgrade_Revert_whilePending() public {
        PrediXExchange impl1 = new PrediXExchange();
        PrediXExchange impl2 = new PrediXExchange();

        vm.prank(OPERATOR);
        exchProxy.proposeUpgrade(address(impl1));

        vm.prank(OPERATOR);
        vm.expectRevert();
        exchProxy.proposeUpgrade(address(impl2));
    }

    function test_Q03_executeUpgrade_Revert_before48h() public {
        PrediXExchange newImpl = new PrediXExchange();
        vm.prank(OPERATOR);
        exchProxy.proposeUpgrade(address(newImpl));

        vm.warp(block.timestamp + 47 hours);
        vm.prank(OPERATOR);
        vm.expectRevert();
        exchProxy.executeUpgrade();
    }

    function test_Q04_cancelUpgrade() public {
        PrediXExchange newImpl = new PrediXExchange();
        vm.prank(OPERATOR);
        exchProxy.proposeUpgrade(address(newImpl));

        vm.prank(OPERATOR);
        exchProxy.cancelUpgrade();

        assertEq(exchProxy.pendingImplementation(), address(0));
    }

    function test_Q05_changeAdmin_acceptAdmin() public {
        vm.prank(OPERATOR);
        exchProxy.changeAdmin(alice);

        // Before 48h: cannot accept
        vm.prank(alice);
        vm.expectRevert();
        exchProxy.acceptAdmin();

        // After 48h: alice accepts
        vm.warp(block.timestamp + 48 hours + 1);
        vm.prank(alice);
        exchProxy.acceptAdmin();

        assertEq(exchProxy.admin(), alice);
    }

    function test_Q06_acceptAdmin_Revert_wrongCaller() public {
        vm.prank(OPERATOR);
        exchProxy.changeAdmin(alice);

        vm.warp(block.timestamp + 48 hours + 1);
        // bob is NOT the pending admin
        vm.prank(bob);
        vm.expectRevert();
        exchProxy.acceptAdmin();
    }

    function test_Q07_sendETH_Revert() public {
        vm.deal(alice, 1 ether);
        vm.prank(alice);
        (bool ok,) = EXCHANGE.call{value: 1 ether}("");
        assertFalse(ok);
    }

    // ================================================================
    // P. Hook Governance
    // ================================================================

    function test_P01_proposeDiamond_execute() public {
        address newDiamond = makeAddr("newDiamond");
        vm.etch(newDiamond, hex"00"); // give it code so check passes

        vm.prank(DEPLOYER);
        hook.proposeDiamond(newDiamond);

        vm.warp(block.timestamp + 48 hours + 1);
        vm.prank(DEPLOYER);
        hook.executeDiamondRotation();
    }

    function test_P02_proposeDiamond_Revert_whilePending() public {
        address d1 = makeAddr("d1");
        address d2 = makeAddr("d2");
        vm.etch(d1, hex"00");
        vm.etch(d2, hex"00");

        vm.prank(DEPLOYER);
        hook.proposeDiamond(d1);

        vm.prank(DEPLOYER);
        vm.expectRevert();
        hook.proposeDiamond(d2);
    }

    function test_P03_executeDiamond_Revert_before48h() public {
        address newDiamond = makeAddr("newDiamond2");
        vm.etch(newDiamond, hex"00");

        vm.prank(DEPLOYER);
        hook.proposeDiamond(newDiamond);

        vm.warp(block.timestamp + 47 hours);
        vm.prank(DEPLOYER);
        vm.expectRevert();
        hook.executeDiamondRotation();
    }

    function test_P04_cancelDiamondRotation() public {
        address newDiamond = makeAddr("newDiamond3");
        vm.etch(newDiamond, hex"00");

        vm.prank(DEPLOYER);
        hook.proposeDiamond(newDiamond);

        vm.prank(DEPLOYER);
        hook.cancelDiamondRotation();
    }

    function test_P05_setAdmin_acceptAdmin() public {
        vm.prank(DEPLOYER);
        hook.setAdmin(alice);

        // Before 48h
        vm.prank(alice);
        vm.expectRevert();
        hook.acceptAdmin();

        // After 48h
        vm.warp(block.timestamp + 48 hours + 1);
        vm.prank(alice);
        hook.acceptAdmin();

        assertEq(hook.admin(), alice);
    }

    function test_P06_acceptAdmin_Revert_wrongCaller() public {
        vm.prank(DEPLOYER);
        hook.setAdmin(alice);

        vm.warp(block.timestamp + 48 hours + 1);
        vm.prank(bob);
        vm.expectRevert();
        hook.acceptAdmin();
    }

    function test_P07_setTrustedRouter_preBootstrap() public {
        // Hook is not yet bootstrapped in our testnet deploy (finalizeGovernance=false)
        address newRouter = makeAddr("newRouter");
        vm.prank(DEPLOYER);
        hook.setTrustedRouter(newRouter, true);
        assertTrue(hook.isTrustedRouter(newRouter));

        vm.prank(DEPLOYER);
        hook.setTrustedRouter(newRouter, false);
        assertFalse(hook.isTrustedRouter(newRouter));
    }
}
