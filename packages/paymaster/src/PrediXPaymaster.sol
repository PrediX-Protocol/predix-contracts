// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import {BasePaymaster} from "@account-abstraction/contracts/core/BasePaymaster.sol";
import {IEntryPoint} from "@account-abstraction/contracts/interfaces/IEntryPoint.sol";
import {PackedUserOperation} from "@account-abstraction/contracts/interfaces/PackedUserOperation.sol";
import {UserOperationLib} from "@account-abstraction/contracts/core/UserOperationLib.sol";
import {_packValidationData} from "@account-abstraction/contracts/core/Helpers.sol";
import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import {MessageHashUtils} from "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";

import {IPrediXPaymaster} from "./interfaces/IPrediXPaymaster.sol";

/// @title PrediXPaymaster
/// @notice Self-hosted verifying paymaster. Sponsors UserOps signed by a BE
///         signer whose call target is on the on-chain allowlist.
/// @dev Pattern adapted from `@account-abstraction/contracts/samples/VerifyingPaymaster`
///      with three protocol-specific additions:
///      (a) mutable signer via `setSigner`,
///      (b) pause mechanism via `pause`/`unpause`,
///      (c) on-chain target allowlist (audit PM-NEW-01) — even a compromised
///          signer cannot direct sponsored UserOps at destinations the owner
///          has not explicitly authorized.
///      (d) two-step, non-renounceable ownership (`Ownable2Step`) so a
///          mistyped `transferOwnership` is recoverable (the nominee must
///          accept) and the paymaster can never be left ownerless with its
///          EntryPoint deposit/stake stranded.
contract PrediXPaymaster is BasePaymaster, Ownable2Step, IPrediXPaymaster {
    using UserOperationLib for PackedUserOperation;

    /// @dev paymasterAndData offsets per EntryPoint v0.7 spec.
    /// Layout: [0..20) paymaster | [20..36) verificationGasLimit | [36..52) postOpGasLimit
    ///         | [52..116) abi.encode(validUntil, validAfter) | [116..) signature
    uint256 private constant VALID_TIMESTAMP_OFFSET = 52;
    uint256 private constant SIGNATURE_OFFSET = VALID_TIMESTAMP_OFFSET + 64;

    /// @dev ERC-4337 smart accounts dispatch sponsored work via
    ///      `execute(address dest, uint256 value, bytes data)`. The decoded
    ///      `dest` is the destination contract we allowlist-check. UserOps
    ///      whose `callData` does not match this 100-byte minimum layout
    ///      (selector + 3×32-byte heads + payload) are rejected so the
    ///      allowlist is enforced uniformly.
    uint256 private constant EXECUTE_CALLDATA_MIN = 4 + 32 + 32 + 32;
    uint256 private constant EXECUTE_DEST_HEAD_OFFSET = 4;

    /// @dev Legacy SimpleAccount single-call entry `execute(address,uint256,bytes)`.
    ///      Kept for backward compatibility alongside the ERC-7579 entry below.
    ///      The old `executeBatch(address[],uint256[],bytes[])` and any other
    ///      non-`execute` selector remain rejected (`UnsupportedExecuteSelector`).
    bytes4 private constant EXECUTE_SELECTOR = bytes4(keccak256("execute(address,uint256,bytes)"));

    /// @dev ERC-7579 batched executor entry used by Kernel v3 / ZeroDev (and any
    ///      ERC-7579 account): `execute(bytes32 mode, bytes executionCalldata)`.
    ///      `mode`'s most-significant byte is the call type (single/batch/delegatecall).
    bytes4 private constant EXECUTE_7579_SELECTOR = bytes4(keccak256("execute(bytes32,bytes)"));

    /// @dev ERC-20 `approve(address spender,uint256)`. Sponsorable even when the
    ///      token itself is not allowlisted, PROVIDED the `spender` (allowance
    ///      grantee) IS allowlisted — so the first-trade `[approve(Router), trade]`
    ///      batch and sell-side `approve(YES/NO → Router)` (per-market tokens) are
    ///      sponsorable, while an `approve` to a non-protocol address is rejected.
    bytes4 private constant APPROVE_SELECTOR = bytes4(keccak256("approve(address,uint256)"));

    /// @dev ERC-7579 mode call types (the most-significant byte of `mode`).
    bytes1 private constant CALLTYPE_SINGLE = 0x00;
    bytes1 private constant CALLTYPE_BATCH = 0x01;

    /// @dev ERC-7579 single `executionCalldata` = packed(target(20) | value(32) | data).
    ///      Need at least the (target, value) prefix; `data` may be empty.
    uint256 private constant EXEC_7579_SINGLE_MIN = 20 + 32;

    /// @dev Upper bound on ERC-7579 batch fan-out checked during validation —
    ///      bounds validation-gas cost; an oversized batch fails loud (`BatchTooLarge`).
    uint256 private constant MAX_BATCH_CALLS = 16;

    /// @dev ERC-7579 batch element. Mirrors OpenZeppelin `draft-IERC7579.Execution`
    ///      (defined locally — the paymaster's OZ remapping predates the 7579
    ///      utils). Types the calldata batch decoded in `_decode7579Batch`.
    struct Execution {
        address target;
        uint256 value;
        bytes callData;
    }

    address public signer;
    bool public paused;

    /// @notice Allowlist of destination contracts the paymaster will sponsor.
    ///         Owner manages via `setAllowedTarget`.
    mapping(address target => bool allowed) public allowedTarget;

    constructor(IEntryPoint entryPoint_, address owner_, address signer_) BasePaymaster(entryPoint_) {
        if (owner_ == address(0)) revert ZeroAddress();
        if (signer_ == address(0)) revert ZeroAddress();
        if (owner_ != msg.sender) {
            _transferOwnership(owner_);
        }
        signer = signer_;
        emit SignerChanged(address(0), signer_);
    }

    // ======== Ownership (two-step, non-renounceable) ========

    /// @dev Nominates `newOwner`; the transfer only takes effect once the
    ///      nominee calls `acceptOwnership`. Owner-only check is enforced by the
    ///      resolved `Ownable2Step.transferOwnership`. Resolves the
    ///      diamond-inherited definition explicitly.
    function transferOwnership(address newOwner) public override(Ownable, Ownable2Step) {
        super.transferOwnership(newOwner);
    }

    /// @dev Clears any pending nominee then assigns the owner (Ownable2Step).
    function _transferOwnership(address newOwner) internal override(Ownable, Ownable2Step) {
        super._transferOwnership(newOwner);
    }

    /// @dev Disabled: the paymaster must always retain an owner so the signer,
    ///      pause flag, and EntryPoint deposit/stake stay controllable.
    function renounceOwnership() public pure override {
        revert OwnershipRenounceDisabled();
    }

    /// @inheritdoc IPrediXPaymaster
    function setSigner(address newSigner) external override onlyOwner {
        if (newSigner == address(0)) revert ZeroAddress();
        emit SignerChanged(signer, newSigner);
        signer = newSigner;
    }

    /// @inheritdoc IPrediXPaymaster
    function pause() external override onlyOwner {
        paused = true;
        emit Paused(msg.sender);
    }

    /// @inheritdoc IPrediXPaymaster
    function unpause() external override onlyOwner {
        paused = false;
        emit Unpaused(msg.sender);
    }

    /// @inheritdoc IPrediXPaymaster
    function setAllowedTarget(address target, bool allowed) external override onlyOwner {
        if (target == address(0)) revert ZeroAddress();
        if (target == address(this) || target == address(entryPoint)) revert CriticalTargetBlocked();
        allowedTarget[target] = allowed;
        emit TargetAllowlistUpdated(target, allowed);
    }

    /// @inheritdoc IPrediXPaymaster
    function isTargetAllowed(address target) external view override returns (bool) {
        return allowedTarget[target];
    }

    /// @notice Hash the off-chain signer covers. Excludes paymasterAndData.signature (circular).
    /// @dev Must match BE's signer.service computation byte-for-byte.
    function getHash(PackedUserOperation calldata userOp, uint48 validUntil, uint48 validAfter)
        public
        view
        returns (bytes32)
    {
        return keccak256(
            abi.encode(
                userOp.getSender(),
                userOp.nonce,
                keccak256(userOp.initCode),
                keccak256(userOp.callData),
                userOp.accountGasLimits,
                uint256(
                    bytes32(
                        userOp.paymasterAndData[UserOperationLib.PAYMASTER_VALIDATION_GAS_OFFSET:VALID_TIMESTAMP_OFFSET]
                    )
                ),
                userOp.preVerificationGas,
                userOp.gasFees,
                block.chainid,
                address(this),
                validUntil,
                validAfter
            )
        );
    }

    function parsePaymasterAndData(bytes calldata paymasterAndData)
        public
        pure
        returns (uint48 validUntil, uint48 validAfter, bytes calldata signature)
    {
        (validUntil, validAfter) = abi.decode(paymasterAndData[VALID_TIMESTAMP_OFFSET:], (uint48, uint48));
        signature = paymasterAndData[SIGNATURE_OFFSET:];
    }

    /// @notice Enforce that EVERY destination this UserOp will call is
    ///         sponsorable. Supports the legacy SimpleAccount
    ///         `execute(address,uint256,bytes)` (single, target-only check) and
    ///         the ERC-7579 `execute(bytes32,bytes)` used by Kernel v3 — both
    ///         single (`0x00`) and batch (`0x01`) call types. Reverts loud +
    ///         typed on any unsupported shape or disallowed target so the
    ///         allowlist (PM-NEW-01) is enforced uniformly. Delegatecall and
    ///         unknown call types are rejected.
    function _enforceCallTargets(bytes calldata callData) private view {
        if (callData.length < 4) revert CallDataTooShort();
        bytes4 sel = bytes4(callData[:4]);

        if (sel == EXECUTE_SELECTOR) {
            // Legacy SimpleAccount execute(address dest, uint256 value, bytes data).
            // Target-only allowlist check — unchanged historical behaviour.
            if (callData.length < EXECUTE_CALLDATA_MIN) revert CallDataTooShort();
            address dest =
                address(uint160(uint256(bytes32(callData[EXECUTE_DEST_HEAD_OFFSET:EXECUTE_DEST_HEAD_OFFSET + 32]))));
            if (!allowedTarget[dest]) revert TargetNotAllowed(dest);
            return;
        }

        if (sel == EXECUTE_7579_SELECTOR) {
            (bytes1 callType, bytes calldata executionCalldata) = _decode7579Mode(callData);

            if (callType == CALLTYPE_SINGLE) {
                if (executionCalldata.length < EXEC_7579_SINGLE_MIN) revert CallDataTooShort();
                address target = address(bytes20(executionCalldata[0:20]));
                _requireSponsorable(target, executionCalldata[52:]);
                return;
            }

            if (callType == CALLTYPE_BATCH) {
                Execution[] calldata executions = _decode7579Batch(executionCalldata);
                uint256 n = executions.length;
                if (n == 0 || n > MAX_BATCH_CALLS) revert BatchTooLarge(n);
                for (uint256 i; i < n; ++i) {
                    _requireSponsorable(executions[i].target, executions[i].callData);
                }
                return;
            }

            // Delegatecall (0xff) or any other call type is not sponsorable.
            revert UnsupportedCallType(callType);
        }

        revert UnsupportedExecuteSelector();
    }

    /// @notice A call to `target` is sponsorable when `target` is allowlisted, OR
    ///         it is an ERC-20 `approve(spender, …)` whose `spender` is
    ///         allowlisted (Policy A — lets an account grant Router/Diamond the
    ///         allowance a trade needs without the token itself being
    ///         allowlisted; covers the first-trade approve+trade batch and
    ///         per-market YES/NO sell approvals). Reverts `TargetNotAllowed`
    ///         otherwise.
    function _requireSponsorable(address target, bytes calldata innerCallData) private view {
        if (allowedTarget[target]) return;
        // approve(address spender, uint256 amount): selector(4) + spender(32) + amount(32).
        if (innerCallData.length >= 36 && bytes4(innerCallData[0:4]) == APPROVE_SELECTOR) {
            address spender = address(uint160(uint256(bytes32(innerCallData[4:36]))));
            if (allowedTarget[spender]) return;
        }
        revert TargetNotAllowed(target);
    }

    /// @notice Split ERC-7579 `execute(bytes32 mode, bytes executionCalldata)`
    ///         into the call type (high byte of `mode`) and the `executionCalldata`
    ///         calldata slice. Bounds-checked so a malformed payload reverts
    ///         `CallDataTooShort` instead of an opaque panic.
    function _decode7579Mode(bytes calldata callData)
        private
        pure
        returns (bytes1 callType, bytes calldata executionCalldata)
    {
        // Layout: selector(4) | mode(32) | offset(32) | len(32) | data(len, padded).
        if (callData.length < 100) revert CallDataTooShort();
        callType = callData[4]; // mode's most-significant byte
        uint256 off = uint256(bytes32(callData[36:68])); // offset to executionCalldata, relative to args (byte 4)
        if (off > callData.length - 36) revert CallDataTooShort(); // ensure the length word fits
        uint256 lenPos = 4 + off;
        uint256 execLen = uint256(bytes32(callData[lenPos:lenPos + 32]));
        uint256 dataStart = lenPos + 32;
        if (execLen > callData.length - dataStart) revert CallDataTooShort();
        executionCalldata = callData[dataStart:dataStart + execLen];
    }

    /// @notice Decode an ERC-7579 batch `executionCalldata` (`abi.encode(Execution[])`)
    ///         into a calldata array. Bounds checks mirror OpenZeppelin
    ///         `ERC7579Utils.decodeBatch` (v5.5.0); a malformed buffer reverts
    ///         `CallDataTooShort`. Per-element calldata validity is checked by
    ///         Solidity when each element is accessed in the caller's loop.
    function _decode7579Batch(bytes calldata executionCalldata)
        private
        pure
        returns (Execution[] calldata executions)
    {
        unchecked {
            uint256 bufferLength = executionCalldata.length;
            if (bufferLength < 0x20) revert CallDataTooShort();
            uint256 arrayLengthOffset = uint256(bytes32(executionCalldata[0x00:0x20]));
            if (arrayLengthOffset > bufferLength - 0x20) revert CallDataTooShort();
            uint256 arrayLength = uint256(bytes32(executionCalldata[arrayLengthOffset:arrayLengthOffset + 0x20]));
            if (arrayLength > type(uint64).max || bufferLength - arrayLengthOffset - 0x20 < arrayLength * 0x20) {
                revert CallDataTooShort();
            }
            assembly ("memory-safe") {
                executions.offset := add(add(executionCalldata.offset, arrayLengthOffset), 0x20)
                executions.length := arrayLength
            }
        }
    }

    function _validatePaymasterUserOp(
        PackedUserOperation calldata userOp,
        bytes32,
        /*userOpHash*/
        uint256 /*maxCost*/
    )
        internal
        view
        override
        returns (bytes memory context, uint256 validationData)
    {
        if (paused) revert ContractPaused();

        // Allowlist check BEFORE signature verification. Cheaper failure path
        // for the bundler; a UserOp whose decoded call target(s) are not
        // sponsorable is invalid regardless of signature legitimacy. Covers the
        // legacy single `execute` and the ERC-7579 single + batch shapes.
        _enforceCallTargets(userOp.callData);

        (uint48 validUntil, uint48 validAfter, bytes calldata sig) = parsePaymasterAndData(userOp.paymasterAndData);

        if (sig.length != 65) revert InvalidSignatureLength(sig.length);

        bytes32 hash = MessageHashUtils.toEthSignedMessageHash(getHash(userOp, validUntil, validAfter));

        if (signer != ECDSA.recover(hash, sig)) {
            return ("", _packValidationData(true, validUntil, validAfter));
        }

        return ("", _packValidationData(false, validUntil, validAfter));
    }
}
