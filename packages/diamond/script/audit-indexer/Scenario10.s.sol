// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import {AuditBase} from "./_AuditBase.sol";
import {console2} from "forge-std/Script.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IMarketFacet} from "@predix/shared/interfaces/IMarketFacet.sol";

/// @notice Scenario 10 — off-protocol ERC20 transfer cost-basis gap.
///         A (HD-10) holds 20 YES on market 9 (resolved YES wins in S1).
///         A directly ERC20.transfers 5 YES → P (HD-19), bypassing every
///         protocol entry point. Then P calls redeem to claim payout.
///
///         Indexer expectation:
///         - holder.yesBalance updates for A and P (Transfer event handler ok)
///         - position table NOT updated by the transfer (no handler)
///         - A.position.totalSpent unchanged ⇒ stale cost basis on tokens that
///           no longer exist in A's wallet
///         - P.position likely upserted by redeem with totalSpent=0 ⇒
///           realizedPnl = full payout (paid 0 directly, but received tokens
///           that originally cost A 2.5 USDC to mint via splitPosition)
contract Scenario10 is AuditBase {
    uint256 internal constant MARKET_ID = 9;
    uint256 internal constant TRANSFER_AMOUNT = 5e6;

    function run() external {
        Ctx memory c = _load();
        string memory mnemonic = vm.envString("MNEMONIC");
        uint256 pKey = vm.deriveKey(mnemonic, 19);
        address p = vm.addr(pKey);
        address a = vm.addr(c.aKey);

        (address yes,,,,) = IMarketFacet(c.diamond).getMarketStatus(MARKET_ID);

        // A → P direct ERC20 transfer (no protocol involvement)
        vm.startBroadcast(c.aKey);
        IERC20(yes).transfer(p, TRANSFER_AMOUNT);
        vm.stopBroadcast();

        // P redeems on market 9 (YES wins per S1)
        vm.startBroadcast(pKey);
        uint256 payout = IMarketFacet(c.diamond).redeem(MARKET_ID);
        vm.stopBroadcast();

        console2.log("=== Scenario 10: A->P transfer + P redeem ===");
        console2.log("A        :", a);
        console2.log("P        :", p);
        console2.log("yesToken :", yes);
        console2.log("transferred (raw)  :", TRANSFER_AMOUNT);
        console2.log("P redeem payout    :", payout);
    }
}
