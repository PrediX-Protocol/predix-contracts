// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import {AuditBase} from "./_AuditBase.sol";
import {console2} from "forge-std/Script.sol";
import {IMarketFacet} from "@predix/shared/interfaces/IMarketFacet.sol";

/// @notice Scenario 7 — X (direct-Exchange taker from S3) redeems on market 10.
///         X holds ~20 YES (winning side per S6 outcome=true). Diamond burns
///         X's YES + NO and pays USDC minus 1% redemption fee.
///         The redeem triggers the indexer's `handleTokensRedeemed` upsert.
///         For X, the upsert creates a position row with totalSpent=0 because
///         no Split/Trade event had populated it (Gap 1 propagation):
///         realizedPnl = payout − 0 = full payout (biases the metric).
///         Y and Z explicitly do NOT redeem this round (Y already sold their
///         YES for USDC; Z holds 20 NO losing side — redeem would revert with
///         Market_NothingWorthRedeeming).
contract Scenario7_RedeemX is AuditBase {
    uint256 internal constant MARKET_ID = 10;

    function run() external {
        Ctx memory c = _load();
        address x = vm.addr(c.xKey);

        vm.startBroadcast(c.xKey);
        uint256 payout = IMarketFacet(c.diamond).redeem(MARKET_ID);
        vm.stopBroadcast();

        console2.log("=== Scenario 7: X redeemed ===");
        console2.log("X         :", x);
        console2.log("payout    :", payout);
    }
}
