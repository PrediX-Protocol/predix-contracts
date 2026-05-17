// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import {BasePaymaster} from "@account-abstraction/contracts/core/BasePaymaster.sol";
import {IEntryPoint} from "@account-abstraction/contracts/interfaces/IEntryPoint.sol";
import {PackedUserOperation} from "@account-abstraction/contracts/interfaces/PackedUserOperation.sol";
import {UserOperationLib} from "@account-abstraction/contracts/core/UserOperationLib.sol";
import {_packValidationData} from "@account-abstraction/contracts/core/Helpers.sol";
import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import {MessageHashUtils} from "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";

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
contract PrediXPaymaster is BasePaymaster, IPrediXPaymaster {
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

    /// @notice Decode the destination contract from an ERC-4337
    ///         `execute(address,uint256,bytes)` callData payload. Reverts
    ///         `CallDataTooShort` if `callData` is shorter than the minimum
    ///         decodable layout. Audit PM-NEW-01.
    function _decodeExecuteTarget(bytes calldata callData) private pure returns (address dest) {
        if (callData.length < EXECUTE_CALLDATA_MIN) revert CallDataTooShort();
        // First parameter of `execute(address,uint256,bytes)` lives at
        // calldata offset 4 (after the selector). `address` is left-padded
        // into a 32-byte head — read the head, cast to address.
        dest = address(uint160(uint256(bytes32(callData[EXECUTE_DEST_HEAD_OFFSET:EXECUTE_DEST_HEAD_OFFSET + 32]))));
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
        // for the bundler; a UserOp signed for an unallowed target is invalid
        // regardless of signature legitimacy.
        address dest = _decodeExecuteTarget(userOp.callData);
        if (!allowedTarget[dest]) revert TargetNotAllowed(dest);

        (uint48 validUntil, uint48 validAfter, bytes calldata sig) = parsePaymasterAndData(userOp.paymasterAndData);

        if (sig.length != 65) revert InvalidSignatureLength(sig.length);

        bytes32 hash = MessageHashUtils.toEthSignedMessageHash(getHash(userOp, validUntil, validAfter));

        if (signer != ECDSA.recover(hash, sig)) {
            return ("", _packValidationData(true, validUntil, validAfter));
        }

        return ("", _packValidationData(false, validUntil, validAfter));
    }
}
