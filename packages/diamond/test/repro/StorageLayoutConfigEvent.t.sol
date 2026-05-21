// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import {EventFixture} from "../utils/EventFixture.sol";

/// @title StorageLayoutConfigEvent
/// @notice Extends the diamond-storage slot pinning (see Audit_I03_StorageLayout,
///         which covers LibMarketStorage) to LibConfigStorage and LibEventStorage.
///         These layouts are append-only; any reorder, type change, or accidental
///         field insertion that shifts an existing slot is caught here before it
///         ships. Each field is written a DISTINCT value so a reorder cannot
///         coincidentally satisfy the assertion. Slot bases are reproduced inline
///         so a library rename cannot silently invalidate the pins.
contract StorageLayoutConfigEventTest is EventFixture {
    /// @dev Mirrors `LibConfigStorage.SLOT`.
    bytes32 internal constant CONFIG_STORAGE_SLOT = keccak256("predix.storage.config.v1");
    /// @dev Mirrors `LibEventStorage.SLOT`.
    bytes32 internal constant EVENT_STORAGE_SLOT = keccak256("predix.storage.event.v1");

    function _load(bytes32 slot) private view returns (uint256) {
        return uint256(vm.load(address(diamond), slot));
    }

    // ── LibConfigStorage.Layout ─────────────────────────────────────────

    /// @notice Pin each scalar field of LibConfigStorage.Layout to its slot.
    ///         Order: collateralToken(0), feeRecipient(1), marketCreationFee(2),
    ///         defaultPerMarketCap(3), approvedOracles mapping(4),
    ///         defaultRedemptionFeeBps(5).
    function test_ConfigStorageLayout_ScalarOffsets() public {
        // Distinct non-zero values so a reordered field cannot pass by chance.
        vm.startPrank(admin);
        market.setMarketCreationFee(777);
        market.setDefaultPerMarketCap(999);
        market.setDefaultRedemptionFeeBps(123);
        vm.stopPrank();

        uint256 base = uint256(CONFIG_STORAGE_SLOT);

        // collateralToken is bound once at init to the fixture's MockUSDC.
        assertEq(address(uint160(_load(bytes32(base + 0)))), address(usdc), "collateralToken @ base+0");
        assertEq(address(uint160(_load(bytes32(base + 1)))), feeRecipient, "feeRecipient @ base+1");
        assertEq(_load(bytes32(base + 2)), 777, "marketCreationFee @ base+2");
        assertEq(_load(bytes32(base + 3)), 999, "defaultPerMarketCap @ base+3");
        // base+4 is the approvedOracles mapping slot (no scalar lives there).
        assertEq(_load(bytes32(base + 5)), 123, "defaultRedemptionFeeBps @ base+5");
    }

    /// @notice Pin the approvedOracles mapping to base+4. Its entry for an
    ///         approved oracle lives at keccak256(oracle, base+4) and reads true.
    function test_ConfigStorageLayout_ApprovedOraclesMapping() public view {
        bytes32 mappingSlot = bytes32(uint256(CONFIG_STORAGE_SLOT) + 4);
        // The binary MockOracle is approved in MarketFixture.setUp.
        bytes32 entry = keccak256(abi.encode(address(oracle), mappingSlot));
        assertEq(_load(entry), 1, "approvedOracles[oracle] == true @ base+4");
    }

    // ── LibEventStorage.Layout + EventData ──────────────────────────────

    /// @notice Pin LibEventStorage.Layout (eventCount at base, events mapping at
    ///         base+1, marketToEvent mapping at base+2) and the upgrade-sensitive
    ///         EventData field offsets — especially slot 7, where the v1.1-appended
    ///         `oracle` packs with the two bools.
    function test_EventStorageLayout_FieldOffsets() public {
        uint256 endTime = block.timestamp + 7 days;
        (uint256 eventId, uint256[] memory marketIds) = _createThreeCandidateEvent(endTime);
        assertEq(eventId, 1, "first eventId");

        uint256 base = uint256(EVENT_STORAGE_SLOT);

        // base+0: eventCount.
        assertEq(_load(bytes32(base + 0)), 1, "eventCount @ base+0");

        // base+1: events mapping → EventData struct base.
        uint256 structBase = uint256(keccak256(abi.encode(eventId, bytes32(base + 1))));

        // EventData order: name(0) marketIds(1) endTime(2) creator(3)
        // resolvedAt(4) refundEnabledAt(5) winningIndex(6)
        // {isResolved,refundModeActive,oracle}(7, packed).
        assertEq(_load(bytes32(structBase + 2)), endTime, "EventData.endTime @ struct+2");
        assertEq(address(uint160(_load(bytes32(structBase + 3)))), alice, "EventData.creator @ struct+3");

        // Slot 7 packing: isResolved (byte0), refundModeActive (byte1),
        // oracle (bytes 2..21). Fresh event → both bools false.
        uint256 packed = _load(bytes32(structBase + 7));
        assertEq(packed & 0xFF, 0, "isResolved=false @ slot7 byte0");
        assertEq((packed >> 8) & 0xFF, 0, "refundModeActive=false @ slot7 byte1");
        assertEq(address(uint160(packed >> 16)), address(eventOracle), "EventData.oracle @ slot7 bytes2..21");

        // base+2: marketToEvent mapping → each child marketId maps to eventId.
        bytes32 m2eEntry = keccak256(abi.encode(marketIds[0], bytes32(base + 2)));
        assertEq(_load(m2eEntry), eventId, "marketToEvent[child] @ base+2");
    }
}
