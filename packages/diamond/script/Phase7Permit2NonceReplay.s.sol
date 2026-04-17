// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Script, console2} from "forge-std/Script.sol";
import {IAllowanceTransfer} from "permit2/src/interfaces/IAllowanceTransfer.sol";

/// @notice Phase 7 Tier A3 — Permit2 nonce-replay defense.
/// @dev    Signs a PermitSingle once, calls permit2.permit directly (consumes
///         nonce + sets allowance), then replays THE SAME signature — the
///         second call reverts because Permit2 expects nonce+1 now.
///         Directly exercises the signature+nonce layer without going through
///         Router (so it works regardless of market state / pool liquidity).
contract Phase7Permit2NonceReplay is Script {
    bytes32 internal constant _PERMIT_DETAILS_TYPEHASH =
        keccak256("PermitDetails(address token,uint160 amount,uint48 expiration,uint48 nonce)");
    bytes32 internal constant _PERMIT_SINGLE_TYPEHASH = keccak256(
        "PermitSingle(PermitDetails details,address spender,uint256 sigDeadline)PermitDetails(address token,uint160 amount,uint48 expiration,uint48 nonce)"
    );

    function run() external {
        uint256 pk = vm.envUint("DEPLOYER_PRIVATE_KEY");
        address user = vm.addr(pk);
        address permit2 = vm.envAddress("PERMIT2_ADDRESS");
        address usdc = vm.envAddress("USDC_ADDRESS");
        // Use TEST_USER_3 as spender so we don't disturb the Router allowance lane
        address spender = vm.envAddress("TEST_USER_3_ADDRESS");

        (,, uint48 nonce) = IAllowanceTransfer(permit2).allowance(user, usdc, spender);
        console2.log("Fresh nonce:", nonce);

        IAllowanceTransfer.PermitSingle memory permit = IAllowanceTransfer.PermitSingle({
            details: IAllowanceTransfer.PermitDetails({
                token: usdc, amount: 1000000, expiration: uint48(block.timestamp + 1 hours), nonce: nonce
            }),
            spender: spender,
            sigDeadline: block.timestamp + 1 hours
        });
        bytes memory sig = _sign(permit, pk, permit2);

        // 1st call: should succeed, consume nonce
        vm.startBroadcast(pk);
        IAllowanceTransfer(permit2).permit(user, permit, sig);
        console2.log("First permit() succeeded");

        // 2nd call with SAME signature: Permit2 now expects nonce+1, so this reverts
        bytes memory callData = abi.encodeWithSignature(
            "permit(address,((address,uint160,uint48,uint48),address,uint256),bytes)", user, permit, sig
        );
        (bool ok,) = permit2.call(callData);
        if (ok) revert("replay unexpectedly succeeded");
        console2.log("Replay correctly reverted at Permit2 nonce check");
        vm.stopBroadcast();
    }

    function _sign(IAllowanceTransfer.PermitSingle memory p, uint256 pk, address permit2)
        internal
        view
        returns (bytes memory)
    {
        bytes32 detailsHash = keccak256(
            abi.encode(
                _PERMIT_DETAILS_TYPEHASH, p.details.token, p.details.amount, p.details.expiration, p.details.nonce
            )
        );
        bytes32 structHash = keccak256(abi.encode(_PERMIT_SINGLE_TYPEHASH, detailsHash, p.spender, p.sigDeadline));
        bytes32 domainSep = IAllowanceTransfer(permit2).DOMAIN_SEPARATOR();
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", domainSep, structHash));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(pk, digest);
        return abi.encodePacked(r, s, v);
    }
}
