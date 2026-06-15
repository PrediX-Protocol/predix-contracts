// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import {IPrediXExchange} from "../../src/IPrediXExchange.sol";
import {Roles} from "@predix/shared/constants/Roles.sol";
import {ExchangeTestBase} from "../base/ExchangeTestBase.sol";
import {MockBuilderRegistry} from "../mocks/MockBuilderRegistry.sol";

/// @notice REVIEW_FIXES F3-3: the builder + protocol fee storage lives in DEDICATED ERC-7201 namespaces
///         (`LibBuilderFeeStorage` / `LibProtocolFeeStorage`), NOT appended to `ExchangeStorage`. Appending
///         would shift `paused` (slot 8) + the `orders` mapping and brick the live proxy. This test proves the
///         opposite holds: writing EVERY fee-lib slot does not perturb `paused()`/orders — asserted via
///         slot-agnostic GETTERS (the only upgrade-safe check). Complements the slot-literal test in Task 1.
contract StorageLayoutSafetyTest is ExchangeTestBase {
    MockBuilderRegistry internal registry;
    address internal mk = makeAddr("slMaker");
    bytes32 internal constant CODE = keccak256("sl-code");

    function setUp() public override {
        super.setUp();
        diamond.grantRole(Roles.ADMIN_ROLE, address(this));
        diamond.grantRole(Roles.PAUSER_ROLE, address(this));
        registry = new MockBuilderRegistry();
    }

    function test_feeWrites_doNotPerturb_pausedOrOrders() public {
        // 1. Baseline: a resting order + paused state, captured via getters.
        bytes32 id = _placeBuyYes(mk, 500_000, 1e8);
        IPrediXExchange.Order memory ordBefore = exchange.getOrder(id);
        exchange.pause();
        assertTrue(exchange.paused(), "paused true baseline");

        // 2. Write EVERY fee-lib slot while paused (these standalone fns are not maker-path gated).
        exchange.setBuilderRegistry(address(registry)); // LibBuilderFeeStorage.builderRegistry
        exchange.setProtocolFeeRecipient(makeAddr("treas")); // LibProtocolFeeStorage.protocolFeeRecipient
        _giveUsdc(address(this), 10e6);
        exchange.depositBuilderFee(CODE, 3e6); // LibBuilderFeeStorage.accrued[CODE]
        exchange.depositProtocolFee(2e6); // LibProtocolFeeStorage.accruedProtocolFee

        // 3. paused (slot 8) + the order are UNCHANGED ⇒ no ERC-7201 ↔ sequential-slot collision.
        assertTrue(exchange.paused(), "paused unchanged after fee writes");
        IPrediXExchange.Order memory ordAfter = exchange.getOrder(id);
        assertEq(ordAfter.owner, ordBefore.owner, "order.owner intact");
        assertEq(ordAfter.price, ordBefore.price, "order.price intact");
        assertEq(ordAfter.amount, ordBefore.amount, "order.amount intact");
        assertEq(ordAfter.depositLocked, ordBefore.depositLocked, "order.depositLocked intact");
        assertEq(uint8(ordAfter.side), uint8(ordBefore.side), "order.side intact");

        // 4. Fee writes landed in their own namespaces.
        assertEq(exchange.accruedBuilderFee(CODE), 3e6, "builder accrual recorded");
        assertEq(exchange.accruedProtocolFee(), 2e6, "protocol accrual recorded");

        // 5. Unpause restores the maker path ⇒ orders mapping fully intact across the fee writes.
        exchange.unpause();
        assertFalse(exchange.paused(), "unpaused");
    }
}
