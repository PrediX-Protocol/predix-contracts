// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Script, console2} from "forge-std/Script.sol";
import {IAllowanceTransfer} from "permit2/src/interfaces/IAllowanceTransfer.sol";
import {IPrediXRouter} from "@predix/router/interfaces/IPrediXRouter.sol";

/// @notice Phase 7 live smoke — Permit2 EIP-712 signed Router flows.
contract Phase7Permit2Smoke is Script {
    bytes32 internal constant _PERMIT_DETAILS_TYPEHASH =
        keccak256("PermitDetails(address token,uint160 amount,uint48 expiration,uint48 nonce)");
    bytes32 internal constant _PERMIT_SINGLE_TYPEHASH = keccak256(
        "PermitSingle(PermitDetails details,address spender,uint256 sigDeadline)PermitDetails(address token,uint160 amount,uint48 expiration,uint48 nonce)"
    );

    function run() external {
        uint256 pk = vm.envUint("DEPLOYER_PRIVATE_KEY");
        address user = vm.addr(pk);
        address router = vm.envAddress("NEW_ROUTER");
        address permit2 = vm.envAddress("PERMIT2_ADDRESS");
        address usdc = vm.envAddress("USDC_ADDRESS");
        uint256 marketId = 4;

        // ACTION env: "buyYes" | "sellYes" | "buyNo" | "sellNo"
        string memory action = vm.envString("PERMIT2_ACTION");
        uint160 amt = uint160(vm.envUint("PERMIT2_AMOUNT")); // in token units (6-dec)
        address token = _tokenFor(action, usdc, marketId, router);

        (,, uint48 nonce) = IAllowanceTransfer(permit2).allowance(user, token, router);

        IAllowanceTransfer.PermitSingle memory permit = IAllowanceTransfer.PermitSingle({
            details: IAllowanceTransfer.PermitDetails({
                token: token, amount: amt, expiration: uint48(block.timestamp + 1 hours), nonce: nonce
            }),
            spender: router,
            sigDeadline: block.timestamp + 1 hours
        });

        bytes memory sig = _signPermitSingle(permit, pk, permit2);

        vm.startBroadcast(pk);
        uint256 out;
        if (_eq(action, "buyYes")) {
            (out,,) =
                IPrediXRouter(router).buyYesWithPermit(marketId, amt, 0, user, 0, block.timestamp + 300, permit, sig);
        } else if (_eq(action, "sellYes")) {
            (out,,) =
                IPrediXRouter(router).sellYesWithPermit(marketId, amt, 0, user, 0, block.timestamp + 300, permit, sig);
        } else if (_eq(action, "buyNo")) {
            (out,,) =
                IPrediXRouter(router).buyNoWithPermit(marketId, amt, 0, user, 0, block.timestamp + 300, permit, sig);
        } else if (_eq(action, "sellNo")) {
            (out,,) =
                IPrediXRouter(router).sellNoWithPermit(marketId, amt, 0, user, 0, block.timestamp + 300, permit, sig);
        } else {
            revert("unknown PERMIT2_ACTION");
        }
        vm.stopBroadcast();
        console2.log("Permit2 flow succeeded, out=", out);
    }

    // Which token permit is spending for this action
    function _tokenFor(string memory action, address usdc, uint256 marketId, address router)
        internal
        view
        returns (address)
    {
        // For buy*, Router pulls USDC; for sell*, Router pulls YES/NO from user
        if (_eq(action, "buyYes") || _eq(action, "buyNo")) return usdc;
        // For sell directions we need the outcome token
        // Fetch via Diamond
        (bool ok, bytes memory ret) =
            vm.envAddress("NEW_DIAMOND").staticcall(abi.encodeWithSignature("getMarket(uint256)", marketId));
        require(ok, "getMarket failed");
        // Decode MarketView struct - we only need yesToken (index 4) or noToken (index 5)
        // Layout: (string,uint256,address,address,address,address,uint256,...)
        (,,,, address yesTok, address noTok,,,,,,,,,) = abi.decode(
            ret,
            (
                string,
                uint256,
                address,
                address,
                address,
                address,
                uint256,
                uint256,
                uint256,
                bool,
                bool,
                bool,
                uint256,
                uint16,
                bool
            )
        );
        return _eq(action, "sellYes") ? yesTok : noTok;
    }

    function _signPermitSingle(IAllowanceTransfer.PermitSingle memory p, uint256 pk, address permit2)
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

    function _eq(string memory a, string memory b) internal pure returns (bool) {
        return keccak256(bytes(a)) == keccak256(bytes(b));
    }
}
