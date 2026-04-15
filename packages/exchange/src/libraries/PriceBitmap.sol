// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

/// @title PriceBitmap
/// @notice Bit-level operations on the Exchange price-index bitmap.
/// @dev A 99-bit bitmap (indices 0..98) maps price level (i+1)*PRICE_TICK to bit i.
///      All functions assume callers have already checked `bitmap != 0` where relevant.
library PriceBitmap {
    /// @notice Index of the lowest set bit — the cheapest (best-ask) price level.
    /// @dev Binary search over up to 128 bits via assembly. Undefined for `bitmap == 0`.
    function lowestBit(uint256 bitmap) internal pure returns (uint8 idx) {
        uint256 isolated = bitmap & (~bitmap + 1);
        assembly ("memory-safe") {
            idx := 0
            if iszero(and(isolated, 0xFFFFFFFFFFFFFFFF)) {
                idx := 64
                isolated := shr(64, isolated)
            }
            if iszero(and(isolated, 0xFFFFFFFF)) {
                idx := add(idx, 32)
                isolated := shr(32, isolated)
            }
            if iszero(and(isolated, 0xFFFF)) {
                idx := add(idx, 16)
                isolated := shr(16, isolated)
            }
            if iszero(and(isolated, 0xFF)) {
                idx := add(idx, 8)
                isolated := shr(8, isolated)
            }
            if iszero(and(isolated, 0xF)) {
                idx := add(idx, 4)
                isolated := shr(4, isolated)
            }
            if iszero(and(isolated, 0x3)) {
                idx := add(idx, 2)
                isolated := shr(2, isolated)
            }
            if iszero(and(isolated, 0x1)) { idx := add(idx, 1) }
        }
    }

    /// @notice Index of the highest set bit — the most expensive (best-bid) price level.
    /// @dev Binary search over up to 128 bits via assembly. Undefined for `bitmap == 0`.
    function highestBit(uint256 bitmap) internal pure returns (uint8 idx) {
        uint256 v = bitmap;
        assembly ("memory-safe") {
            idx := 0
            if gt(v, 0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF) {
                idx := 128
                v := shr(128, v)
            }
            if gt(v, 0xFFFFFFFFFFFFFFFF) {
                idx := add(idx, 64)
                v := shr(64, v)
            }
            if gt(v, 0xFFFFFFFF) {
                idx := add(idx, 32)
                v := shr(32, v)
            }
            if gt(v, 0xFFFF) {
                idx := add(idx, 16)
                v := shr(16, v)
            }
            if gt(v, 0xFF) {
                idx := add(idx, 8)
                v := shr(8, v)
            }
            if gt(v, 0xF) {
                idx := add(idx, 4)
                v := shr(4, v)
            }
            if gt(v, 0x3) {
                idx := add(idx, 2)
                v := shr(2, v)
            }
            if gt(v, 0x1) { idx := add(idx, 1) }
        }
    }

    /// @notice Return `bitmap` with bit `idx` set.
    function set(uint256 bitmap, uint8 idx) internal pure returns (uint256) {
        return bitmap | (uint256(1) << idx);
    }

    /// @notice Return `bitmap` with bit `idx` cleared.
    function clear(uint256 bitmap, uint8 idx) internal pure returns (uint256) {
        return bitmap & ~(uint256(1) << idx);
    }
}
