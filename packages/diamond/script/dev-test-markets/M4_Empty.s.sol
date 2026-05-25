// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import {DevBase} from "./_DevBase.sol";
import {console2} from "forge-std/Script.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IMarketFacet} from "@predix/shared/interfaces/IMarketFacet.sol";

/// @notice Variant 4 — empty market (no pool, no orders). Tests FE / Router "no
///         liquidity" UX — quote functions should return 0; Router.buy* should
///         revert ExactInUnfilled if attempted.
contract M4_Empty is DevBase {
    string internal constant QUESTION = "[Test] Will DOGE hit $1?";
    uint256 internal constant END_OFFSET = 24 hours;

    function run() external {
        Ctx memory c = _load();

        vm.startBroadcast(c.creatorKey);
        IERC20(c.usdc).approve(c.diamond, type(uint256).max);
        uint256 marketId =
            IMarketFacet(c.diamond).createMarket(QUESTION, block.timestamp + END_OFFSET, c.oracleManual);
        vm.stopBroadcast();

        (address yes, address no,,,) = IMarketFacet(c.diamond).getMarketStatus(marketId);

        console2.log("=== M4 empty market complete ===");
        console2.log("marketId :", marketId);
        console2.log("yesToken :", yes);
        console2.log("noToken  :", no);
        console2.log("endTime  :", block.timestamp + END_OFFSET);
    }
}
