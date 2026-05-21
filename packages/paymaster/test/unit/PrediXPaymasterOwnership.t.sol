// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import {Test} from "forge-std/Test.sol";
import {EntryPoint} from "@account-abstraction/contracts/core/EntryPoint.sol";
import {IEntryPoint} from "@account-abstraction/contracts/interfaces/IEntryPoint.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

import {PrediXPaymaster} from "../../src/PrediXPaymaster.sol";
import {IPrediXPaymaster} from "../../src/interfaces/IPrediXPaymaster.sol";

/// @notice Pins two-step, non-renounceable paymaster ownership
///         (`Ownable2Step`), replacing the bare
///         single-step `Ownable`. A mistyped transfer is recoverable (the
///         nominee must accept) and the paymaster can never be left ownerless
///         with its EntryPoint deposit/stake stranded.
contract PrediXPaymasterOwnershipTest is Test {
    EntryPoint internal entryPoint;
    PrediXPaymaster internal paymaster;

    address internal owner = makeAddr("owner");
    address internal newOwner = makeAddr("newOwner");
    address internal stranger = makeAddr("stranger");
    address internal signerAddr = makeAddr("signer");

    function setUp() public {
        entryPoint = new EntryPoint();
        paymaster = new PrediXPaymaster(IEntryPoint(address(entryPoint)), owner, signerAddr);
    }

    // ── two-step transfer ───────────────────────────────────────────────

    function test_TransferOwnership_OnlyNominates() public {
        vm.prank(owner);
        paymaster.transferOwnership(newOwner);

        // Transfer has NOT taken effect — current owner keeps control.
        assertEq(paymaster.owner(), owner, "owner unchanged before accept");
        assertEq(paymaster.pendingOwner(), newOwner, "nominee pending");
    }

    function test_AcceptOwnership_CompletesTransfer() public {
        vm.prank(owner);
        paymaster.transferOwnership(newOwner);

        vm.prank(newOwner);
        paymaster.acceptOwnership();

        assertEq(paymaster.owner(), newOwner, "owner rotated on accept");
        assertEq(paymaster.pendingOwner(), address(0), "pending cleared");
    }

    function test_OldOwnerRetainsControlUntilAccept() public {
        address pendingSigner = makeAddr("pendingSigner");
        address oldOwnerSigner = makeAddr("oldOwnerSigner");

        vm.prank(owner);
        paymaster.transferOwnership(newOwner);

        // Nominee cannot act before accepting.
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, newOwner));
        vm.prank(newOwner);
        paymaster.setSigner(pendingSigner);

        // Current owner still controls the paymaster.
        vm.prank(owner);
        paymaster.setSigner(oldOwnerSigner);
        assertEq(paymaster.signer(), oldOwnerSigner, "old owner still in control");
    }

    function test_Revert_TransferOwnership_NotOwner() public {
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, stranger));
        vm.prank(stranger);
        paymaster.transferOwnership(newOwner);
    }

    function test_Revert_AcceptOwnership_NotPending() public {
        vm.prank(owner);
        paymaster.transferOwnership(newOwner);

        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, stranger));
        vm.prank(stranger);
        paymaster.acceptOwnership();
    }

    // ── renounce disabled ───────────────────────────────────────────────

    function test_Revert_RenounceOwnership_Disabled() public {
        vm.expectRevert(IPrediXPaymaster.OwnershipRenounceDisabled.selector);
        vm.prank(owner);
        paymaster.renounceOwnership();
    }
}
