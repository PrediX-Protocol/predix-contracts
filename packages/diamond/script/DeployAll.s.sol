// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import {Script, console2} from "forge-std/Script.sol";
import {TimelockController} from "@openzeppelin/contracts/governance/TimelockController.sol";

import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IV4Quoter} from "@uniswap/v4-periphery/src/interfaces/IV4Quoter.sol";
import {HookMiner} from "@uniswap/v4-periphery/src/utils/HookMiner.sol";
import {IAllowanceTransfer} from "permit2/src/interfaces/IAllowanceTransfer.sol";

import {IMarketFacet} from "@predix/shared/interfaces/IMarketFacet.sol";

import {ChainlinkOracle} from "@predix/oracle/adapters/ChainlinkOracle.sol";
import {ManualOracle} from "@predix/oracle/adapters/ManualOracle.sol";
import {IPrediXHook} from "@predix/hook/interfaces/IPrediXHook.sol";
import {PrediXHookV2} from "@predix/hook/hooks/PrediXHookV2.sol";
import {PrediXHookProxyV2} from "@predix/hook/proxy/PrediXHookProxyV2.sol";
import {PrediXExchange} from "@predix/exchange/PrediXExchange.sol";
import {PrediXExchangeProxy} from "@predix/exchange/PrediXExchangeProxy.sol";
import {PrediXRouter} from "@predix/router/PrediXRouter.sol";

import {DeployEnvVerifier} from "./lib/DeployEnvVerifier.sol";
import {DiamondDeployLib} from "./lib/DiamondDeployLib.sol";

