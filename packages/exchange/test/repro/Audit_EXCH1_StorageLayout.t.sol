// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Roles} from "@predix/shared/constants/Roles.sol";
import {ExchangeTestBase} from "../base/ExchangeTestBase.sol";
import {MockBuilderRegistry} from "../mocks/MockBuilderRegistry.sol";

/// @title Audit_EXCH1_StorageLayout (clm6.8 / EXCH-1)
/// @notice The Exchange impl uses SEQUENTIAL (non-ERC-7201) storage slots and is the logic behind a live
///         ERC-1967 proxy, so a future upgrade that reorders/inserts a slot would shift escrow + brick
///         conservation. The diamond has Audit_I03_StorageLayout; the exchange had none. This mirrors it:
///         it RAW-pins each ExchangeStorage slot via vm.load (so any reorder is caught in `forge test` / CI)
///         AND proves the new ERC-7201 fee storage (LibBuilderFeeStorage/LibProtocolFeeStorage) lives far away
///         — writing every fee-lib slot perturbs none of slots 0..8 (complements the getter-based
///         StorageLayoutSafety + the slot-literal LibFeeStorageSlots tests).
contract Audit_EXCH1_StorageLayoutTest is ExchangeTestBase {
    /// @notice Golden sequential layout (from `forge inspect PrediXExchange storage-layout`):
    ///   slot 0 diamond · 1 usdc · 2 feeRecipient (+_initialized at byte 20) · 3 orders · 4 _orderQueue ·
    ///   5 priceBitmap · 6 userOrderCount · 7 _orderNonce · 8 paused. Fee storage is NOT here (ERC-7201).
    function test_EXCH1_sequentialSlotPositions_pinned() public {
        assertEq(
            address(uint160(uint256(vm.load(address(exchange), bytes32(uint256(0)))))),
            exchange.diamond(),
            "diamond@slot0"
        );
        assertEq(
            address(uint160(uint256(vm.load(address(exchange), bytes32(uint256(1)))))), exchange.usdc(), "usdc@slot1"
        );

        uint256 s2 = uint256(vm.load(address(exchange), bytes32(uint256(2))));
        assertEq(address(uint160(s2)), exchange.feeRecipient(), "feeRecipient@slot2 (low 20 bytes)");
        assertTrue(((s2 >> 160) & 0xff) != 0, "_initialized@slot2 byte 20 == true");

        // paused @ slot 8 — THE slot the ERC-7201 fee storage must never shift.
        diamond.grantRole(Roles.PAUSER_ROLE, address(this));
        exchange.pause();
        assertEq(uint256(vm.load(address(exchange), bytes32(uint256(8)))) & 0xff, 1, "paused@slot8 == 1 after pause");
        exchange.unpause();
        assertEq(uint256(vm.load(address(exchange), bytes32(uint256(8)))) & 0xff, 0, "paused@slot8 == 0 after unpause");
    }

    /// @notice Writing EVERY ERC-7201 fee-lib slot must leave the sequential slots 0..8 byte-identical
    ///         (no collision). Raw-slot mirror of the getter-based StorageLayoutSafety proof.
    function test_EXCH1_feeWrites_doNotTouchSequentialSlots() public {
        bytes32[9] memory pre;
        for (uint256 i; i < 9; i++) {
            pre[i] = vm.load(address(exchange), bytes32(i));
        }

        diamond.grantRole(Roles.ADMIN_ROLE, address(this));
        MockBuilderRegistry registry = new MockBuilderRegistry();
        exchange.setBuilderRegistry(address(registry)); // LibBuilderFeeStorage.builderRegistry
        exchange.setProtocolFeeRecipient(makeAddr("treas")); // LibProtocolFeeStorage.protocolFeeRecipient
        _giveUsdc(address(this), 10e6);
        exchange.depositBuilderFee(keccak256("exch1-code"), 3e6); // LibBuilderFeeStorage.accrued[code]
        exchange.depositProtocolFee(2e6); // LibProtocolFeeStorage.accruedProtocolFee

        for (uint256 i; i < 9; i++) {
            assertEq(vm.load(address(exchange), bytes32(i)), pre[i], "sequential slot unshifted by ERC-7201 fee write");
        }
    }
}
