// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import {AuditBase} from "./_AuditBase.sol";
import {console2} from "forge-std/Script.sol";
import {IMarketFacet} from "@predix/shared/interfaces/IMarketFacet.sol";
import {IManualOracle} from "@predix/oracle/interfaces/IManualOracle.sol";

/// @notice Scenario 8 finalize — resolve market + M redeems.
///         outcome=true ⇒ YES wins. M holds ~20 YES (10 Router + 10 direct).
///         M.redeem burns 20 YES + 0 NO ⇒ payout ≈ 20 * 99% = 19.8 USDC.
///         Indexer: position.totalSpent should be 10 USDC (5 Router + 5 direct)
///         but Gap 1 means only 5 USDC (Router only) is tracked. So realizedPnl
///         shows ≈ 19.8 - 5 = 14.8 USDC profit, vs. actual 19.8 - 10 = 9.8.
contract Scenario8_ResolveRedeem is AuditBase {
    function run() external {
        Ctx memory c = _load();
        uint256 marketId = vm.envUint("S8_MARKET_ID");
        bool outcome = vm.envOr("S8_OUTCOME", true);
        string memory mnemonic = vm.envString("MNEMONIC");
        uint256 mKey = vm.deriveKey(mnemonic, 17);
        address m = vm.addr(mKey);

        vm.startBroadcast(c.reporterKey);
        IManualOracle(c.oracleManual).report(marketId, outcome);
        vm.stopBroadcast();

        vm.startBroadcast(c.deployerKey);
        IMarketFacet(c.diamond).resolveMarket(marketId);
        vm.stopBroadcast();

        vm.startBroadcast(mKey);
        uint256 payout = IMarketFacet(c.diamond).redeem(marketId);
        vm.stopBroadcast();

        console2.log("=== Scenario 8 finalized ===");
        console2.log("marketId :", marketId);
        console2.log("outcome  :", outcome);
        console2.log("M        :", m);
        console2.log("payout   :", payout);
    }
}
