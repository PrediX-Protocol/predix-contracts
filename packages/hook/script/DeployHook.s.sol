// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Script, console2} from "forge-std/Script.sol";

import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {HookMiner} from "@uniswap/v4-periphery/src/utils/HookMiner.sol";

import {PrediXHookV2} from "@predix/hook/hooks/PrediXHookV2.sol";
import {PrediXHookProxyV2} from "@predix/hook/proxy/PrediXHookProxyV2.sol";

/// @title DeployHook
/// @notice Deploys `PrediXHookV2` (implementation) and `PrediXHookProxyV2` (CREATE2-salt-mined
///         proxy). The proxy address is the one registered with the v4 PoolManager, so its
///         low-order bits must match the permission bitmap returned by `getHookPermissions()`.
///
///         Salt mining uses `HookMiner.find(deployer, flags, creationCode, constructorArgs)`
///         where `deployer` is the canonical CREATE2 Deployer Proxy
///         `0x4e59b44847b379578588920cA78FbF26c0B4956C` that `forge script` uses when a `salt`
///         is supplied to `new Contract{salt: ...}(...)`.
contract DeployHook is Script {
    /// @dev Canonical CREATE2 Deployer Proxy used by `forge script` salted deploys.
    address internal constant CREATE2_DEPLOYER = 0x4e59b44847b379578588920cA78FbF26c0B4956C;

    /// @dev Permission flags for `PrediXHookV2.getHookPermissions()` — keep this in sync
    ///      with `packages/hook/src/hooks/PrediXHookV2.sol::getHookPermissions`.
    uint160 internal constant HOOK_PERMISSION_FLAGS = uint160(
        Hooks.BEFORE_INITIALIZE_FLAG | Hooks.BEFORE_ADD_LIQUIDITY_FLAG | Hooks.BEFORE_REMOVE_LIQUIDITY_FLAG
            | Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_SWAP_FLAG | Hooks.BEFORE_DONATE_FLAG
    );

    struct Deployed {
        address implementation;
        address proxy;
        bytes32 salt;
    }

    function run() external returns (Deployed memory out) {
        IPoolManager poolManager = IPoolManager(vm.envAddress("POOL_MANAGER_ADDRESS"));
        address proxyAdmin = vm.envAddress("HOOK_PROXY_ADMIN");
        address hookAdmin = vm.envAddress("HOOK_RUNTIME_ADMIN");
        address diamond = vm.envAddress("DIAMOND_ADDRESS");
        address usdc = vm.envAddress("USDC_ADDRESS");
        address quoter = vm.envAddress("V4_QUOTER_ADDRESS");
        // NEW-M4: canonical pool key params. Same env vars the Router's deploy
        // script consumes, so (fee, tickSpacing) enforcement on
        // registerMarketPool is guaranteed to match the Router's own swap path.
        uint24 canonicalLpFee = uint24(vm.envUint("LP_FEE_FLAG"));
        int24 canonicalTickSpacing = int24(vm.envInt("TICK_SPACING"));

        vm.startBroadcast(vm.envUint("DEPLOYER_PRIVATE_KEY"));
        out = _deploy(poolManager, proxyAdmin, hookAdmin, diamond, usdc, quoter, canonicalLpFee, canonicalTickSpacing);
        vm.stopBroadcast();

        console2.log("PrediXHookV2 (impl):", out.implementation);
        console2.log("PrediXHookProxyV2:   ", out.proxy);
        console2.log("  salt:", vm.toString(out.salt));
    }

    /// @dev Shared deploy helper used by `DeployAll`. Assumes a broadcast scope is open.
    function deploy(
        IPoolManager poolManager,
        address proxyAdmin,
        address hookAdmin,
        address diamond,
        address usdc,
        address quoter,
        uint24 canonicalLpFee,
        int24 canonicalTickSpacing
    ) external returns (Deployed memory) {
        return _deploy(poolManager, proxyAdmin, hookAdmin, diamond, usdc, quoter, canonicalLpFee, canonicalTickSpacing);
    }

    function _deploy(
        IPoolManager poolManager,
        address proxyAdmin,
        address hookAdmin,
        address diamond,
        address usdc,
        address quoter,
        uint24 canonicalLpFee,
        int24 canonicalTickSpacing
    ) internal returns (Deployed memory out) {
        PrediXHookV2 impl = new PrediXHookV2(poolManager, quoter, canonicalLpFee, canonicalTickSpacing);
        out.implementation = address(impl);

        bytes memory constructorArgs = abi.encode(poolManager, address(impl), proxyAdmin, hookAdmin, diamond, usdc);
        (address predicted, bytes32 salt) = HookMiner.find(
            CREATE2_DEPLOYER, HOOK_PERMISSION_FLAGS, type(PrediXHookProxyV2).creationCode, constructorArgs
        );

        PrediXHookProxyV2 proxy =
            new PrediXHookProxyV2{salt: salt}(poolManager, address(impl), proxyAdmin, hookAdmin, diamond, usdc);

        if (address(proxy) != predicted) revert HookAddressMismatch(predicted, address(proxy));
        if ((uint160(address(proxy)) & Hooks.ALL_HOOK_MASK) != HOOK_PERMISSION_FLAGS) {
            revert HookPermissionBitsMismatch(address(proxy));
        }

        out.proxy = address(proxy);
        out.salt = salt;
    }

    error HookAddressMismatch(address predicted, address actual);
    error HookPermissionBitsMismatch(address proxy);
}
