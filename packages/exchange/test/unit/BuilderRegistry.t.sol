// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import {Test} from "forge-std/Test.sol";
import {IBuilderRegistry} from "@predix/shared/interfaces/IBuilderRegistry.sol";
import {Roles} from "@predix/shared/constants/Roles.sol";
import {BuilderRegistry} from "../../src/BuilderRegistry.sol";
import {MockAccessControl} from "../mocks/MockAccessControl.sol";

contract BuilderRegistryTest is Test {
    BuilderRegistry internal registry;
    MockAccessControl internal diamond;

    address internal admin = address(0xA11CE);
    address internal stranger = address(0xBEEF);
    address internal recipient = address(0xCAFE);
    bytes32 internal constant CODE = keccak256("phemex");

    function setUp() public {
        diamond = new MockAccessControl();
        diamond.grant(Roles.ADMIN_ROLE, admin);
        registry = new BuilderRegistry(address(diamond));
    }

    function test_constructor_storesDiamond_andDefaults() public view {
        assertEq(registry.diamond(), address(diamond));
        assertEq(registry.maxTakerBps(), 100);
        assertEq(registry.maxMakerBps(), 50);
        assertEq(registry.rateChangeCooldown(), 3 days);
        assertEq(registry.rateChangeMinInterval(), 7 days);
    }

    function test_constructor_rejectsZeroDiamond() public {
        vm.expectRevert(IBuilderRegistry.Registry_ZeroCode.selector);
        new BuilderRegistry(address(0));
    }

    // ---- Task 3: setBuilder (create-only, caps, ADMIN) + views ----

    function test_setBuilder_createsAndExposes() public {
        vm.prank(admin);
        registry.setBuilder(CODE, recipient, 100, 50);

        (uint16 t, uint16 m, address r) = registry.feeOf(CODE);
        assertEq(t, 100);
        assertEq(m, 50);
        assertEq(r, recipient);
        assertEq(registry.recipientOf(CODE), recipient);
        assertTrue(registry.exists(CODE));

        IBuilderRegistry.Builder memory b = registry.getBuilder(CODE);
        assertEq(b.lastChangeAt, block.timestamp);
        assertEq(b.rateReadyAt, 0);
    }

    function test_feeOf_unknownCode_returnsZero() public view {
        (uint16 t, uint16 m, address r) = registry.feeOf(keccak256("nope"));
        assertEq(t, 0);
        assertEq(m, 0);
        assertEq(r, address(0));
        assertFalse(registry.exists(keccak256("nope")));
    }

    function test_setBuilder_onlyAdmin() public {
        vm.prank(stranger);
        vm.expectRevert(IBuilderRegistry.Registry_NotAdmin.selector);
        registry.setBuilder(CODE, recipient, 100, 50);
    }

    function test_setBuilder_rejectsZeroCode() public {
        vm.prank(admin);
        vm.expectRevert(IBuilderRegistry.Registry_ZeroCode.selector);
        registry.setBuilder(bytes32(0), recipient, 100, 50);
    }

    function test_setBuilder_rejectsZeroRecipient() public {
        vm.prank(admin);
        vm.expectRevert(IBuilderRegistry.Registry_ZeroRecipient.selector);
        registry.setBuilder(CODE, address(0), 100, 50);
    }

    function test_setBuilder_rejectsOverCap() public {
        vm.prank(admin);
        vm.expectRevert(IBuilderRegistry.Registry_CapExceeded.selector);
        registry.setBuilder(CODE, recipient, 101, 50); // taker > maxTakerBps
    }

    function test_setBuilder_createOnly_rejectsReconfig() public {
        vm.prank(admin);
        registry.setBuilder(CODE, recipient, 100, 50);
        vm.prank(admin);
        vm.expectRevert(IBuilderRegistry.Registry_AlreadyExists.selector);
        registry.setBuilder(CODE, recipient, 50, 25);
    }

    // ---- Task 4: setRecipient (rotate payout) ----

    function test_setRecipient_rotates() public {
        vm.prank(admin);
        registry.setBuilder(CODE, recipient, 100, 50);
        address newR = address(0xD00D);
        vm.prank(admin);
        registry.setRecipient(CODE, newR);
        assertEq(registry.recipientOf(CODE), newR);
    }

    function test_setRecipient_unknownCode_reverts() public {
        vm.prank(admin);
        vm.expectRevert(IBuilderRegistry.Registry_UnknownCode.selector);
        registry.setRecipient(CODE, recipient);
    }

    function test_setRecipient_zero_reverts() public {
        vm.prank(admin);
        registry.setBuilder(CODE, recipient, 100, 50);
        vm.prank(admin);
        vm.expectRevert(IBuilderRegistry.Registry_ZeroRecipient.selector);
        registry.setRecipient(CODE, address(0));
    }

    function test_setRecipient_onlyAdmin() public {
        vm.prank(admin);
        registry.setBuilder(CODE, recipient, 100, 50);
        vm.prank(stranger);
        vm.expectRevert(IBuilderRegistry.Registry_NotAdmin.selector);
        registry.setRecipient(CODE, address(0xD00D));
    }

    // ---- Task 5: proposeRates (caps + min-interval cooldown) ----

    function test_proposeRates_setsPending_andReadyAt() public {
        vm.prank(admin);
        registry.setBuilder(CODE, recipient, 100, 50);
        // setBuilder set lastChangeAt = now; min-interval is 7d. Warp past it.
        vm.warp(block.timestamp + 7 days);
        vm.prank(admin);
        registry.proposeRates(CODE, 60, 30);

        IBuilderRegistry.Builder memory b = registry.getBuilder(CODE);
        assertEq(b.pendingTakerBps, 60);
        assertEq(b.pendingMakerBps, 30);
        assertEq(b.rateReadyAt, block.timestamp + 3 days); // cooldown
        // effective rates unchanged until applyRates
        assertEq(b.takerBps, 100);
        assertEq(b.makerBps, 50);
    }

    function test_proposeRates_unknownCode_reverts() public {
        vm.prank(admin);
        vm.expectRevert(IBuilderRegistry.Registry_UnknownCode.selector);
        registry.proposeRates(CODE, 60, 30);
    }

    function test_proposeRates_overCap_reverts() public {
        vm.prank(admin);
        registry.setBuilder(CODE, recipient, 100, 50);
        vm.warp(block.timestamp + 7 days);
        vm.prank(admin);
        vm.expectRevert(IBuilderRegistry.Registry_CapExceeded.selector);
        registry.proposeRates(CODE, 100, 51); // maker > maxMakerBps
    }

    function test_proposeRates_beforeMinInterval_reverts() public {
        vm.prank(admin);
        registry.setBuilder(CODE, recipient, 100, 50); // lastChangeAt = now
        vm.prank(admin);
        vm.expectRevert(IBuilderRegistry.Registry_CooldownActive.selector);
        registry.proposeRates(CODE, 60, 30); // < 7d since lastChangeAt
    }

    function test_proposeRates_onlyAdmin() public {
        vm.prank(admin);
        registry.setBuilder(CODE, recipient, 100, 50);
        vm.warp(block.timestamp + 7 days);
        vm.prank(stranger);
        vm.expectRevert(IBuilderRegistry.Registry_NotAdmin.selector);
        registry.proposeRates(CODE, 60, 30);
    }

    // ---- Task 6: applyRates (promote pending after cooldown, clear state) ----

    function _propose() internal {
        vm.prank(admin);
        registry.setBuilder(CODE, recipient, 100, 50);
        vm.warp(block.timestamp + 7 days);
        vm.prank(admin);
        registry.proposeRates(CODE, 60, 30);
    }

    function test_applyRates_promotes_andClears() public {
        _propose();
        vm.warp(block.timestamp + 3 days); // past rateReadyAt
        registry.applyRates(CODE); // permissionless

        IBuilderRegistry.Builder memory b = registry.getBuilder(CODE);
        assertEq(b.takerBps, 60);
        assertEq(b.makerBps, 30);
        assertEq(b.pendingTakerBps, 0);
        assertEq(b.pendingMakerBps, 0);
        assertEq(b.rateReadyAt, 0);
        assertEq(b.lastChangeAt, block.timestamp);
    }

    function test_applyRates_noPending_reverts() public {
        vm.prank(admin);
        registry.setBuilder(CODE, recipient, 100, 50);
        vm.expectRevert(IBuilderRegistry.Registry_NoPendingRates.selector);
        registry.applyRates(CODE);
    }

    function test_applyRates_beforeReady_reverts() public {
        _propose();
        // only 1 day past propose; rateReadyAt is +3d
        vm.warp(block.timestamp + 1 days);
        vm.expectRevert(IBuilderRegistry.Registry_RateNotReady.selector);
        registry.applyRates(CODE);
    }

    // ---- Task 7: setMaxBps (ABSOLUTE_MAX ceiling) ----

    function test_setMaxBps_tighten() public {
        vm.prank(admin);
        registry.setMaxBps(50, 25);
        assertEq(registry.maxTakerBps(), 50);
        assertEq(registry.maxMakerBps(), 25);
        // a new builder above the tightened cap now reverts
        vm.prank(admin);
        vm.expectRevert(IBuilderRegistry.Registry_CapExceeded.selector);
        registry.setBuilder(CODE, recipient, 51, 25);
    }

    function test_setMaxBps_aboveAbsolute_reverts() public {
        vm.prank(admin);
        vm.expectRevert(IBuilderRegistry.Registry_AbsoluteCapExceeded.selector);
        registry.setMaxBps(101, 50); // > ABSOLUTE_MAX_TAKER_BPS
    }

    function test_setMaxBps_onlyAdmin() public {
        vm.prank(stranger);
        vm.expectRevert(IBuilderRegistry.Registry_NotAdmin.selector);
        registry.setMaxBps(50, 25);
    }
}
