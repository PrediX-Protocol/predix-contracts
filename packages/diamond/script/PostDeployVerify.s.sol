// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import {Script, console2} from "forge-std/Script.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {TimelockController} from "@openzeppelin/contracts/governance/TimelockController.sol";

import {IAccessControlFacet} from "@predix/shared/interfaces/IAccessControlFacet.sol";
import {IDiamondCut} from "@predix/shared/interfaces/IDiamondCut.sol";
import {IDiamondLoupe} from "@predix/shared/interfaces/IDiamondLoupe.sol";
import {IEventFacet} from "@predix/shared/interfaces/IEventFacet.sol";
import {IMarketFacet} from "@predix/shared/interfaces/IMarketFacet.sol";
import {IPausableFacet} from "@predix/shared/interfaces/IPausableFacet.sol";
import {Roles} from "@predix/shared/constants/Roles.sol";

import {IPrediXHook} from "@predix/hook/interfaces/IPrediXHook.sol";

import {DeployEnvVerifier} from "./lib/DeployEnvVerifier.sol";

interface IExchangeView {
    function diamond() external view returns (address);
    function usdc() external view returns (address);
    function feeRecipient() external view returns (address);
    function paused() external view returns (bool);
}

interface IRouterView {
    function diamond() external view returns (address);
    function usdc() external view returns (address);
    function hook() external view returns (address);
    function exchange() external view returns (address);
    function poolManager() external view returns (address);
    function quoter() external view returns (address);
    function permit2() external view returns (address);
}

interface IExchangeProxyAdminRead {
    function admin() external view returns (address);
    function implementation() external view returns (address);
}

interface IHookProxyAdminRead {
    function proxyAdmin() external view returns (address);
    function implementation() external view returns (address);
}

interface IChainlinkOracleView {
    function diamond() external view returns (address);
    function sequencerUptimeFeed() external view returns (address);
}

interface IManualOracleView {
    function diamond() external view returns (address);
}

