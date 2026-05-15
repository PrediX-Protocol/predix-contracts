// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import {IMarketFacet} from "@predix/shared/interfaces/IMarketFacet.sol";

import {MarketFixture} from "../utils/MarketFixture.sol";

/// @title Audit_I03_StorageLayout
/// @notice Audit I-03: pin the diamond-storage slot positions for
///         `LibMarketStorage` so any append-only violation (reorder, type
///         change, or accidental insertion) is caught by CI before it ships.
///         The keccak slot base is reproduced inline so the test stays valid
///         even if the library is later renamed.
contract Audit_I03_StorageLayoutTest is MarketFixture {
    /// @dev Mirrors `LibMarketStorage.SLOT` exactly. Reproduced here so a
    ///      rename / refactor of the constant cannot silently invalidate
    ///      the test.
    bytes32 internal constant MARKET_STORAGE_SLOT = keccak256("predix.storage.market.v1");

    /// @notice After creating a market, `LibMarketStorage.Layout.marketCount`
    ///         (the first field) must read 1 at the base slot.
    function test_I03_MarketStorageSlot_BasePosition() public {
        _createMarket(block.timestamp + 7 days);
        bytes32 raw = vm.load(address(diamond), MARKET_STORAGE_SLOT);
        assertEq(uint256(raw), 1, "marketCount lives at slot[base]");
    }

    /// @notice The `markets` mapping starts at offset 1 from the base slot,
    ///         i.e. its values live at `keccak256(marketId, baseSlot + 1)`.
    ///         Reproduce the slot derivation Solidity uses and probe
    ///         `MarketData.endTime` (offset 1 within the struct).
    function test_I03_MarketStorageSlot_MarketsMapping() public {
        uint256 endTime = block.timestamp + 7 days;
        uint256 marketId = _createMarket(endTime);

        // diamond-storage `markets` lives at base+1. Solidity mapping slot
        // derivation: keccak256(abi.encode(key, mappingSlot)).
        bytes32 mappingSlot = bytes32(uint256(MARKET_STORAGE_SLOT) + 1);
        bytes32 marketStructSlot = keccak256(abi.encode(marketId, mappingSlot));

        // `MarketData` field order: question (slot 0), endTime (slot 1), ...
        bytes32 endTimeSlot = bytes32(uint256(marketStructSlot) + 1);
        uint256 storedEndTime = uint256(vm.load(address(diamond), endTimeSlot));
        assertEq(storedEndTime, endTime, "endTime at struct offset 1");
    }

    /// @notice Slot 12 of `MarketData` packs three small fields together
    ///         per audit N-13:
    ///           perMarketRedemptionFeeBps  (uint16, 2 bytes — declared first)
    ///           redemptionFeeOverridden    (bool,   1 byte)
    ///           snapshottedDefaultRedemptionFeeBps (uint16, 2 bytes)
    ///         A future maintainer inserting a new field BEFORE these would
    ///         shift them off slot 12 and break upgrades.
    function test_I03_MarketStorageSlot_RedemptionFeePacking() public {
        uint256 marketId = _createMarket(block.timestamp + 7 days);

        // Flip the override flag so the packed slot has at least one
        // distinguishable non-zero byte to read back.
        vm.prank(admin);
        market.setPerMarketRedemptionFeeBps(marketId, 0);

        bytes32 mappingSlot = bytes32(uint256(MARKET_STORAGE_SLOT) + 1);
        bytes32 marketStructSlot = keccak256(abi.encode(marketId, mappingSlot));

        // `MarketData` field offsets:
        //   slot 0  question
        //   slot 1  endTime
        //   slot 2  oracle (20-byte addr alone — next field is also 20-byte)
        //   slot 3  creator
        //   slot 4  yesToken
        //   slot 5  noToken
        //   slot 6  totalCollateral
        //   slot 7  perMarketCap
        //   slot 8  resolvedAt
        //   slot 9  refundEnabledAt
        //   slot 10 isResolved + outcome + refundModeActive (3 bools packed)
        //   slot 11 eventId
        //   slot 12 perMarketRedemptionFeeBps + redemptionFeeOverridden
        //           + snapshottedDefaultRedemptionFeeBps  (THIS SLOT)
        bytes32 packedSlot = bytes32(uint256(marketStructSlot) + 12);
        uint256 packed = uint256(vm.load(address(diamond), packedSlot));

        // Solidity packs first-declared into the lowest bytes:
        //   bytes [0..1]   perMarketRedemptionFeeBps (uint16) = 0
        //   byte  [2]      redemptionFeeOverridden  (bool)   = 1
        //   bytes [3..4]   snapshottedDefaultRedemptionFeeBps = 0
        uint16 fee = uint16(packed & 0xFFFF);
        bool overridden = ((packed >> 16) & 0xFF) != 0;
        uint16 snapshot = uint16((packed >> 24) & 0xFFFF);

        assertEq(fee, 0, "perMarketRedemptionFeeBps at lowest 2 bytes");
        assertTrue(overridden, "redemptionFeeOverridden at byte 2");
        assertEq(snapshot, 0, "snapshottedDefaultRedemptionFeeBps at bytes 3..4");
    }
}
