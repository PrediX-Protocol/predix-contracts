// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import {DevBase} from "./_DevBase.sol";
import {console2} from "forge-std/Script.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IMarketFacet} from "@predix/shared/interfaces/IMarketFacet.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";

/// @notice Variant 2 — pure AMM (no CLOB orders). LP provides 50 USDC + 100 YES
///         into pool via PositionManager full-range. Router trades route 100%
///         through AMM leg (CLOB preview returns 0 ⇒ no waterfall).
contract M2_AmmOnly is DevBase {
    string internal constant QUESTION = "[Test] Will ETH reach $5K?";
    uint256 internal constant END_OFFSET = 24 hours;
    uint256 internal constant USDC_SPLIT = 100e6; // 100 USDC -> 100 YES + 100 NO
    uint256 internal constant AMM_USDC_AMT = 50e6;
    uint256 internal constant AMM_YES_AMT = 100e6;

    function run() external {
        Ctx memory c = _load();
        address lp = vm.addr(c.lpKey);

        vm.startBroadcast(c.creatorKey);
        IERC20(c.usdc).approve(c.diamond, type(uint256).max);
        uint256 marketId =
            IMarketFacet(c.diamond).createMarket(QUESTION, block.timestamp + END_OFFSET, c.oracleManual);
        vm.stopBroadcast();

        (address yes, address no,,,) = IMarketFacet(c.diamond).getMarketStatus(marketId);

        vm.startBroadcast(c.lpKey);
        IERC20(c.usdc).approve(c.diamond, type(uint256).max);
        IMarketFacet(c.diamond).splitPosition(marketId, USDC_SPLIT);
        _grantPermit2(c, yes);
        (PoolKey memory key, uint256 tokenId) = _registerAndLpAmm(c, marketId, yes, lp, AMM_USDC_AMT, AMM_YES_AMT);
        vm.stopBroadcast();

        console2.log("=== M2 AMM-only complete ===");
        console2.log("marketId    :", marketId);
        console2.log("yesToken    :", yes);
        console2.log("noToken     :", no);
        console2.log("AMM tokenId :", tokenId);
        console2.log("endTime     :", block.timestamp + END_OFFSET);
    }
}
