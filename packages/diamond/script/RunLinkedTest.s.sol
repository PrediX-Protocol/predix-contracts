// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import {Script, console2} from "forge-std/Script.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {ILinkedEventFacet} from "@predix/shared/interfaces/ILinkedEventFacet.sol";
import {IMarketFacet} from "@predix/shared/interfaces/IMarketFacet.sol";

/// @notice Functional end-to-end exercise of the freshly-upgraded LINKED (shared-collateral) engine on the
///         LIVE diamond: create a 3-outcome linked event, mint a complete set, assert the shared-pool +
///         per-outcome YES accounting (Σ-YES invariant), then redeem part of the set and re-assert. Inline
///         `require`s run during simulation, so a broken invariant aborts BEFORE any broadcast. DRY-RUN by
///         default — add `--broadcast` to execute. The created event (#eventCount+1) is permanent on beta.
/// @dev    Signs with the mnemonic account that holds CREATOR_ROLE (HD index from CREATOR_HD_INDEX). That
///         account must also hold >= MINT_AMOUNT USDC (mintCompleteSet pulls collateral from the caller).
///         Required env: DIAMOND_ADDRESS, USDC_ADDRESS, ORACLE_MANUAL_ADDRESS, MNEMONIC, CREATOR_HD_INDEX.
contract RunLinkedTest is Script {
    uint256 internal constant MINT_AMOUNT = 100e6; // 100 USDC (6 decimals)
    uint256 internal constant REDEEM_AMOUNT = 40e6; // redeem 40 of the complete set back to USDC
    uint256 internal constant N_OUTCOMES = 3;

    function run() external {
        address diamond = vm.envAddress("DIAMOND_ADDRESS");
        IERC20 usdc = IERC20(vm.envAddress("USDC_ADDRESS"));
        address oracle = vm.envAddress("ORACLE_MANUAL_ADDRESS");
        uint256 pk = vm.deriveKey(vm.envString("MNEMONIC"), uint32(vm.envUint("CREATOR_HD_INDEX")));
        address signer = vm.addr(pk);

        string[] memory questions = new string[](N_OUTCOMES);
        questions[0] = "LINKED TEST: outcome A wins?";
        questions[1] = "LINKED TEST: outcome B wins?";
        questions[2] = "LINKED TEST: outcome C wins?";
        uint256 endTime = block.timestamp + 7 days;

        // Each child market charges marketCreationFee to feeRecipient inside LibMarket.create, so creating
        // an N-outcome event costs N * fee on top of the mint deposit.
        uint256 creationFee = IMarketFacet(diamond).marketCreationFee();
        uint256 usdcBefore = usdc.balanceOf(signer);
        require(usdcBefore >= MINT_AMOUNT + N_OUTCOMES * creationFee, "signer lacks USDC for mint + creation fees");

        console2.log("=== LINKED engine functional test ===");
        console2.log("signer (CREATOR_ROLE):", signer);
        console2.log("USDC before:", usdcBefore);

        vm.startBroadcast(pk);

        // 1) create the 3-outcome shared-collateral event
        (uint256 eventId, uint256[] memory marketIds) =
            ILinkedEventFacet(diamond).createLinkedEvent("LINKED TEST", questions, endTime, oracle);
        require(marketIds.length == N_OUTCOMES, "wrong child count");
        require(ILinkedEventFacet(diamond).isLinkedEvent(eventId), "event not flagged linked");
        require(ILinkedEventFacet(diamond).eventPoolOf(eventId) == 0, "fresh pool must be 0");

        // 2) mint a complete set: deposit MINT_AMOUNT USDC -> MINT_AMOUNT YES of EVERY outcome
        usdc.approve(diamond, MINT_AMOUNT);
        ILinkedEventFacet(diamond).mintCompleteSet(eventId, MINT_AMOUNT);

        require(ILinkedEventFacet(diamond).eventPoolOf(eventId) == MINT_AMOUNT, "pool != minted amount");
        for (uint256 i; i < N_OUTCOMES; ++i) {
            address yes = IMarketFacet(diamond).getMarket(marketIds[i]).yesToken;
            require(IERC20(yes).balanceOf(signer) == MINT_AMOUNT, "YES balance != minted (per outcome)");
        }

        // 3) redeem part of the set: burn REDEEM_AMOUNT YES of EVERY outcome -> REDEEM_AMOUNT USDC back
        ILinkedEventFacet(diamond).redeemCompleteSet(eventId, REDEEM_AMOUNT);

        uint256 expectedPool = MINT_AMOUNT - REDEEM_AMOUNT;
        require(ILinkedEventFacet(diamond).eventPoolOf(eventId) == expectedPool, "pool != post-redeem");
        for (uint256 i; i < N_OUTCOMES; ++i) {
            address yes = IMarketFacet(diamond).getMarket(marketIds[i]).yesToken;
            require(IERC20(yes).balanceOf(signer) == expectedPool, "YES != post-redeem (per outcome)");
        }

        vm.stopBroadcast();

        uint256 usdcAfter = usdc.balanceOf(signer);
        // net USDC out = pool remainder (un-redeemed complete set, recoverable) + per-child creation fee
        // (spent to feeRecipient at createLinkedEvent, not part of the pool).
        uint256 expectedNetOut = expectedPool + N_OUTCOMES * creationFee;
        require(usdcBefore - usdcAfter == expectedNetOut, "net USDC delta != pool remainder + creation fees");

        console2.log("eventId:", eventId);
        console2.log("child markets:", marketIds[0], marketIds[1], marketIds[2]);
        console2.log("pool after (expect 60e6):", ILinkedEventFacet(diamond).eventPoolOf(eventId));
        console2.log("USDC after:", usdcAfter);
        console2.log("net USDC out (pool + 3x creation fee):", usdcBefore - usdcAfter);
        console2.log("ALL INVARIANTS PASSED");
    }
}