/// @title PostDeployVerify
/// @notice Standalone health check that re-asserts every wiring invariant on a
///         live deploy. Reads deployed addresses + expected admins from env and
///         reverts on the first discrepancy. Safe to run at any time after a
///         deploy — performs zero state changes — so it doubles as a periodic
///         integrity monitor.
///
///         Required env: DIAMOND_ADDRESS, HOOK_PROXY_ADDRESS, EXCHANGE_ADDRESS,
///         ROUTER_ADDRESS, ORACLE_MANUAL_ADDRESS, TIMELOCK_ADDRESS,
///         MULTISIG_ADDRESS, PAUSER_ADDRESS, HOOK_PROXY_ADMIN,
///         HOOK_RUNTIME_ADMIN, EXCHANGE_PROXY_ADMIN, USDC_ADDRESS,
///         POOL_MANAGER_ADDRESS, V4_QUOTER_ADDRESS, PERMIT2_ADDRESS,
///         FEE_RECIPIENT, DEPLOYER_ADDRESS.
///         Optional: ORACLE_CHAINLINK_ADDRESS, CHAINLINK_ENABLED,
///         CHAINLINK_SEQUENCER_UPTIME_FEED.
///
///         Usage:
///             forge script PostDeployVerify --rpc-url $UNICHAIN_RPC_PRIMARY
contract PostDeployVerify is Script {
    error PostDeployVerify_Failed(string what);

    struct Targets {
        address diamond;
        address hookProxy;
        address exchange;
        address router;
        address manualOracle;
        address chainlinkOracle;
        address timelock;
        address multisig;
        address pauser;
        address hookProxyAdmin;
        address hookRuntimeAdmin;
        address exchangeProxyAdmin;
        address usdc;
        address poolManager;
        address v4Quoter;
        address permit2;
        address feeRecipient;
        address deployer;
        address sequencerUptimeFeed;
        bool chainlinkEnabled;
    }

    function run() external view {
        Targets memory t = _loadTargets();

        console2.log("PostDeployVerify: chainId =", block.chainid);
        console2.log("PostDeployVerify: diamond  =", t.diamond);

        _verifyEnvCanonicals(t);
        _verifyDiamondRoles(t);
        _verifyDiamondFacetRoutes(t);
        _verifyTimelock(t);
        _verifyHook(t);
        _verifyExchange(t);
        _verifyRouter(t);
        _verifyOracles(t);
        _verifyPauseStateConsistent(t);

        console2.log("PostDeployVerify: OK");
    }

    // ---------------------------------------------------------------- env ---

    function _loadTargets() internal view returns (Targets memory t) {
        t.diamond = vm.envAddress("DIAMOND_ADDRESS");
        t.hookProxy = vm.envAddress("HOOK_PROXY_ADDRESS");
        t.exchange = vm.envAddress("EXCHANGE_ADDRESS");
        t.router = vm.envAddress("ROUTER_ADDRESS");
        t.manualOracle = vm.envAddress("ORACLE_MANUAL_ADDRESS");
        t.timelock = vm.envAddress("TIMELOCK_ADDRESS");
        t.multisig = vm.envAddress("MULTISIG_ADDRESS");
        t.pauser = vm.envAddress("PAUSER_ADDRESS");
        t.hookProxyAdmin = vm.envAddress("HOOK_PROXY_ADMIN");
        t.hookRuntimeAdmin = vm.envAddress("HOOK_RUNTIME_ADMIN");
        t.exchangeProxyAdmin = vm.envAddress("EXCHANGE_PROXY_ADMIN");
        t.usdc = vm.envAddress("USDC_ADDRESS");
        t.poolManager = vm.envAddress("POOL_MANAGER_ADDRESS");
        t.v4Quoter = vm.envAddress("V4_QUOTER_ADDRESS");
        t.permit2 = vm.envAddress("PERMIT2_ADDRESS");
        t.feeRecipient = vm.envAddress("FEE_RECIPIENT");
        t.deployer = vm.envAddress("DEPLOYER_ADDRESS");
        t.chainlinkEnabled = vm.envOr("CHAINLINK_ENABLED", false);
        if (t.chainlinkEnabled) {
            t.chainlinkOracle = vm.envAddress("ORACLE_CHAINLINK_ADDRESS");
            t.sequencerUptimeFeed = vm.envOr("CHAINLINK_SEQUENCER_UPTIME_FEED", address(0));
        }
    }

    // ----------------------------------------------------- canonical infra ---

    function _verifyEnvCanonicals(Targets memory t) internal view {
        // Re-run the same canonical-address checks DeployAll runs at deploy
        // time. Catches the case where a later operator action accidentally
        // changes env to point at a non-canonical Permit2.
        DeployEnvVerifier.verifyPermit2(block.chainid, t.permit2);
        if (t.chainlinkEnabled) {
            DeployEnvVerifier.verifySequencerFeed(block.chainid, t.sequencerUptimeFeed);
        }
    }

    // ----------------------------------------------------- diamond access ---

    function _verifyDiamondRoles(Targets memory t) internal view {
        IAccessControlFacet ac = IAccessControlFacet(t.diamond);

        if (!ac.hasRole(Roles.DEFAULT_ADMIN_ROLE, t.multisig)) {
            revert PostDeployVerify_Failed("multisig missing DEFAULT_ADMIN_ROLE");
        }
        if (!ac.hasRole(Roles.ADMIN_ROLE, t.multisig)) revert PostDeployVerify_Failed("multisig missing ADMIN_ROLE");
        if (!ac.hasRole(Roles.OPERATOR_ROLE, t.multisig)) {
            revert PostDeployVerify_Failed("multisig missing OPERATOR_ROLE");
        }
        if (!ac.hasRole(Roles.CREATOR_ROLE, t.multisig)) {
            revert PostDeployVerify_Failed("multisig missing CREATOR_ROLE");
        }
        if (!ac.hasRole(Roles.PAUSER_ROLE, t.pauser)) revert PostDeployVerify_Failed("pauser missing PAUSER_ROLE");
        if (!ac.hasRole(Roles.CUT_EXECUTOR_ROLE, t.timelock)) {
            revert PostDeployVerify_Failed("timelock missing CUT_EXECUTOR_ROLE");
        }

        // Deployer MUST have renounced every privileged diamond role.
        if (ac.hasRole(Roles.DEFAULT_ADMIN_ROLE, t.deployer)) {
            revert PostDeployVerify_Failed("deployer still holds DEFAULT_ADMIN_ROLE");
        }
        if (ac.hasRole(Roles.ADMIN_ROLE, t.deployer)) revert PostDeployVerify_Failed("deployer still holds ADMIN_ROLE");
        if (ac.hasRole(Roles.OPERATOR_ROLE, t.deployer)) {
            revert PostDeployVerify_Failed("deployer still holds OPERATOR_ROLE");
        }
        if (ac.hasRole(Roles.PAUSER_ROLE, t.deployer)) {
            revert PostDeployVerify_Failed("deployer still holds PAUSER_ROLE");
        }

        // Split-key model: PAUSER_ADDRESS != MULTISIG_ADDRESS must mean
        // multisig no longer holds PAUSER_ROLE.
        if (t.pauser != t.multisig && ac.hasRole(Roles.PAUSER_ROLE, t.multisig)) {
            revert PostDeployVerify_Failed("multisig still holds PAUSER after split");
        }
    }

    function _verifyDiamondFacetRoutes(Targets memory t) internal view {
        IDiamondLoupe loupe = IDiamondLoupe(t.diamond);

        // Sentinel selectors per facet. Each must route to a non-zero
        // facet address; the precise address is verified by the lib
        // `verifyPostDeploy` at deploy time but a non-zero route here
        // catches accidental selector wipes.
        bytes4[7] memory sentinels = [
            IDiamondCut.diamondCut.selector,
            IDiamondLoupe.facets.selector,
            IAccessControlFacet.hasRole.selector,
            IPausableFacet.paused.selector,
            IMarketFacet.createMarket.selector,
            IMarketFacet.redeem.selector,
            IEventFacet.createEvent.selector
        ];
        for (uint256 i = 0; i < sentinels.length; ++i) {
            if (loupe.facetAddress(sentinels[i]) == address(0)) {
                revert PostDeployVerify_Failed("facet route missing");
            }
        }
    }

    // ----------------------------------------------------------- timelock ---

    function _verifyTimelock(Targets memory t) internal view {
        TimelockController tl = TimelockController(payable(t.timelock));
        if (tl.getMinDelay() < 48 hours) revert PostDeployVerify_Failed("timelock minDelay below 48h");
        if (!tl.hasRole(tl.PROPOSER_ROLE(), t.multisig)) {
            revert PostDeployVerify_Failed("multisig missing timelock PROPOSER");
        }
        if (!tl.hasRole(tl.EXECUTOR_ROLE(), t.multisig)) {
            revert PostDeployVerify_Failed("multisig missing timelock EXECUTOR");
        }
        // Timelock self-admin: TimelockController revokes the explicit
        // TIMELOCK_ADMIN_ROLE from the deployer in its constructor when
        // `admin == address(0)`. The role is held by the timelock itself.
        if (tl.hasRole(tl.DEFAULT_ADMIN_ROLE(), t.deployer)) {
            revert PostDeployVerify_Failed("deployer still holds timelock admin");
        }
    }

    // --------------------------------------------------------------- hook ---

    function _verifyHook(Targets memory t) internal view {
        IPrediXHook hook = IPrediXHook(t.hookProxy);
        if (hook.diamond() != t.diamond) revert PostDeployVerify_Failed("hook.diamond != DIAMOND_ADDRESS");
        if (hook.admin() != t.hookRuntimeAdmin) revert PostDeployVerify_Failed("hook.admin != HOOK_RUNTIME_ADMIN");
        if (!hook.isTrustedRouter(t.router)) revert PostDeployVerify_Failed("router not trusted on hook");
        if (!hook.isTrustedRouter(t.v4Quoter)) revert PostDeployVerify_Failed("v4Quoter not trusted on hook");

        // Proxy admin slot — separate from the hook's runtime admin.
        // The proxy admin can replace the implementation; the runtime
        // admin only configures the implementation. Both must be the
        // Safes specified in env.
        address proxyAdmin = IHookProxyAdminRead(t.hookProxy).proxyAdmin();
        if (proxyAdmin != t.hookProxyAdmin) revert PostDeployVerify_Failed("hook proxy admin mismatch");

        address impl = IHookProxyAdminRead(t.hookProxy).implementation();
        if (impl == address(0) || impl.code.length == 0) revert PostDeployVerify_Failed("hook impl missing");
    }

    // ----------------------------------------------------------- exchange ---

    function _verifyExchange(Targets memory t) internal view {
        IExchangeView ex = IExchangeView(t.exchange);
        if (ex.diamond() != t.diamond) revert PostDeployVerify_Failed("exchange.diamond != DIAMOND_ADDRESS");
        if (ex.usdc() != t.usdc) revert PostDeployVerify_Failed("exchange.usdc != USDC_ADDRESS");
        if (ex.feeRecipient() != t.feeRecipient) revert PostDeployVerify_Failed("exchange.feeRecipient mismatch");

        // The exchange must have its max USDC allowance to the current
        // diamond intact, otherwise the synthetic MINT path is broken.
        if (IERC20(t.usdc).allowance(t.exchange, t.diamond) != type(uint256).max) {
            revert PostDeployVerify_Failed("exchange USDC allowance to diamond is not max");
        }

        address proxyAdmin = IExchangeProxyAdminRead(t.exchange).admin();
        if (proxyAdmin != t.exchangeProxyAdmin) revert PostDeployVerify_Failed("exchange proxy admin mismatch");

        address impl = IExchangeProxyAdminRead(t.exchange).implementation();
        if (impl == address(0) || impl.code.length == 0) revert PostDeployVerify_Failed("exchange impl missing");
    }

    // ------------------------------------------------------------- router ---

    function _verifyRouter(Targets memory t) internal view {
        IRouterView r = IRouterView(t.router);
        if (r.diamond() != t.diamond) revert PostDeployVerify_Failed("router.diamond mismatch");
        if (r.usdc() != t.usdc) revert PostDeployVerify_Failed("router.usdc mismatch");
        if (r.hook() != t.hookProxy) revert PostDeployVerify_Failed("router.hook mismatch");
        if (r.exchange() != t.exchange) revert PostDeployVerify_Failed("router.exchange mismatch");
        if (r.poolManager() != t.poolManager) revert PostDeployVerify_Failed("router.poolManager mismatch");
        if (r.quoter() != t.v4Quoter) revert PostDeployVerify_Failed("router.quoter mismatch");
        if (r.permit2() != t.permit2) revert PostDeployVerify_Failed("router.permit2 mismatch");
        if (r.permit2() != DeployEnvVerifier.CANONICAL_PERMIT2) {
            revert PostDeployVerify_Failed("router.permit2 not canonical");
        }
    }

    // ------------------------------------------------------------ oracles ---

    function _verifyOracles(Targets memory t) internal view {
        IMarketFacet mkt = IMarketFacet(t.diamond);

        // ManualOracle — always deployed.
        if (IManualOracleView(t.manualOracle).diamond() != t.diamond) {
            revert PostDeployVerify_Failed("manualOracle.diamond mismatch");
        }
        if (!mkt.isOracleApproved(t.manualOracle)) revert PostDeployVerify_Failed("manualOracle not approved");
        if (!AccessControl(t.manualOracle).hasRole(Roles.DEFAULT_ADMIN_ROLE,t.multisig)) {
            revert PostDeployVerify_Failed("manualOracle DEFAULT_ADMIN != multisig");
        }
        if (AccessControl(t.manualOracle).hasRole(Roles.DEFAULT_ADMIN_ROLE,t.deployer)) {
            revert PostDeployVerify_Failed("deployer still has manualOracle DEFAULT_ADMIN");
        }

        if (!t.chainlinkEnabled) return;

        IChainlinkOracleView cl = IChainlinkOracleView(t.chainlinkOracle);
        if (cl.diamond() != t.diamond) revert PostDeployVerify_Failed("chainlinkOracle.diamond mismatch");
        if (cl.sequencerUptimeFeed() != t.sequencerUptimeFeed) {
            revert PostDeployVerify_Failed("chainlinkOracle.sequencerUptimeFeed != env");
        }
        if (!mkt.isOracleApproved(t.chainlinkOracle)) revert PostDeployVerify_Failed("chainlinkOracle not approved");
        if (!AccessControl(t.chainlinkOracle).hasRole(Roles.DEFAULT_ADMIN_ROLE,t.multisig)) {
            revert PostDeployVerify_Failed("chainlinkOracle DEFAULT_ADMIN != multisig");
        }
        if (AccessControl(t.chainlinkOracle).hasRole(Roles.DEFAULT_ADMIN_ROLE,t.deployer)) {
            revert PostDeployVerify_Failed("deployer still has chainlinkOracle DEFAULT_ADMIN");
        }
    }

    // ------------------------------------------------------ pause sanity ---

    function _verifyPauseStateConsistent(Targets memory t) internal view {
        // Diamond pause and exchange pause are independent surfaces; this
        // function only asserts both are readable (i.e., the facets are
        // wired and the exchange proxy delegates correctly). Beta deploys
        // may legitimately start either or both paused — that policy
        // decision lives outside this verifier.
        IPausableFacet(t.diamond).paused();
        IExchangeView(t.exchange).paused();
        IPrediXHook(t.hookProxy).paused();
    }
}
