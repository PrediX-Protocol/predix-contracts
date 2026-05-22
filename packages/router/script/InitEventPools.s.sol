// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import {Script, console2} from "forge-std/Script.sol";

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";

import {IMarketFacet} from "@predix/shared/interfaces/IMarketFacet.sol";

interface IPrediXHookRegister {
    function registerMarketPool(uint256 marketId, PoolKey calldata key) external;
}

/// @title InitEventPools
/// @notice Register + initialize the v4 pool (50c) for event child markets that were
///         created via `diamond.createEvent` without pools. One register + one
///         initialize per child; forge broadcasts each external call as its own tx, so
///         every pool init is isolated — Unichain flashblocks reject >=2 pool inits in
///         a single tx, but 1-per-tx sequences fine. Mirrors PrediXMarketFactory._initPool.
/// @dev Reads `INIT_POOL_MARKET_IDS` (comma-separated marketIds) plus the standard
///      pool-config env. Run with --slow so register lands before initialize.
contract InitEventPools is Script {
    uint160 internal constant SQRT_PRICE_MID_C0 = 56022770974786139918731938227;
    uint160 internal constant SQRT_PRICE_MID_C1 = 112045541949572279837463876454;

    function run() external {
        address diamond = vm.envAddress("DIAMOND_ADDRESS");
        address usdc = vm.envAddress("USDC_ADDRESS");
        address hook = vm.envAddress("HOOK_PROXY_ADDRESS");
        IPoolManager poolManager = IPoolManager(vm.envAddress("POOL_MANAGER_ADDRESS"));
        uint24 lpFeeFlag = uint24(vm.envUint("LP_FEE_FLAG"));
        int24 tickSpacing = int24(vm.envInt("TICK_SPACING"));
        uint256[] memory ids = vm.envUint("INIT_POOL_MARKET_IDS", ",");

        uint256 deployerKey;
        string memory mnemonic = vm.envOr("MNEMONIC", string(""));
        if (bytes(mnemonic).length > 0) {
            deployerKey = vm.deriveKey(mnemonic, 0);
        } else {
            deployerKey = vm.envUint("DEPLOYER_PRIVATE_KEY");
        }

        vm.startBroadcast(deployerKey);
        for (uint256 i; i < ids.length; ++i) {
            address yesToken = IMarketFacet(diamond).getMarket(ids[i]).yesToken;
            require(yesToken != address(0), "market not found");

            (Currency c0, Currency c1) = usdc < yesToken
                ? (Currency.wrap(usdc), Currency.wrap(yesToken))
                : (Currency.wrap(yesToken), Currency.wrap(usdc));
            PoolKey memory key =
                PoolKey({currency0: c0, currency1: c1, fee: lpFeeFlag, tickSpacing: tickSpacing, hooks: IHooks(hook)});

            IPrediXHookRegister(hook).registerMarketPool(ids[i], key);
            uint160 sqrtPrice = usdc < yesToken ? SQRT_PRICE_MID_C1 : SQRT_PRICE_MID_C0;
            poolManager.initialize(key, sqrtPrice);
            console2.log("pool inited for market", ids[i]);
        }
        vm.stopBroadcast();
    }
}
