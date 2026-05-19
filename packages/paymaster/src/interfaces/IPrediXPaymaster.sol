// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

/// @title IPrediXPaymaster
/// @notice Errors + events + admin surface for the self-hosted verifying
///         paymaster. The implementation inherits ERC-4337 `BasePaymaster`.
///         Paymaster sponsors UserOps whose call target is on the
///         `allowedTarget` allowlist AND whose signature is from the
///         current `signer`. Owner controls signer, pause, and the allowlist.
interface IPrediXPaymaster {
    event SignerChanged(address indexed oldSigner, address indexed newSigner);
    event Paused(address indexed by);
    event Unpaused(address indexed by);
    /// @notice Emitted whenever the allowlist flag for `target` changes.
    /// @param target  The destination contract whose sponsorship status changed.
    /// @param allowed New flag value — `true` means UserOps calling `target`
    ///                are sponsorable; `false` means rejected at validation.
    event TargetAllowlistUpdated(address indexed target, bool allowed);

    error ContractPaused();
    error InvalidSignatureLength(uint256 actual);
    error ZeroAddress();
    /// @notice Reverts (via `_packValidationData(true,…)`) when the UserOp's
    ///         `callData` decodes to a destination contract that is not on
    ///         the allowlist. Audit PM-NEW-01 — without an on-chain
    ///         allowlist, a compromised signer could sponsor arbitrary
    ///         UserOps and drain the EntryPoint deposit.
    error TargetNotAllowed(address target);
    /// @notice Reverts when the UserOp's `callData` is too short to decode a
    ///         destination address (Account Abstraction `execute` selector
    ///         needs at least 4 + 32 bytes). Defense-in-depth so the
    ///         validation path fails with a clear selector instead of
    ///         panicking on the slice.
    error CallDataTooShort();
    /// @notice Reverts when the UserOp's `callData` selector is not the
    ///         canonical `execute(address,uint256,bytes)`. Prevents
    ///         `executeBatch` or arbitrary selectors from bypassing the
    ///         target allowlist by decoding the ABI offset pointer as an
    ///         address.
    error UnsupportedExecuteSelector();
    /// @notice Reverts when the owner attempts to allowlist a critical
    ///         infrastructure address (the paymaster itself or the
    ///         EntryPoint). Sponsoring UserOps that target these would let a
    ///         compromised signer drain the EntryPoint deposit.
    error CriticalTargetBlocked();

    function signer() external view returns (address);

    function paused() external view returns (bool);

    function setSigner(address newSigner) external;

    function pause() external;

    function unpause() external;

    /// @notice Returns whether `target` is currently sponsorable by this paymaster.
    function isTargetAllowed(address target) external view returns (bool);

    /// @notice Owner-only: add or remove `target` from the sponsorship allowlist.
    /// @dev Idempotent. Emits `TargetAllowlistUpdated` on every call so the
    ///      operational trail is preserved even for no-op sets.
    function setAllowedTarget(address target, bool allowed) external;
}
