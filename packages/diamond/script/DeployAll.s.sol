// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

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
import {PrediXHookV2} from "@predix/hook/hooks/PrediXHookV2.sol";
import {PrediXHookProxyV2} from "@predix/hook/proxy/PrediXHookProxyV2.sol";
import {PrediXExchange} from "@predix/exchange/PrediXExchange.sol";
import {PrediXRouter} from "@predix/router/PrediXRouter.sol";

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

    struct Env {
        uint256 deployerKey;
        address deployer;
        address multisig;
        address reporter;
        address registrar;
        address feeRecipient;
        address hookProxyAdmin;
        address hookRuntimeAdmin;
        uint256 timelockDelay;
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
    }

    struct Addresses {
        address timelock;
        address diamond;
        address manualOracle;
        address chainlinkOracle;
        address hookImpl;
        address hookProxy;
        bytes32 hookSalt;
        address exchange;
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

        out.exchange = address(new PrediXExchange(out.diamond, env.usdc, env.feeRecipient));

        out.router = address(
            new PrediXRouter(
                env.poolManager,
                out.diamond,
                env.usdc,
                out.hookProxy,
                out.exchange,
                IV4Quoter(env.v4Quoter),
                IAllowanceTransfer(env.permit2),
                env.lpFeeFlag,
                env.tickSpacing
            )
        );

        DiamondDeployLib.transferGovernance(out.diamond, env.deployer, env.multisig, out.timelock);

        vm.stopBroadcast();

        DiamondDeployLib.verifyPostDeploy(out.diamond, out.facets, env.multisig, out.timelock);
        _logSummary(env, out);
    }

    // ------------------------------------------------------------------- env ---

    function _loadEnv() internal view returns (Env memory e) {
        e.deployerKey = vm.envUint("DEPLOYER_PRIVATE_KEY");
        e.deployer = vm.addr(e.deployerKey);
        e.multisig = vm.envAddress("MULTISIG_ADDRESS");
        e.reporter = vm.envAddress("REPORTER_ADDRESS");
        e.feeRecipient = vm.envAddress("FEE_RECIPIENT");
        e.hookProxyAdmin = vm.envAddress("HOOK_PROXY_ADMIN");
        e.hookRuntimeAdmin = vm.envAddress("HOOK_RUNTIME_ADMIN");
        e.timelockDelay = vm.envUint("TIMELOCK_DELAY_SECONDS");
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

        if (e.chainlinkEnabled) {
            e.registrar = vm.envAddress("REGISTRAR_ADDRESS");
            // Legitimate optional (Loại A): pass address(0) on L1 or on testnets without
            // a Chainlink sequencer feed. Documented in ChainlinkOracle.sol lines 24-27.
            e.chainlinkSequencerFeed = vm.envOr("CHAINLINK_SEQUENCER_UPTIME_FEED", address(0));
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
        manualOracle.grantRole(manualOracle.DEFAULT_ADMIN_ROLE(), env.multisig);
        manualOracle.renounceRole(manualOracle.DEFAULT_ADMIN_ROLE(), env.deployer);
        manualAddr = address(manualOracle);

        if (env.chainlinkEnabled) {
            ChainlinkOracle chainlinkOracle = new ChainlinkOracle(env.deployer, env.chainlinkSequencerFeed);
            chainlinkOracle.grantRole(chainlinkOracle.REGISTRAR_ROLE(), env.registrar);
            chainlinkOracle.grantRole(chainlinkOracle.DEFAULT_ADMIN_ROLE(), env.multisig);
            chainlinkOracle.renounceRole(chainlinkOracle.DEFAULT_ADMIN_ROLE(), env.deployer);
            chainlinkAddr = address(chainlinkOracle);
        }
    }

    function _deployHook(Env memory env, address diamond) internal returns (address impl, address proxy, bytes32 salt) {
        PrediXHookV2 implC = new PrediXHookV2(env.poolManager);
        impl = address(implC);

        bytes memory constructorArgs =
            abi.encode(env.poolManager, impl, env.hookProxyAdmin, env.hookRuntimeAdmin, diamond, env.usdc);
        (address predicted, bytes32 mined) = HookMiner.find(
            CREATE2_DEPLOYER, HOOK_PERMISSION_FLAGS, type(PrediXHookProxyV2).creationCode, constructorArgs
        );
        salt = mined;

        PrediXHookProxyV2 proxyC = new PrediXHookProxyV2{salt: mined}(
            env.poolManager, impl, env.hookProxyAdmin, env.hookRuntimeAdmin, diamond, env.usdc
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
        console2.log("Exchange:        ", out.exchange);
        console2.log("Router:          ", out.router);
        console2.log("============================================================");
    }

    error HookAddressMismatch(address predicted, address actual);
    error HookPermissionBitsMismatch(address proxy);
}
