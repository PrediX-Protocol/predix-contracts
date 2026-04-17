// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Script, console2} from "forge-std/Script.sol";
import {IAllowanceTransfer} from "permit2/src/interfaces/IAllowanceTransfer.sol";

/// @notice Phase 7 Tier A3 helper — produces a signed permit2.permit calldata
///         payload and prints it to stdout for replay via `cast send`.
contract Phase7Permit2SignOnly is Script {
    bytes32 internal constant _PERMIT_DETAILS_TYPEHASH =
        keccak256("PermitDetails(address token,uint160 amount,uint48 expiration,uint48 nonce)");
    bytes32 internal constant _PERMIT_SINGLE_TYPEHASH = keccak256(
        "PermitSingle(PermitDetails details,address spender,uint256 sigDeadline)PermitDetails(address token,uint160 amount,uint48 expiration,uint48 nonce)"
    );

    function run() external view {
        uint256 pk = vm.envUint("DEPLOYER_PRIVATE_KEY");
        address user = vm.addr(pk);
        address permit2 = vm.envAddress("PERMIT2_ADDRESS");
        address usdc = vm.envAddress("USDC_ADDRESS");
        address spender = vm.envAddress("TEST_USER_3_ADDRESS");

        (,, uint48 nonce) = IAllowanceTransfer(permit2).allowance(user, usdc, spender);

        IAllowanceTransfer.PermitSingle memory permit = IAllowanceTransfer.PermitSingle({
            details: IAllowanceTransfer.PermitDetails({
                token: usdc, amount: 1000000, expiration: uint48(block.timestamp + 1 hours), nonce: nonce
            }),
            spender: spender,
            sigDeadline: block.timestamp + 1 hours
        });

        bytes32 detailsHash = keccak256(
            abi.encode(
                _PERMIT_DETAILS_TYPEHASH,
                permit.details.token,
                permit.details.amount,
                permit.details.expiration,
                permit.details.nonce
            )
        );
        bytes32 structHash =
            keccak256(abi.encode(_PERMIT_SINGLE_TYPEHASH, detailsHash, permit.spender, permit.sigDeadline));
        bytes32 domainSep = IAllowanceTransfer(permit2).DOMAIN_SEPARATOR();
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", domainSep, structHash));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(pk, digest);
        bytes memory sig = abi.encodePacked(r, s, v);

        bytes memory calldataBytes = abi.encodeWithSignature(
            "permit(address,((address,uint160,uint48,uint48),address,uint256),bytes)", user, permit, sig
        );

        console2.log("NONCE:", nonce);
        console2.log("EXPIRATION:", permit.details.expiration);
        console2.log("SIGNATURE:");
        console2.logBytes(sig);
        console2.log("FULL_CALLDATA:");
        console2.logBytes(calldataBytes);
    }
}
