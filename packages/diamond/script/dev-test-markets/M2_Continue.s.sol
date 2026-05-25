// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import {DevBase} from "./_DevBase.sol";
import {console2} from "forge-std/Script.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IMarketFacet} from "@predix/shared/interfaces/IMarketFacet.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";

/// @notice Continue M2 setup after M2_AmmOnly partially landed (createMarket OK,
///         LP step nonce-conflicted). Takes the existing market ID via
///         `M2_MARKET_ID` env var and finishes split + Permit2 + AMM LP.
contract M2_Continue is DevBase {
    uint256 internal constant USDC_SPLIT = 100e6;
    uint256 internal constant AMM_USDC_AMT = 50e6;
    uint256 internal constant AMM_YES_AMT = 100e6;

    function run() external {
        Ctx memory c = _load();
        uint256 marketId = vm.envUint("M2_MARKET_ID");
        address lp = vm.addr(c.lpKey);

        (address yes,,,,) = IMarketFacet(c.diamond).getMarketStatus(marketId);
        require(yes != address(0), "market not found");

        vm.startBroadcast(c.lpKey);
        IERC20(c.usdc).approve(c.diamond, type(uint256).max);
        IMarketFacet(c.diamond).splitPosition(marketId, USDC_SPLIT);
        _grantPermit2(c, yes);
        (, uint256 tokenId) = _registerAndLpAmm(c, marketId, yes, lp, AMM_USDC_AMT, AMM_YES_AMT);
        vm.stopBroadcast();

        console2.log("=== M2 continue complete ===");
        console2.log("marketId    :", marketId);
        console2.log("AMM tokenId :", tokenId);
    }
}
