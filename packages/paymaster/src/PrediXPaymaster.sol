// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {BasePaymaster} from "@account-abstraction/contracts/core/BasePaymaster.sol";
import {IEntryPoint} from "@account-abstraction/contracts/interfaces/IEntryPoint.sol";
import {PackedUserOperation} from "@account-abstraction/contracts/interfaces/PackedUserOperation.sol";
import {UserOperationLib} from "@account-abstraction/contracts/core/UserOperationLib.sol";
import {_packValidationData} from "@account-abstraction/contracts/core/Helpers.sol";
import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import {MessageHashUtils} from "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";

import {IPrediXPaymaster} from "./interfaces/IPrediXPaymaster.sol";

/// @title PrediXPaymaster
/// @notice Self-hosted verifying paymaster. Sponsors UserOps signed by a BE signer.
///         Owner can rotate signer or pause all sponsorships in an incident.
/// @dev Pattern adapted from @account-abstraction/contracts/samples/VerifyingPaymaster
///      with: (a) mutable signer via setSigner(), (b) pause mechanism.
///      Hash of UserOp fields matches canonical getHash() to ensure off-chain signer
///      and on-chain verifier agree byte-for-byte.
contract PrediXPaymaster is BasePaymaster, IPrediXPaymaster {
    using UserOperationLib for PackedUserOperation;

    /// @dev paymasterAndData offsets per EntryPoint v0.7 spec.
    /// Layout: [0..20) paymaster | [20..36) verificationGasLimit | [36..52) postOpGasLimit
    ///         | [52..116) abi.encode(validUntil, validAfter) | [116..) signature
    uint256 private constant VALID_TIMESTAMP_OFFSET = 52;
    uint256 private constant SIGNATURE_OFFSET = VALID_TIMESTAMP_OFFSET + 64;

    address public signer;
    bool public paused;

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

        (uint48 validUntil, uint48 validAfter, bytes calldata sig) = parsePaymasterAndData(userOp.paymasterAndData);

        if (sig.length != 65) revert InvalidSignatureLength(sig.length);

        bytes32 hash = MessageHashUtils.toEthSignedMessageHash(getHash(userOp, validUntil, validAfter));

        if (signer != ECDSA.recover(hash, sig)) {
            return ("", _packValidationData(true, validUntil, validAfter));
        }

        return ("", _packValidationData(false, validUntil, validAfter));
    }
}
