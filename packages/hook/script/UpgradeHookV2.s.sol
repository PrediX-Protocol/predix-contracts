// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import {Script, console2} from "forge-std/Script.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";

import {PrediXHookV2} from "@predix/hook/hooks/PrediXHookV2.sol";
import {IPrediXHookProxy} from "@predix/hook/interfaces/IPrediXHookProxy.sol";

/// @title UpgradeHookV2
/// @notice Gap#4 IN-PLACE hook upgrade: deploy a new `PrediXHookV2` implementation that carries the
///         bounded-LP `_beforeAddLiquidity` guard, built with the EXACT immutables of the LIVE impl —
///         read off-chain from the live implementation, NOT from env — so the admin-rotation timelock
///         and pool-key params cannot silently drift (the dev-beta env carries a relaxed 1h rotation
///         delay, while the live impl was deployed with 48h; copying live keeps it 48h). Prints the
///         proxy `proposeUpgrade`/`executeUpgrade` calldata for the proxyAdmin multisig to submit.
///         The proxy address is unchanged (permission flags untouched), so every existing AMM pool
///         stays valid and no salt re-mine is needed.
/// @dev DRY-RUN by default (run WITHOUT `--broadcast` first). Required env:
///      `HOOK_PROXY_ADDRESS` + (`MNEMONIC` | `DEPLOYER_PRIVATE_KEY`).
contract UpgradeHookV2 is Script {
    /// @dev Verified LIVE mainnet (chain 130) immutables — the new impl MUST match these exactly.
    ///      Sourced from on-chain read 2026-05-31; see RUNBOOK_UPGRADE_GAP1_GAP4.md §0.
    address internal constant LIVE_POOL_MANAGER = 0x1F98400000000000000000000000000000000004;
    int24 internal constant LIVE_TICK_SPACING = 60;
    uint24 internal constant LIVE_LP_FEE = uint24(0x800000);
    // Hook RUNTIME admin-rotation delay (impl immutable), live-read 2026-05-31. This is NOT the proxy's
    // 48h UPGRADE timelock (timelockDuration = 172800) — a separate, mutable proxy-storage value.
    uint256 internal constant LIVE_ADMIN_ROTATION_DELAY = 3600; // 1h

    function run() external returns (address newImpl) {
        address proxy = vm.envAddress("HOOK_PROXY_ADDRESS");

        // Read the LIVE immutables off the current implementation so ONLY the guard logic changes.
        PrediXHookV2 live = PrediXHookV2(IPrediXHookProxy(proxy).implementation());
        IPoolManager pm = live.poolManager();
        address quoter = live.quoter();
        uint24 lpFee = live.canonicalLpFee();
        int24 spacing = live.canonicalTickSpacing();
        uint256 rotDelay = live.ADMIN_ROTATION_DELAY();

        // Fail loud if any live immutable drifted from the verified mainnet value: a drifted new impl
        // would change pool-key enforcement or the admin-rotation timelock under the same address.
        require(address(pm) == LIVE_POOL_MANAGER, "poolManager drift");
        require(spacing == LIVE_TICK_SPACING, "tickSpacing drift");
        require(lpFee == LIVE_LP_FEE, "lpFee drift");
        require(rotDelay == LIVE_ADMIN_ROTATION_DELAY, "adminRotationDelay drift");

        string memory mnemonic = vm.envOr("MNEMONIC", string(""));
        uint256 key = bytes(mnemonic).length > 0 ? vm.deriveKey(mnemonic, 0) : vm.envUint("DEPLOYER_PRIVATE_KEY");

        vm.startBroadcast(key);
        newImpl = address(new PrediXHookV2(pm, quoter, lpFee, spacing, rotDelay));
        vm.stopBroadcast();

        console2.log("=== UpgradeHookV2 (Gap#4 bounded-LP) ===");
        console2.log("proxy:     ", proxy);
        console2.log("old impl:  ", address(live));
        console2.log("new impl:  ", newImpl);
        console2.log("proxyAdmin:", IPrediXHookProxy(proxy).proxyAdmin());
        console2.log(">> STEP A - proxyAdmin (Safe) submits to the proxy (proposeUpgrade). to =", proxy);
        console2.logBytes(abi.encodeWithSignature("proposeUpgrade(address)", newImpl));
        console2.log(">> STEP B - after 48h, proxyAdmin (Safe) submits to the proxy (executeUpgrade). to =", proxy);
        console2.logBytes(abi.encodeWithSignature("executeUpgrade()"));
    }
}
