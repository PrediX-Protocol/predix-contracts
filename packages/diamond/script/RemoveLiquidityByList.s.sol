// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import {Script, console2} from "forge-std/Script.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {LPFeeLibrary} from "@uniswap/v4-core/src/libraries/LPFeeLibrary.sol";
import {ModifyLiquidityParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";

interface IPoolModifyLiquidityTest {
    function modifyLiquidity(PoolKey memory key, ModifyLiquidityParams memory params, bytes memory hookData)
        external
        payable
        returns (int256 delta);
}

/// @notice Authoritative LP remover: removes the FULL-RANGE position for an explicit, deduplicated list of
///         (owner-router, YES-token) pairs extracted from the Phase7 seeding broadcast logs — the ground
///         truth of every position the deployer created. Pairs come in two parallel env arrays
///         (LP_ROUTERS[i] owns the position for LP_YESES[i]); the YES/USDC currency ordering is derived per
///         pair, so BOTH orientations (YES as currency0 OR currency1) are handled. Idempotent: a pair whose
///         on-chain liquidity already reads 0 is skipped. Read-only unless DO_BROADCAST=true.
/// @dev Required env: POOL_MANAGER_ADDRESS, HOOK_PROXY_ADDRESS, USDC_ADDRESS, LP_ROUTERS, LP_YESES,
///      MNEMONIC (HD-0 = deployer) or DEPLOYER_PRIVATE_KEY. Optional: DO_BROADCAST (default false).
contract RemoveLiquidityByList is Script {
    using StateLibrary for IPoolManager;
    using PoolIdLibrary for PoolKey;

    int24 internal constant TICK_LOWER = -887220;
    int24 internal constant TICK_UPPER = 887220;
    int24 internal constant TICK_SPACING = 60;
    bytes32 internal constant SALT = bytes32(0);

    function run() external {
        IPoolManager pm = IPoolManager(vm.envAddress("POOL_MANAGER_ADDRESS"));
        address hook = vm.envAddress("HOOK_PROXY_ADDRESS");
        address usdc = vm.envAddress("USDC_ADDRESS");
        address[] memory routers = vm.envAddress("LP_ROUTERS", ",");
        address[] memory yeses = vm.envAddress("LP_YESES", ",");
        require(routers.length == yeses.length && routers.length > 0, "bad pair arrays");

        bool doBroadcast = vm.envOr("DO_BROADCAST", false);
        string memory mnemonic = vm.envOr("MNEMONIC", string(""));
        uint256 pk =
            bytes(mnemonic).length > 0 ? vm.deriveKey(mnemonic, 0) : vm.envUint("DEPLOYER_PRIVATE_KEY");
        address deployer = vm.addr(pk);

        uint256 usdcBefore = IERC20(usdc).balanceOf(deployer);
        uint256 active;
        uint256 removed;
        uint128 maxL;

        console2.log("=== RemoveLiquidityByList ===");
        console2.log("pairs:", routers.length);
        console2.log("broadcast:", doBroadcast);

        if (doBroadcast) vm.startBroadcast(pk);
        for (uint256 i; i < routers.length; ++i) {
            address yes = yeses[i];
            address router = routers[i];
            (address c0, address c1) = yes < usdc ? (yes, usdc) : (usdc, yes);
            PoolKey memory key = PoolKey({
                currency0: Currency.wrap(c0),
                currency1: Currency.wrap(c1),
                fee: LPFeeLibrary.DYNAMIC_FEE_FLAG,
                tickSpacing: TICK_SPACING,
                hooks: IHooks(hook)
            });
            PoolId pid = key.toId();
            (uint128 liq,,) = pm.getPositionInfo(pid, router, TICK_LOWER, TICK_UPPER, SALT);
            if (liq == 0) continue;
            ++active;
            if (liq > maxL) maxL = liq;
            if (!doBroadcast) continue;
            IPoolModifyLiquidityTest(router).modifyLiquidity(
                key,
                ModifyLiquidityParams({
                    tickLower: TICK_LOWER,
                    tickUpper: TICK_UPPER,
                    liquidityDelta: -int256(uint256(liq)),
                    salt: SALT
                }),
                ""
            );
            ++removed;
        }
        if (doBroadcast) vm.stopBroadcast();

        console2.log("positions still ACTIVE (L>0):", active);
        console2.log("positions REMOVED this run:", removed);
        console2.log("USDC recovered:", IERC20(usdc).balanceOf(deployer) - usdcBefore);
    }
}
