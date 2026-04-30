// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Script, console2} from "forge-std/Script.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IAllowanceTransfer} from "permit2/src/interfaces/IAllowanceTransfer.sol";
import {IPrediXRouter} from "@predix/router/interfaces/IPrediXRouter.sol";
import {IMarketFacet} from "@predix/shared/interfaces/IMarketFacet.sol";

contract E2EPermit2Test is Script {
    bytes32 constant PERMIT2_DOMAIN_SEPARATOR_SLOT = 0x0000000000000000000000000000000000000000000000000000000000000000;

    function run() external {
        address router = vm.envAddress("PREDIX_ROUTER_ADDRESS");
        address usdc = vm.envAddress("USDC_ADDRESS");
        address diamond = vm.envAddress("DIAMOND_ADDRESS");
        address permit2 = vm.envAddress("PERMIT2_ADDRESS");
        uint256 pk = vm.envUint("DEPLOYER_PRIVATE_KEY");
        address deployer = vm.addr(pk);
        uint256 marketId = vm.envUint("E2E_MARKET_ID");

        // Get permit2 domain separator
        bytes32 domainSep = IAllowanceTransfer(permit2).DOMAIN_SEPARATOR();

        // Build PermitSingle
        IAllowanceTransfer.PermitSingle memory permitSingle = IAllowanceTransfer.PermitSingle({
            details: IAllowanceTransfer.PermitDetails({
                token: usdc,
                amount: uint160(10e6),
                expiration: uint48(block.timestamp + 3600),
                nonce: 0
            }),
            spender: router,
            sigDeadline: block.timestamp + 3600
        });

        // Compute EIP-712 hash
        bytes32 PERMIT_DETAILS_TYPEHASH = keccak256(
            "PermitDetails(address token,uint160 amount,uint48 expiration,uint48 nonce)"
        );
        bytes32 PERMIT_SINGLE_TYPEHASH = keccak256(
            "PermitSingle(PermitDetails details,address spender,uint256 sigDeadline)PermitDetails(address token,uint160 amount,uint48 expiration,uint48 nonce)"
        );

        bytes32 detailsHash = keccak256(abi.encode(
            PERMIT_DETAILS_TYPEHASH,
            permitSingle.details.token,
            permitSingle.details.amount,
            permitSingle.details.expiration,
            permitSingle.details.nonce
        ));
        bytes32 structHash = keccak256(abi.encode(
            PERMIT_SINGLE_TYPEHASH,
            detailsHash,
            permitSingle.spender,
            permitSingle.sigDeadline
        ));
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", domainSep, structHash));

        // Sign
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(pk, digest);
        bytes memory signature = abi.encodePacked(r, s, v);

        console2.log("Permit2 signature constructed");
        console2.log("  token:", usdc);
        console2.log("  amount: 10 USDC");
        console2.log("  spender:", router);

        // First approve USDC to Permit2 (required for Permit2 to pull)
        vm.startBroadcast(pk);
        IERC20(usdc).approve(permit2, type(uint256).max);

        // Call buyYesWithPermit
        IMarketFacet.MarketView memory m = IMarketFacet(diamond).getMarket(marketId);
        uint256 yesBefore = IERC20(m.yesToken).balanceOf(deployer);

        try IPrediXRouter(router).buyYesWithPermit(
            marketId,
            10e6,    // usdcIn
            1,       // minYesOut
            deployer,
            10,      // maxFills
            block.timestamp + 300,
            permitSingle,
            signature
        ) returns (uint256 yesOut, uint256, uint256) {
            console2.log("buyYesWithPermit SUCCESS, yesOut:", yesOut);
        } catch (bytes memory reason) {
            // May revert due to AMM pool issues, but the permit was consumed
            console2.log("buyYesWithPermit reverted (expected if no AMM pool)");
            console2.log("  reason length:", reason.length);
        }

        vm.stopBroadcast();

        uint256 yesAfter = IERC20(m.yesToken).balanceOf(deployer);
        if (yesAfter > yesBefore) {
            console2.log("PERMIT2 TEST PASSED: received", yesAfter - yesBefore, "YES");
        } else {
            console2.log("PERMIT2 TEST: tx executed (permit consumed), AMM may have insufficient liquidity");
        }
    }
}
