// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import {IEventFacet} from "@predix/shared/interfaces/IEventFacet.sol";

import {LinkedEventFixture} from "../utils/LinkedEventFixture.sol";

/// @title Gap1UpgradeStorageBrick
/// @notice AUDIT (upgrade/storage lens). Proves the Gap#1 append of `EventData.linked` (slot 7, byte 22)
///         and `EventData.redemptionFeeBps` (slot 7, bytes 23-24) into the SAME slot that already holds
///         `isResolved`/`refundModeActive`/`oracle` cannot brick an event that was written by PRE-Gap#1
///         bytecode. We forge a pre-upgrade EventData directly into the diamond's diamond-storage slot
///         (slot-7 tail left zero, exactly as the old compiler would have left it) and then read it back
///         through the NEW facet code. Append-only is correct iff: the pre-existing slot-7 fields survive
///         AND the appended fields read as their zero defaults (not garbage from the address tail).
/// @dev Audit-only; no engine src touched. Mirrors the compiler offsets independently verified via
///      `forge inspect Gap1LayoutProbe storage-layout`.
contract Gap1UpgradeStorageBrick is LinkedEventFixture {
    // keccak256("predix.storage.event.v1") — LibEventStorage.SLOT.
    bytes32 internal constant EVENT_SLOT = keccak256("predix.storage.event.v1");

    function test_PreUpgradeEvent_SurvivesAppend_NoBrick() public {
        // Layout: eventCount @ SLOT, events mapping @ SLOT+1. events[eventId] base = keccak(eventId, SLOT+1).
        uint256 eventId = 7;
        bytes32 base = keccak256(abi.encode(eventId, uint256(EVENT_SLOT) + 1));

        address legacyOracle = address(0xBEEF);
        uint256 legacyEnd = block.timestamp + 100 days;
        address legacyCreator = address(0xCAFE);

        // base+2 endTime, base+3 creator (so `_event` passes its creator!=0 existence check).
        vm.store(address(diamond), bytes32(uint256(base) + 2), bytes32(legacyEnd));
        vm.store(address(diamond), bytes32(uint256(base) + 3), bytes32(uint256(uint160(legacyCreator))));

        // base+7 packed EXACTLY as pre-Gap#1 bytecode would: byte0 isResolved=1, byte1 refundModeActive=0,
        // bytes2-21 oracle. Bytes 22-31 (the future `linked`/`redemptionFeeBps`) are LEFT ZERO — this is
        // the only state a pre-upgrade write could have produced (per-field masked writes never touch them).
        uint256 slot7 = uint256(1) /* isResolved @ byte0 */ | (uint256(uint160(legacyOracle)) << (8 * 2));
        vm.store(address(diamond), bytes32(uint256(base) + 7), bytes32(slot7));

        // --- Read through NEW facet code ---
        // 1. Appended `linked` must read false (NOT a non-zero leak from the oracle bytes below it).
        assertFalse(linked.isLinkedEvent(eventId), "BRICK: appended `linked` read non-false for legacy event");

        // 2. Pre-existing slot-7 fields must be intact after the append.
        IEventFacet.EventView memory e = eventFacet.getEvent(eventId);
        assertEq(e.oracle, legacyOracle, "BRICK: oracle corrupted by slot-7 tail append");
        assertTrue(e.isResolved, "BRICK: isResolved corrupted");
        assertFalse(e.refundModeActive, "BRICK: refundModeActive corrupted");
        assertEq(e.endTime, legacyEnd, "BRICK: endTime corrupted");
        assertEq(e.creator, legacyCreator, "BRICK: creator corrupted");
    }

    function test_PreUpgradeEvent_DirtyAddressBits_DoNotLeakIntoLinked() public {
        // Adversarial: pack the MAXIMUM oracle address (all 20 bytes set) so byte 21 is 0xFF. If `linked`
        // (byte 22) were mis-offset by even one byte, it would read 0xFF (true). It must still read false.
        uint256 eventId = 99;
        bytes32 base = keccak256(abi.encode(eventId, uint256(EVENT_SLOT) + 1));
        vm.store(address(diamond), bytes32(uint256(base) + 3), bytes32(uint256(uint160(address(0xCAFE)))));
        address maxOracle = address(type(uint160).max);
        uint256 slot7 = uint256(1) | (uint256(uint160(maxOracle)) << (8 * 2));
        vm.store(address(diamond), bytes32(uint256(base) + 7), bytes32(slot7));

        assertFalse(linked.isLinkedEvent(eventId), "BRICK: `linked` aliases the oracle's high byte");
        assertEq(eventFacet.getEvent(eventId).oracle, maxOracle, "oracle mismatch under max-address pack");
    }
}