/// @title DeployAll
/// @notice End-to-end orchestrator. Deploys every contract in the correct order, wires the
///         diamond, approves oracles, deploys the hook proxy with a mined CREATE2 salt,
///         and hands governance to the multisig + Timelock in a single broadcast.
///
///         Ordering: Timelock → Diamond (+ facets + inits) → Oracles → approveOracle →
///                   Hook (impl + mined proxy) → Exchange → Router → transferGovernance.
///
///         Dry-run:
///             forge script DeployAll --rpc-url $UNICHAIN_RPC_PRIMARY --sender $DEPLOYER_ADDRESS
///         Live:
///             forge script DeployAll --rpc-url $UNICHAIN_RPC_PRIMARY --sender $DEPLOYER_ADDRESS --broadcast
contract DeployAll is Script {
    address internal constant CREATE2_DEPLOYER = 0x4e59b44847b379578588920cA78FbF26c0B4956C;

    uint160 internal constant HOOK_PERMISSION_FLAGS = uint160(
        Hooks.BEFORE_INITIALIZE_FLAG | Hooks.BEFORE_ADD_LIQUIDITY_FLAG | Hooks.BEFORE_REMOVE_LIQUIDITY_FLAG
            | Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_SWAP_FLAG | Hooks.BEFORE_DONATE_FLAG
    );

    /// @notice Default floor on the diamond cut timelock. Production deploys
    ///         leave this active to keep governance delays uniform with the
    ///         hook + exchange proxy upgrade timelocks. Dev-beta deploys may
    ///         override via `MIN_TIMELOCK_DELAY_SECONDS` env to a smaller
    ///         value; that override is only safe when caps are bounded.
    uint256 public constant DEFAULT_MIN_TIMELOCK_DELAY = 48 hours;

    /// @notice Absolute minimum the override may be set to. Below 1 hour the
    ///         governance window is shorter than typical block-explorer
    ///         indexing latency and operators cannot react.
    uint256 public constant ABSOLUTE_MIN_TIMELOCK_DELAY = 1 hours;

    /// @notice Helper used by the deploy flow and tests so the floor check is
    ///         unambiguously observable. Reverts when `delay < floor`.
    function _requireTimelockFloor(uint256 delay, uint256 floor) internal pure {
        require(floor >= ABSOLUTE_MIN_TIMELOCK_DELAY, "MIN_TIMELOCK_DELAY_SECONDS below 1h absolute floor");
        require(delay >= floor, "TIMELOCK_DELAY_SECONDS below configured floor");
    }

    struct Env {
        uint256 deployerKey;
        address deployer;
        address multisig;
        address pauser;
        address reporter;
        address registrar;
        address feeRecipient;
        address hookProxyAdmin;
        address hookRuntimeAdmin;
        address exchangeProxyAdmin;
        uint256 timelockDelay;
        uint256 minTimelockDelay;
        uint256 hookAdminRotationDelay;
        address usdc;
        IPoolManager poolManager;
        address permit2;
        address v4Quoter;
        bool chainlinkEnabled;
        address chainlinkSequencerFeed;
        uint256 marketCreationFee;
        uint256 defaultPerMarketCap;
        uint256 defaultRedemptionFeeBps;
        uint24 lpFeeFlag;
        int24 tickSpacing;
        // Staging flag: when false, the deploy skips the governance handover
        // (multisig grants, deployer renounces, hook completeBootstrap, hook
        // admin rotation) so the deployer retains admin power for iterative
        // staging ops. Production mainnet deploys must set to true.
        bool finalizeGovernance;
    }

    struct Addresses {
        address timelock;
        address diamond;
        address manualOracle;
        address chainlinkOracle;
        address hookImpl;
        address hookProxy;
        bytes32 hookSalt;
        address exchangeImpl;
        address exchangeProxy;
        address router;
        DiamondDeployLib.FacetAddresses facets;
    }

    error ZeroAddress(string name);

    function run() external returns (Addresses memory out) {
        Env memory env = _loadEnv();

        vm.startBroadcast(env.deployerKey);

        out.timelock = _deployTimelock(env);
        out.facets = DiamondDeployLib.deployFacets();
        out.diamond = DiamondDeployLib.deployDiamondWithDeployerAdmin(out.facets, env.deployer);
        DiamondDeployLib.wireMarketAndEvent(
            out.diamond, out.facets, env.usdc, env.feeRecipient, env.marketCreationFee, env.defaultPerMarketCap
        );

        if (env.defaultRedemptionFeeBps > 0) {
            IMarketFacet(out.diamond).setDefaultRedemptionFeeBps(env.defaultRedemptionFeeBps);
        }

        (out.manualOracle, out.chainlinkOracle) = _deployOracles(env, out.diamond);
        IMarketFacet(out.diamond).approveOracle(out.manualOracle);
        if (env.chainlinkEnabled) {
            IMarketFacet(out.diamond).approveOracle(out.chainlinkOracle);
        }

        (out.hookImpl, out.hookProxy, out.hookSalt) = _deployHook(env, out.diamond);

        out.exchangeImpl = address(new PrediXExchange());
        out.exchangeProxy = address(
            new PrediXExchangeProxy(out.exchangeImpl, env.exchangeProxyAdmin, out.diamond, env.usdc, env.feeRecipient)
        );

        out.router = address(
            new PrediXRouter(
                env.poolManager,
                out.diamond,
                env.usdc,
                out.hookProxy,
                out.exchangeProxy,
                IV4Quoter(env.v4Quoter),
                IAllowanceTransfer(env.permit2),
                env.lpFeeFlag,
                env.tickSpacing
            )
        );

        // Backlog #44 canonical fix: the hook's FINAL-H06 commit gate requires
        // both the router and the V4Quoter to be in its trusted-routers set.
        // Without these two calls, every `router.buyYes` / `sellYes` / `buyNo` /
        // `sellNo` call on chain reverts with `Hook_UntrustedCaller(router)`,
        // and every `router.quote*` call reverts with
        // `Hook_UntrustedCaller(quoter)` via the simulate-and-revert path.
        //
        // Phase 3 caught this as escapes #5 and #6 via manual operator txs; this
        // block folds both into the deploy pipeline so fresh deploys never need
        // post-broadcast wiring. The deployer is the temporary hook runtime admin
        // (see `_deployHook`) so these calls succeed inside the broadcast; the
        // final admin rotation to `env.hookRuntimeAdmin` is proposed immediately
        // afterwards and must be accepted by the incoming admin in a separate tx.
        IPrediXHook(out.hookProxy).setTrustedRouter(out.router, true);
        IPrediXHook(out.hookProxy).setTrustedRouter(env.v4Quoter, true);

        if (env.finalizeGovernance) {
            // H-H02: close the bootstrap window so post-deploy trust changes
            // must route through the 48h propose/execute flow. Once this fires,
            // the legacy immediate-apply `setTrustedRouter` setter is permanently
            // disabled on this hook instance.
            IPrediXHook(out.hookProxy).completeBootstrap();

            // Propose the final hook runtime admin. Rotation is two-step per SPEC_HOOK_V2:
            // the incoming admin must call `hook.acceptAdmin()` in a follow-up tx.
            if (env.hookRuntimeAdmin != env.deployer) {
                IPrediXHook(out.hookProxy).setAdmin(env.hookRuntimeAdmin);
            }

            DiamondDeployLib.transferGovernance(
                out.diamond, env.deployer, env.multisig, env.pauser, out.timelock
            );
        }

        vm.stopBroadcast();

        if (env.finalizeGovernance) {
            DiamondDeployLib.verifyPostDeploy(
                out.diamond, out.facets, env.multisig, env.pauser, out.timelock, env.minTimelockDelay
            );
        }
        _logSummary(env, out);
    }

    // ------------------------------------------------------------------- env ---

    function _loadEnv() internal view returns (Env memory e) {
        // Deployer key resolution: `MNEMONIC` takes precedence over
        // `DEPLOYER_PRIVATE_KEY` when set. The mnemonic is derived at the
        // standard BIP-44 path m/44'/60'/0'/0/0; downstream tooling
        // (DeriveAccountsFromMnemonic) prints higher indices so the operator
        // can import the same mnemonic into Metamask and pre-name the
        // role-specific accounts.
        string memory mnemonic = vm.envOr("MNEMONIC", string(""));
        if (bytes(mnemonic).length > 0) {
            e.deployerKey = vm.deriveKey(mnemonic, 0);
        } else {
            e.deployerKey = vm.envUint("DEPLOYER_PRIVATE_KEY");
        }
        e.deployer = vm.addr(e.deployerKey);
        e.multisig = vm.envAddress("MULTISIG_ADDRESS");
        // PAUSER_ADDRESS is intentionally a required env var (no fallback)
        // so the operator must make the separate-key vs single-key choice
        // explicitly. Set `PAUSER_ADDRESS=$MULTISIG_ADDRESS` for the
        // single-key model. See docs/KEY_MANAGEMENT_POLICY.md for the
        // separation rationale (audit N-10).
        e.pauser = vm.envAddress("PAUSER_ADDRESS");
        e.reporter = vm.envAddress("REPORTER_ADDRESS");
        e.feeRecipient = vm.envAddress("FEE_RECIPIENT");
        e.hookProxyAdmin = vm.envAddress("HOOK_PROXY_ADMIN");
        e.hookRuntimeAdmin = vm.envAddress("HOOK_RUNTIME_ADMIN");
        e.exchangeProxyAdmin = vm.envAddress("EXCHANGE_PROXY_ADMIN");
        e.timelockDelay = vm.envUint("TIMELOCK_DELAY_SECONDS");
        e.minTimelockDelay = vm.envOr("MIN_TIMELOCK_DELAY_SECONDS", DEFAULT_MIN_TIMELOCK_DELAY);
        _requireTimelockFloor(e.timelockDelay, e.minTimelockDelay);
        e.hookAdminRotationDelay = vm.envOr("HOOK_ADMIN_ROTATION_DELAY_SECONDS", uint256(48 hours));
        e.usdc = vm.envAddress("USDC_ADDRESS");
        e.poolManager = IPoolManager(vm.envAddress("POOL_MANAGER_ADDRESS"));
        e.permit2 = vm.envAddress("PERMIT2_ADDRESS");
        e.v4Quoter = vm.envAddress("V4_QUOTER_ADDRESS");
        e.chainlinkEnabled = vm.envBool("CHAINLINK_ENABLED");
        e.marketCreationFee = vm.envUint("MARKET_CREATION_FEE");
        e.defaultPerMarketCap = vm.envUint("DEFAULT_PER_MARKET_CAP");
        e.defaultRedemptionFeeBps = vm.envUint("DEFAULT_REDEMPTION_FEE_BPS");
        e.lpFeeFlag = uint24(vm.envUint("LP_FEE_FLAG"));
        e.tickSpacing = int24(vm.envInt("TICK_SPACING"));
        e.finalizeGovernance = vm.envOr("DIAMOND_FINALIZE_GOVERNANCE", false);

        if (e.chainlinkEnabled) {
            e.registrar = vm.envAddress("REGISTRAR_ADDRESS");
            // Pass address(0) on L1 or on chains without a Chainlink sequencer
            // feed. Documented in ChainlinkOracle.sol lines 24-27.
            e.chainlinkSequencerFeed = vm.envOr("CHAINLINK_SEQUENCER_UPTIME_FEED", address(0));
        }

        // Pre-flight: confirm canonical infrastructure addresses match the
        // target chain before opening a broadcast. Wrong PERMIT2_ADDRESS or a
        // sequencer feed not deployed on this chain would silently misconfigure
        // every router and Chainlink resolve until the first user-facing call
        // reverts.
        DeployEnvVerifier.verifyPermit2(block.chainid, e.permit2);
        if (e.chainlinkEnabled) {
            DeployEnvVerifier.verifySequencerFeed(block.chainid, e.chainlinkSequencerFeed);
        }
    }

    // --------------------------------------------------------------- steps ---

    function _deployTimelock(Env memory env) internal returns (address) {
        address[] memory proposers = new address[](1);
        proposers[0] = env.multisig;
        address[] memory executors = new address[](1);
        executors[0] = env.multisig;
        return address(new TimelockController(env.timelockDelay, proposers, executors, address(0)));
    }

    function _deployOracles(Env memory env, address diamond)
        internal
        returns (address manualAddr, address chainlinkAddr)
    {
        // Deployer holds DEFAULT_ADMIN_ROLE temporarily so we can grant the operational
        // role (reporter/registrar) in the same broadcast. Final handover to multisig is
        // the last two calls on each oracle. Mirrors `DiamondDeployLib.transferGovernance`.
        ManualOracle manualOracle = new ManualOracle(env.deployer, diamond);
        manualOracle.grantRole(manualOracle.REPORTER_ROLE(), env.reporter);
        if (env.finalizeGovernance) {
            manualOracle.grantRole(manualOracle.DEFAULT_ADMIN_ROLE(), env.multisig);
            manualOracle.renounceRole(manualOracle.DEFAULT_ADMIN_ROLE(), env.deployer);
        }
        manualAddr = address(manualOracle);

        if (env.chainlinkEnabled) {
            ChainlinkOracle chainlinkOracle = new ChainlinkOracle(env.deployer, env.chainlinkSequencerFeed, diamond);
            chainlinkOracle.grantRole(chainlinkOracle.REGISTRAR_ROLE(), env.registrar);
            if (env.finalizeGovernance) {
                chainlinkOracle.grantRole(chainlinkOracle.DEFAULT_ADMIN_ROLE(), env.multisig);
                chainlinkOracle.renounceRole(chainlinkOracle.DEFAULT_ADMIN_ROLE(), env.deployer);
            }
            chainlinkAddr = address(chainlinkOracle);
        }
    }

    /// @dev The hook proxy is constructed with `env.deployer` as the initial runtime
    ///      admin, not `env.hookRuntimeAdmin`. This lets the deploy broadcast wire
    ///      trusted routers (backlog #44 fix) in the same transaction batch before
    ///      proposing admin rotation to the final runtime admin. The actual rotation
    ///      acceptance (`hook.acceptAdmin()`) is a follow-up tx the final admin must
    ///      sign post-broadcast — documented in `packages/diamond/script/README.md`.
    function _deployHook(Env memory env, address diamond) internal returns (address impl, address proxy, bytes32 salt) {
        PrediXHookV2 implC = new PrediXHookV2(
            env.poolManager, env.v4Quoter, env.lpFeeFlag, env.tickSpacing, env.hookAdminRotationDelay
        );
        impl = address(implC);

        bytes memory constructorArgs =
            abi.encode(env.poolManager, impl, env.hookProxyAdmin, env.deployer, diamond, env.usdc);
        (address predicted, bytes32 mined) = HookMiner.find(
            CREATE2_DEPLOYER, HOOK_PERMISSION_FLAGS, type(PrediXHookProxyV2).creationCode, constructorArgs
        );
        salt = mined;

        PrediXHookProxyV2 proxyC = new PrediXHookProxyV2{salt: mined}(
            env.poolManager, impl, env.hookProxyAdmin, env.deployer, diamond, env.usdc
        );
        if (address(proxyC) != predicted) revert HookAddressMismatch(predicted, address(proxyC));
        if ((uint160(address(proxyC)) & Hooks.ALL_HOOK_MASK) != HOOK_PERMISSION_FLAGS) {
            revert HookPermissionBitsMismatch(address(proxyC));
        }
        proxy = address(proxyC);
    }

    // --------------------------------------------------------------- logs ---

    function _logSummary(Env memory env, Addresses memory out) internal pure {
        console2.log("============================================================");
        console2.log("PrediX V2 deployment complete");
        console2.log("============================================================");
        console2.log("deployer:        ", env.deployer);
        console2.log("multisig:        ", env.multisig);
        console2.log("------------------------------------------------------------");
        console2.log("Timelock:        ", out.timelock);
        console2.log("Diamond:         ", out.diamond);
        console2.log("  cut facet:     ", out.facets.cut);
        console2.log("  loupe facet:   ", out.facets.loupe);
        console2.log("  access facet:  ", out.facets.access);
        console2.log("  pausable facet:", out.facets.pausable);
        console2.log("  market facet:  ", out.facets.market);
        console2.log("  event facet:   ", out.facets.eventF);
        console2.log("  diamond init:  ", out.facets.diamondInit);
        console2.log("  market init:   ", out.facets.marketInit);
        console2.log("ManualOracle:    ", out.manualOracle);
        if (env.chainlinkEnabled) {
            console2.log("ChainlinkOracle: ", out.chainlinkOracle);
        } else {
            console2.log("ChainlinkOracle: SKIPPED (CHAINLINK_ENABLED=false)");
        }
        console2.log("Hook impl:       ", out.hookImpl);
        console2.log("Hook proxy:      ", out.hookProxy);
        console2.log("  salt:          ", vm.toString(out.hookSalt));
        console2.log("Exchange impl:   ", out.exchangeImpl);
        console2.log("Exchange proxy:  ", out.exchangeProxy);
        console2.log("Router:          ", out.router);
        console2.log("============================================================");
    }

    error HookAddressMismatch(address predicted, address actual);
    error HookPermissionBitsMismatch(address proxy);
}
