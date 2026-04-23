// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";
import {EntryPoint} from "@account-abstraction/contracts/core/EntryPoint.sol";
import {IEntryPoint} from "@account-abstraction/contracts/interfaces/IEntryPoint.sol";
import {PackedUserOperation} from "@account-abstraction/contracts/interfaces/PackedUserOperation.sol";
import {MessageHashUtils} from "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";

import {PrediXPaymaster} from "../../src/PrediXPaymaster.sol";
import {IPrediXPaymaster} from "../../src/interfaces/IPrediXPaymaster.sol";

contract PrediXPaymasterTest is Test {
    using MessageHashUtils for bytes32;

    EntryPoint internal entryPoint;
    PrediXPaymaster internal paymaster;

    address internal owner = makeAddr("owner");
    address internal stranger = makeAddr("stranger");
    address internal userAccount = makeAddr("userAccount");

    uint256 internal signerKey;
    address internal signerAddr;

    uint256 internal attackerKey;
    address internal attackerAddr;

    function setUp() public {
        entryPoint = new EntryPoint();

        (signerAddr, signerKey) = makeAddrAndKey("signer");
        (attackerAddr, attackerKey) = makeAddrAndKey("attacker");

        paymaster = new PrediXPaymaster(IEntryPoint(address(entryPoint)), owner, signerAddr);

        vm.deal(owner, 1 ether);
        vm.prank(owner);
        paymaster.deposit{value: 0.1 ether}();
    }

    // ─────────────────────────── Constructor ───────────────────────────

    function test_Constructor_SetsOwnerAndSigner() public view {
        assertEq(paymaster.owner(), owner, "owner");
        assertEq(paymaster.signer(), signerAddr, "signer");
        assertFalse(paymaster.paused(), "paused");
    }

    function test_Revert_Constructor_ZeroOwner() public {
        vm.expectRevert(IPrediXPaymaster.ZeroAddress.selector);
        new PrediXPaymaster(IEntryPoint(address(entryPoint)), address(0), signerAddr);
    }

    function test_Revert_Constructor_ZeroSigner() public {
        vm.expectRevert(IPrediXPaymaster.ZeroAddress.selector);
        new PrediXPaymaster(IEntryPoint(address(entryPoint)), owner, address(0));
    }

    function test_Constructor_EmitsSignerChanged() public {
        vm.expectEmit(true, true, true, true);
        emit IPrediXPaymaster.SignerChanged(address(0), signerAddr);
        new PrediXPaymaster(IEntryPoint(address(entryPoint)), owner, signerAddr);
    }

    // ─────────────────────────── setSigner ───────────────────────────

    function test_SetSigner_UpdatesSignerAndEmits() public {
        address newSigner = makeAddr("newSigner");

        vm.expectEmit(true, true, true, true);
        emit IPrediXPaymaster.SignerChanged(signerAddr, newSigner);

        vm.prank(owner);
        paymaster.setSigner(newSigner);

        assertEq(paymaster.signer(), newSigner);
    }

    function test_Revert_SetSigner_OnlyOwner() public {
        vm.prank(stranger);
        vm.expectRevert(); // OZ Ownable custom error or string
        paymaster.setSigner(makeAddr("newSigner"));
    }

    function test_Revert_SetSigner_ZeroAddress() public {
        vm.prank(owner);
        vm.expectRevert(IPrediXPaymaster.ZeroAddress.selector);
        paymaster.setSigner(address(0));
    }

    // ─────────────────────────── pause / unpause ───────────────────────────

    function test_Pause_SetsPausedTrueAndEmits() public {
        vm.expectEmit(true, true, true, true);
        emit IPrediXPaymaster.Paused(owner);

        vm.prank(owner);
        paymaster.pause();

        assertTrue(paymaster.paused());
    }

    function test_Unpause_ResetsPausedAndEmits() public {
        vm.prank(owner);
        paymaster.pause();

        vm.expectEmit(true, true, true, true);
        emit IPrediXPaymaster.Unpaused(owner);

        vm.prank(owner);
        paymaster.unpause();

        assertFalse(paymaster.paused());
    }

    function test_Revert_Pause_OnlyOwner() public {
        vm.prank(stranger);
        vm.expectRevert();
        paymaster.pause();
    }

    function test_Revert_Unpause_OnlyOwner() public {
        vm.prank(owner);
        paymaster.pause();

        vm.prank(stranger);
        vm.expectRevert();
        paymaster.unpause();
    }

    // ─────────────────────────── validatePaymasterUserOp ───────────────────────────

    function test_ValidatePaymasterUserOp_ValidSignature_ReturnsValid() public {
        uint48 validUntil = uint48(block.timestamp + 300);
        uint48 validAfter = uint48(block.timestamp);

        PackedUserOperation memory userOp = _buildUserOp(validUntil, validAfter, signerKey);

        vm.prank(address(entryPoint));
        (bytes memory context, uint256 validationData) = paymaster.validatePaymasterUserOp(userOp, bytes32(0), 0);

        assertEq(context.length, 0, "context should be empty");
        // validationData layout: [aggregator 160][validUntil 48][validAfter 48]
        // aggregator = 0 (success), so lower 160 bits must be zero
        assertEq(validationData & uint256(type(uint160).max), 0, "signature failure flag should be false");
    }

    function test_ValidatePaymasterUserOp_InvalidSignature_ReturnsFailure() public {
        uint48 validUntil = uint48(block.timestamp + 300);
        uint48 validAfter = uint48(block.timestamp);

        // Sign with attacker key, not authorized signer
        PackedUserOperation memory userOp = _buildUserOp(validUntil, validAfter, attackerKey);

        vm.prank(address(entryPoint));
        (bytes memory context, uint256 validationData) = paymaster.validatePaymasterUserOp(userOp, bytes32(0), 0);

        assertEq(context.length, 0);
        // SIG_VALIDATION_FAILED = 1 in lower bits (aggregator = address(1))
        assertEq(validationData & uint256(type(uint160).max), 1, "should mark signature failure");
    }

    function test_Revert_ValidatePaymasterUserOp_Paused() public {
        vm.prank(owner);
        paymaster.pause();

        uint48 validUntil = uint48(block.timestamp + 300);
        uint48 validAfter = uint48(block.timestamp);
        PackedUserOperation memory userOp = _buildUserOp(validUntil, validAfter, signerKey);

        vm.prank(address(entryPoint));
        vm.expectRevert(IPrediXPaymaster.ContractPaused.selector);
        paymaster.validatePaymasterUserOp(userOp, bytes32(0), 0);
    }

    function test_Revert_ValidatePaymasterUserOp_WrongSignatureLength() public {
        uint48 validUntil = uint48(block.timestamp + 300);
        uint48 validAfter = uint48(block.timestamp);

        PackedUserOperation memory userOp = _buildUserOp(validUntil, validAfter, signerKey);

        // Truncate signature to 64 bytes (invalid length per our contract — we require exactly 65)
        bytes memory truncatedPmd = _truncatePaymasterSig(userOp.paymasterAndData, 64);
        userOp.paymasterAndData = truncatedPmd;

        vm.prank(address(entryPoint));
        vm.expectRevert(abi.encodeWithSelector(IPrediXPaymaster.InvalidSignatureLength.selector, uint256(64)));
        paymaster.validatePaymasterUserOp(userOp, bytes32(0), 0);
    }

    function test_ValidatePaymasterUserOp_ExpiredValidUntil_EncodesTimeGate() public {
        // validUntil in the past — canonical VerifyingPaymaster pattern:
        // paymaster does NOT revert; it packs validUntil into validationData
        // so EntryPoint auto-rejects on `block.timestamp > validUntil`.
        // This test locks in that contract-level behaviour (no ExpiredSponsorship
        // revert) so future refactors can't silently drift to reverting.
        uint48 validUntil = uint48(block.timestamp - 1);
        uint48 validAfter = 0;

        PackedUserOperation memory userOp = _buildUserOp(validUntil, validAfter, signerKey);

        vm.prank(address(entryPoint));
        (bytes memory context, uint256 validationData) = paymaster.validatePaymasterUserOp(userOp, bytes32(0), 0);

        assertEq(context.length, 0);

        // Signature is valid — aggregator field (lower 160 bits) must be 0.
        assertEq(validationData & uint256(type(uint160).max), 0, "signature must verify even when expired");

        // validUntil is packed at bits [160..208). Extract + assert.
        uint48 packedValidUntil = uint48(validationData >> 160);
        assertEq(packedValidUntil, validUntil, "validUntil must round-trip into validationData");
    }

    function test_Revert_ValidatePaymasterUserOp_NotFromEntryPoint() public {
        uint48 validUntil = uint48(block.timestamp + 300);
        uint48 validAfter = uint48(block.timestamp);
        PackedUserOperation memory userOp = _buildUserOp(validUntil, validAfter, signerKey);

        vm.prank(stranger);
        vm.expectRevert(); // BasePaymaster._requireFromEntryPoint reverts
        paymaster.validatePaymasterUserOp(userOp, bytes32(0), 0);
    }

    // ─────────────────────────── helpers ───────────────────────────

    function _buildUserOp(uint48 validUntil, uint48 validAfter, uint256 signingKey)
        internal
        view
        returns (PackedUserOperation memory userOp)
    {
        userOp = PackedUserOperation({
            sender: userAccount,
            nonce: 0,
            initCode: hex"",
            callData: hex"",
            accountGasLimits: bytes32((uint256(100000) << 128) | uint256(100000)),
            preVerificationGas: 50000,
            gasFees: bytes32((uint256(1 gwei) << 128) | uint256(1 gwei)),
            paymasterAndData: hex"",
            signature: hex""
        });

        // Build paymasterAndData with placeholder signature so getHash sees the gas-limit bytes
        // Layout: [20 paymaster][16 verifGas][16 postOpGas][32 validUntil][32 validAfter][65 sig placeholder]
        bytes memory pmd = abi.encodePacked(
            address(paymaster),
            uint128(100000), // paymasterVerificationGasLimit
            uint128(50000), // paymasterPostOpGasLimit
            abi.encode(validUntil, validAfter),
            new bytes(65) // placeholder — replaced after hash
        );
        userOp.paymasterAndData = pmd;

        bytes32 hash = paymaster.getHash(userOp, validUntil, validAfter);
        bytes32 ethSignedHash = hash.toEthSignedMessageHash();
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(signingKey, ethSignedHash);
        bytes memory sig = abi.encodePacked(r, s, v);

        // Replace the 65-byte signature placeholder at the tail
        userOp.paymasterAndData = abi.encodePacked(
            address(paymaster), uint128(100000), uint128(50000), abi.encode(validUntil, validAfter), sig
        );
    }

    function _truncatePaymasterSig(bytes memory pmd, uint256 sigLen) internal pure returns (bytes memory) {
        // Keep first 116 bytes (paymaster + gas limits + validUntil/After encoded), replace signature
        bytes memory prefix = new bytes(116);
        for (uint256 i = 0; i < 116; i++) {
            prefix[i] = pmd[i];
        }
        bytes memory sig = new bytes(sigLen);
        return bytes.concat(prefix, sig);
    }
}
