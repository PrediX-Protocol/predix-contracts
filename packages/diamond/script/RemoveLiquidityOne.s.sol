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

/// @notice TEST: remove ONE full-range LP position that was seeded via the Phase7 scripts
///         (owned by a `PoolModifyLiquidityTest` router). Reads the position's CURRENT liquidity
///         on-chain, removes ALL of it, and returns the underlying YES + USDC to the deployer
///         (msg.sender of `modifyLiquidity`). DRY-RUN by default — add `--broadcast` to execute.
/// @dev    Required env: POOL_MANAGER_ADDRESS, HOOK_PROXY_ADDRESS, USDC_ADDRESS, MNEMONIC (HD-0)
///         or DEPLOYER_PRIVATE_KEY, plus LP_REMOVE_ROUTER + LP_REMOVE_YES for the target position.
///         The seed used full-range ticks [-887220, 887220], salt 0, dynamic-fee pool key.
contract RemoveLiquidityOne is Script {
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
        address router = vm.envAddress("LP_REMOVE_ROUTER");
        address yes = vm.envAddress("LP_REMOVE_YES");

        // Canonical v4 ordering: currency0 < currency1 by raw address.
        bool yesIsCurrency0 = yes < usdc;
        (address c0, address c1) = yesIsCurrency0 ? (yes, usdc) : (usdc, yes);
        PoolKey memory key = PoolKey({
            currency0: Currency.wrap(c0),
            currency1: Currency.wrap(c1),
            fee: LPFeeLibrary.DYNAMIC_FEE_FLAG,
            tickSpacing: TICK_SPACING,
            hooks: IHooks(hook)
        });
        PoolId pid = key.toId();

        (uint128 liq,,) = pm.getPositionInfo(pid, router, TICK_LOWER, TICK_UPPER, SALT);
        console2.log("=== Remove LP (TEST, 1 position) ===");
        console2.log("router (owner):    ", router);
        console2.log("YES token:         ", yes);
        console2.log("yesIsCurrency0:    ", yesIsCurrency0);
        console2.log("current liquidity L:", uint256(liq));
        require(liq > 0, "position has no liquidity (already removed / not active)");

        string memory mnemonic = vm.envOr("MNEMONIC", string(""));
        uint256 pk = bytes(mnemonic).length > 0 ? vm.deriveKey(mnemonic, 0) : vm.envUint("DEPLOYER_PRIVATE_KEY");
        address deployer = vm.addr(pk);
        uint256 yesBefore = IERC20(yes).balanceOf(deployer);
        uint256 usdcBefore = IERC20(usdc).balanceOf(deployer);

        vm.startBroadcast(pk);
        IPoolModifyLiquidityTest(router)
            .modifyLiquidity(
                key,
                ModifyLiquidityParams({
                    tickLower: TICK_LOWER, tickUpper: TICK_UPPER, liquidityDelta: -int256(uint256(liq)), salt: SALT
                }),
                ""
            );
        vm.stopBroadcast();

        (uint128 liqAfter,,) = pm.getPositionInfo(pid, router, TICK_LOWER, TICK_UPPER, SALT);
        console2.log("liquidity AFTER:   ", uint256(liqAfter));
        console2.log("YES recovered:     ", IERC20(yes).balanceOf(deployer) - yesBefore);
        console2.log("USDC recovered:    ", IERC20(usdc).balanceOf(deployer) - usdcBefore);
        console2.log("deployer:          ", deployer);
    }
}
