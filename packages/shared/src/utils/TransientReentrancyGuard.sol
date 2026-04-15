// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

/// @title TransientReentrancyGuard
/// @notice EIP-1153 transient-storage reentrancy guard.
/// @dev Cheaper than the storage-slot variant because the slot is auto-cleared at
///      the end of the transaction. The slot is namespaced by `keccak256("predix.reentrancy.v1") - 1`
///      to avoid clashing with any consumer's transient storage.
abstract contract TransientReentrancyGuard {
    /// @notice Thrown when a `nonReentrant` function is re-entered within the same transaction.
    error ReentrantCall();

    uint256 private constant _NOT_ENTERED = 0;
    uint256 private constant _ENTERED = 1;

    bytes32 private constant _SLOT = bytes32(uint256(keccak256("predix.reentrancy.v1")) - 1);

    modifier nonReentrant() {
        bytes32 slot = _SLOT;
        uint256 status;
        assembly ("memory-safe") {
            status := tload(slot)
        }
        if (status == _ENTERED) revert ReentrantCall();
        assembly ("memory-safe") {
            tstore(slot, _ENTERED)
        }
        _;
        assembly ("memory-safe") {
            tstore(slot, _NOT_ENTERED)
        }
    }
}
