// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import {Script, console2} from "forge-std/Script.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {IEventFacet} from "@predix/shared/interfaces/IEventFacet.sol";
import {IMarketFacet} from "@predix/shared/interfaces/IMarketFacet.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {LPFeeLibrary} from "@uniswap/v4-core/src/libraries/LPFeeLibrary.sol";

interface IHookRegister {
    function registerMarketPool(uint256 marketId, PoolKey calldata key) external;
}

/// @notice One-off: create 2 LEGACY multi-outcome events (createEvent, NOT createLinkedEvent), then register
///         + initialize each child pool at the $0.50 midpoint (the only price the hook's init window allows).
///         Legacy events emit EventCreated, which the indexer/BE/FE already group + render correctly. Liquidity
///         is seeded separately by the USDC-holding deployer. Signer = CREATOR_HD_INDEX.
/// @dev Required env: DIAMOND_ADDRESS, USDC_ADDRESS, HOOK_PROXY_ADDRESS, POOL_MANAGER_ADDRESS,
///      ORACLE_MANUAL_ADDRESS, MNEMONIC, CREATOR_HD_INDEX.
contract CreateMultiEvents is Script {
    uint160 internal constant SQRT_MID_YES_C0 = 56022770974786139918731938227;
    uint160 internal constant SQRT_MID_YES_C1 = 112045541949572279837463876454;
    int24 internal constant TICK_SPACING = 60;

    address internal diamond;
    address internal usdc;
    address internal hook;
    IPoolManager internal pm;
    address internal oracle;

    function run() external {
        diamond = vm.envAddress("DIAMOND_ADDRESS");
        usdc = vm.envAddress("USDC_ADDRESS");
        hook = vm.envAddress("HOOK_PROXY_ADDRESS");
        pm = IPoolManager(vm.envAddress("POOL_MANAGER_ADDRESS"));
        oracle = vm.envAddress("ORACLE_MANUAL_ADDRESS");
        uint256 pk = vm.deriveKey(vm.envString("MNEMONIC"), uint32(vm.envUint("CREATOR_HD_INDEX")));

        string[] memory q1 = new string[](4);
        q1[0] = unicode"Below $80,000";
        q1[1] = unicode"$80,000 – $82,000";
        q1[2] = unicode"$82,001 – $85,000";
        q1[3] = unicode"Above $85,000";

        string[] memory q2 = new string[](4);
        q2[0] = unicode"Below 0%";
        q2[1] = unicode"0% – 2%";
        q2[2] = unicode"2% – 4%";
        q2[3] = unicode"Above 4%";

        vm.startBroadcast(pk);
        IERC20(usdc).approve(diamond, type(uint256).max); // per-child creation fee
        _createAndInit(unicode"BTC Weekly Closing Price", q1, 1781049540); // 2026-06-09 23:59 UTC
        _createAndInit(unicode"Where will Bitcoin's Kimchi Premium be at the end of this week?", q2, 1781042400); // 22:00 UTC
        vm.stopBroadcast();
    }

    function _createAndInit(string memory name, string[] memory questions, uint256 endTime) internal {
        (uint256 eventId, uint256[] memory marketIds) =
            IEventFacet(diamond).createEvent(name, questions, endTime, oracle);
        console2.log("EVENT", eventId, name);
        for (uint256 i; i < marketIds.length; ++i) {
            IMarketFacet.MarketView memory mkt = IMarketFacet(diamond).getMarket(marketIds[i]);
            bool yesC0 = mkt.yesToken < usdc;
            (address c0, address c1) = yesC0 ? (mkt.yesToken, usdc) : (usdc, mkt.yesToken);
            PoolKey memory key = PoolKey({
                currency0: Currency.wrap(c0),
                currency1: Currency.wrap(c1),
                fee: LPFeeLibrary.DYNAMIC_FEE_FLAG,
                tickSpacing: TICK_SPACING,
                hooks: IHooks(hook)
            });
            IHookRegister(hook).registerMarketPool(marketIds[i], key);
            pm.initialize(key, yesC0 ? SQRT_MID_YES_C0 : SQRT_MID_YES_C1);
            console2.log("  child", marketIds[i], mkt.yesToken);
        }
    }
}
