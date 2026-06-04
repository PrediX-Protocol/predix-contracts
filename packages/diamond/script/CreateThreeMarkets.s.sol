// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import {Script, console2} from "forge-std/Script.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {IMarketFacet} from "@predix/shared/interfaces/IMarketFacet.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {LPFeeLibrary} from "@uniswap/v4-core/src/libraries/LPFeeLibrary.sol";

interface IHookRegister {
    function registerMarketPool(uint256 marketId, PoolKey calldata key) external;
}

/// @notice One-off: create 3 specific binary markets (signer = CREATOR_HD_INDEX), register each pool on the
///         hook, and initialize each v4 pool at the $0.50 midpoint. Mirrors Phase7CreateMarketFull steps 1-4
///         but stops before liquidity (LP is seeded separately by the USDC-holding deployer). createMarket
///         charges the per-market creation fee in USDC, so the signer approves USDC to the diamond first.
/// @dev Required env: DIAMOND_ADDRESS, USDC_ADDRESS, HOOK_PROXY_ADDRESS, POOL_MANAGER_ADDRESS,
///      ORACLE_MANUAL_ADDRESS, MNEMONIC, CREATOR_HD_INDEX.
contract CreateThreeMarkets is Script {
    uint160 internal constant SQRT_MID_YES_C0 = 56022770974786139918731938227; // YES=currency0, p=$0.50
    uint160 internal constant SQRT_MID_YES_C1 = 112045541949572279837463876454; // YES=currency1, p=$0.50
    int24 internal constant TICK_SPACING = 60;

    function run() external {
        address diamond = vm.envAddress("DIAMOND_ADDRESS");
        address usdc = vm.envAddress("USDC_ADDRESS");
        address hook = vm.envAddress("HOOK_PROXY_ADDRESS");
        IPoolManager pm = IPoolManager(vm.envAddress("POOL_MANAGER_ADDRESS"));
        address oracle = vm.envAddress("ORACLE_MANUAL_ADDRESS");
        uint256 pk = vm.deriveKey(vm.envString("MNEMONIC"), uint32(vm.envUint("CREATOR_HD_INDEX")));

        string[3] memory questions;
        questions[0] = "Will MicroStrategy sell more BTC this week?";
        questions[1] = "Will BTC close below $82,000 this week?";
        questions[2] = "Will Bitcoin's Kimchi Premium turn negative this week?";
        uint256[3] memory endTimes;
        endTimes[0] = 1781049540; // 2026-06-09 23:59:00 UTC
        endTimes[1] = 1781049540; // 2026-06-09 23:59:00 UTC
        endTimes[2] = 1781042400; // 2026-06-09 22:00:00 UTC

        vm.startBroadcast(pk);
        IERC20(usdc).approve(diamond, type(uint256).max); // per-market creation fee

        for (uint256 i; i < 3; ++i) {
            uint256 marketId = IMarketFacet(diamond).createMarket(questions[i], endTimes[i], oracle);
            IMarketFacet.MarketView memory mkt = IMarketFacet(diamond).getMarket(marketId);

            bool yesC0 = mkt.yesToken < usdc;
            (address c0, address c1) = yesC0 ? (mkt.yesToken, usdc) : (usdc, mkt.yesToken);
            PoolKey memory key = PoolKey({
                currency0: Currency.wrap(c0),
                currency1: Currency.wrap(c1),
                fee: LPFeeLibrary.DYNAMIC_FEE_FLAG,
                tickSpacing: TICK_SPACING,
                hooks: IHooks(hook)
            });

            IHookRegister(hook).registerMarketPool(marketId, key);
            pm.initialize(key, yesC0 ? SQRT_MID_YES_C0 : SQRT_MID_YES_C1);

            console2.log("CREATED marketId", marketId);
            console2.log("   q:", questions[i]);
            console2.log("   yes / endTime:", mkt.yesToken, endTimes[i]);
        }
        vm.stopBroadcast();
    }
}
