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
import {ModifyLiquidityParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";

interface IPoolModifyLiquidityTest {
    function modifyLiquidity(PoolKey memory key, ModifyLiquidityParams memory params, bytes memory hookData)
        external
        payable
        returns (int256 delta);
}

/// @notice BATCH: remove EVERY full-range LP position that was seeded via the Phase7 scripts (each
///         owned by one of the 3 `PoolModifyLiquidityTest` routers). Iterates all markets, derives
///         the USDC/YES pool key, and for each of the 3 routers checks for an active full-range
///         position [-887220, 887220]; removes any with liquidity > 0, returning YES + USDC to the
///         deployer (msg.sender). Idempotent: already-removed positions read L = 0 and are skipped.
///         DRY-RUN by default — add `--broadcast` to execute.
/// @dev    Required env: POOL_MANAGER_ADDRESS, HOOK_PROXY_ADDRESS, USDC_ADDRESS, DIAMOND_ADDRESS,
///         LP_ROUTER_1, LP_ROUTER_2, LP_ROUTER_3, MNEMONIC (HD-0) or DEPLOYER_PRIVATE_KEY.
contract RemoveLiquidityBatch is Script {
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
        IMarketFacet diamond = IMarketFacet(vm.envAddress("DIAMOND_ADDRESS"));

        address[3] memory routers =
            [vm.envAddress("LP_ROUTER_1"), vm.envAddress("LP_ROUTER_2"), vm.envAddress("LP_ROUTER_3")];

        string memory mnemonic = vm.envOr("MNEMONIC", string(""));
        uint256 pk =
            bytes(mnemonic).length > 0 ? vm.deriveKey(mnemonic, 0) : vm.envUint("DEPLOYER_PRIVATE_KEY");
        address deployer = vm.addr(pk);

        uint256 marketCount = diamond.marketCount();
        uint256 usdcBefore = IERC20(usdc).balanceOf(deployer);
        uint256 removed;

        console2.log("=== BATCH REMOVE LP (full-range, 3 routers) ===");
        console2.log("marketCount:", marketCount);
        console2.log("deployer:", deployer);

        vm.startBroadcast(pk);
        for (uint256 id = 1; id <= marketCount; ++id) {
            address yes = diamond.getMarket(id).yesToken;
            if (yes == address(0)) continue;

            (address c0, address c1) = yes < usdc ? (yes, usdc) : (usdc, yes);
            PoolKey memory key = PoolKey({
                currency0: Currency.wrap(c0),
                currency1: Currency.wrap(c1),
                fee: LPFeeLibrary.DYNAMIC_FEE_FLAG,
                tickSpacing: TICK_SPACING,
                hooks: IHooks(hook)
            });
            PoolId pid = key.toId();

            for (uint256 r; r < routers.length; ++r) {
                (uint128 liq,,) = pm.getPositionInfo(pid, routers[r], TICK_LOWER, TICK_UPPER, SALT);
                if (liq == 0) continue;
                IPoolModifyLiquidityTest(routers[r]).modifyLiquidity(
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
                console2.log("  removed market", id);
                console2.log("    router", routers[r]);
                console2.log("    L", uint256(liq));
            }
        }
        vm.stopBroadcast();

        console2.log("=== DONE ===");
        console2.log("positions removed:", removed);
        console2.log("USDC recovered (total):", IERC20(usdc).balanceOf(deployer) - usdcBefore);
    }
}
