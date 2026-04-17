// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import {TimelockController} from "@openzeppelin/contracts/governance/TimelockController.sol";

import {IAccessControlFacet} from "@predix/shared/interfaces/IAccessControlFacet.sol";
import {IDiamondCut} from "@predix/shared/interfaces/IDiamondCut.sol";
import {IDiamondLoupe} from "@predix/shared/interfaces/IDiamondLoupe.sol";
import {IEventFacet} from "@predix/shared/interfaces/IEventFacet.sol";
import {IMarketFacet} from "@predix/shared/interfaces/IMarketFacet.sol";
import {IPausableFacet} from "@predix/shared/interfaces/IPausableFacet.sol";
import {Roles} from "@predix/shared/constants/Roles.sol";

import {AccessControlFacet} from "@predix/diamond/facets/access/AccessControlFacet.sol";
import {DiamondCutFacet} from "@predix/diamond/facets/cut/DiamondCutFacet.sol";
import {DiamondLoupeFacet} from "@predix/diamond/facets/loupe/DiamondLoupeFacet.sol";
import {EventFacet} from "@predix/diamond/facets/event/EventFacet.sol";
import {MarketFacet} from "@predix/diamond/facets/market/MarketFacet.sol";
import {PausableFacet} from "@predix/diamond/facets/pausable/PausableFacet.sol";
import {DiamondInit} from "@predix/diamond/init/DiamondInit.sol";
import {MarketInit} from "@predix/diamond/init/MarketInit.sol";
import {Diamond} from "@predix/diamond/proxy/Diamond.sol";

/// @title DiamondDeployLib
/// @notice Shared building blocks for deploying the PrediX diamond. Used by both
///         `DeployDiamond.s.sol` (standalone) and `DeployAll.s.sol` (orchestration).
///         All deploy-time behavior lives here so the two scripts cannot drift.
library DiamondDeployLib {
    struct FacetAddresses {
        address cut;
        address loupe;
        address access;
        address pausable;
        address market;
        address eventF;
        address diamondInit;
        address marketInit;
    }

    error ZeroAddress(string name);
    error DeployFailed(string step);

    /// @dev `deployer` is granted DEFAULT_ADMIN_ROLE by Diamond's constructor AND
    ///      ADMIN/OPERATOR/PAUSER/CUT_EXECUTOR via DiamondInit.init. This allows a
    ///      single EOA to complete wiring (MarketInit diamondCut + approveOracle)
    ///      before handing over to multisig + Timelock in `transferGovernance`.
    function deployFacets() internal returns (FacetAddresses memory f) {
        f.cut = address(new DiamondCutFacet());
        f.loupe = address(new DiamondLoupeFacet());
        f.access = address(new AccessControlFacet());
        f.pausable = address(new PausableFacet());
        f.market = address(new MarketFacet());
        f.eventF = address(new EventFacet());
        f.diamondInit = address(new DiamondInit());
        f.marketInit = address(new MarketInit());
    }

    function buildCoreCuts(FacetAddresses memory f) internal pure returns (IDiamondCut.FacetCut[] memory cuts) {
        cuts = new IDiamondCut.FacetCut[](4);
        cuts[0] = _cut(f.cut, _cutSelectors());
        cuts[1] = _cut(f.loupe, _loupeSelectors());
        cuts[2] = _cut(f.access, _accessSelectors());
        cuts[3] = _cut(f.pausable, _pausableSelectors());
    }

    function buildMarketAndEventCuts(FacetAddresses memory f)
        internal
        pure
        returns (IDiamondCut.FacetCut[] memory cuts)
    {
        cuts = new IDiamondCut.FacetCut[](2);
        cuts[0] = _cut(f.market, _marketSelectors());
        cuts[1] = _cut(f.eventF, _eventSelectors());
    }

    /// @notice Deploys the diamond proxy with core facets wired and runs `DiamondInit.init`
    ///         with `deployer` holding every admin role (including CUT_EXECUTOR).
    function deployDiamondWithDeployerAdmin(FacetAddresses memory f, address deployer) internal returns (address) {
        if (deployer == address(0)) revert ZeroAddress("deployer");
        bytes memory initData = abi.encodeCall(DiamondInit.init, (deployer, deployer));
        Diamond d = new Diamond(deployer, buildCoreCuts(f), f.diamondInit, initData);
        return address(d);
    }

    /// @notice Runs the second diamondCut that adds MarketFacet + EventFacet and
    ///         delegatecalls `MarketInit.init(args)` atomically. Caller must hold
    ///         `CUT_EXECUTOR_ROLE` at call time.
    function wireMarketAndEvent(
        address diamond,
        FacetAddresses memory f,
        address collateralToken,
        address feeRecipient,
        uint256 marketCreationFee,
        uint256 defaultPerMarketCap
    ) internal {
        if (collateralToken == address(0)) revert ZeroAddress("collateralToken");
        if (feeRecipient == address(0)) revert ZeroAddress("feeRecipient");

        MarketInit.InitArgs memory args = MarketInit.InitArgs({
            collateralToken: collateralToken,
            feeRecipient: feeRecipient,
            marketCreationFee: marketCreationFee,
            defaultPerMarketCap: defaultPerMarketCap
        });
        bytes memory initData = abi.encodeCall(MarketInit.init, (args));

        IDiamondCut(diamond).diamondCut(buildMarketAndEventCuts(f), f.marketInit, initData);
    }

    /// @notice Final governance handover. Grants `multisig` the four runtime admin roles,
    ///         grants `timelock` CUT_EXECUTOR_ROLE, and revokes everything from `deployer`.
    ///         Caller (deployer) must still hold DEFAULT_ADMIN_ROLE at entry.
    function transferGovernance(address diamond, address deployer, address multisig, address timelock) internal {
        if (multisig == address(0)) revert ZeroAddress("multisig");
        if (timelock == address(0)) revert ZeroAddress("timelock");

        IAccessControlFacet ac = IAccessControlFacet(diamond);

        ac.grantRole(Roles.DEFAULT_ADMIN_ROLE, multisig);
        ac.grantRole(Roles.ADMIN_ROLE, multisig);
        ac.grantRole(Roles.OPERATOR_ROLE, multisig);
        ac.grantRole(Roles.PAUSER_ROLE, multisig);
        ac.grantRole(Roles.CUT_EXECUTOR_ROLE, timelock);

        ac.revokeRole(Roles.CUT_EXECUTOR_ROLE, deployer);
        ac.revokeRole(Roles.PAUSER_ROLE, deployer);
        ac.revokeRole(Roles.OPERATOR_ROLE, deployer);
        ac.revokeRole(Roles.ADMIN_ROLE, deployer);
        ac.renounceRole(Roles.DEFAULT_ADMIN_ROLE, deployer);
    }

    /// @notice Asserts post-deploy invariants so that simulation will revert on a bad wiring.
    function verifyPostDeploy(address diamond, FacetAddresses memory f, address multisig, address timelock)
        internal
        view
    {
        IAccessControlFacet ac = IAccessControlFacet(diamond);
        if (!ac.hasRole(Roles.DEFAULT_ADMIN_ROLE, multisig)) revert DeployFailed("multisig DEFAULT_ADMIN");
        if (!ac.hasRole(Roles.ADMIN_ROLE, multisig)) revert DeployFailed("multisig ADMIN");
        if (!ac.hasRole(Roles.OPERATOR_ROLE, multisig)) revert DeployFailed("multisig OPERATOR");
        if (!ac.hasRole(Roles.PAUSER_ROLE, multisig)) revert DeployFailed("multisig PAUSER");
        if (!ac.hasRole(Roles.CUT_EXECUTOR_ROLE, timelock)) revert DeployFailed("timelock CUT_EXECUTOR");

        IDiamondLoupe loupe = IDiamondLoupe(diamond);
        if (loupe.facetAddress(IDiamondCut.diamondCut.selector) != f.cut) revert DeployFailed("cut route");
        if (loupe.facetAddress(IMarketFacet.createMarket.selector) != f.market) revert DeployFailed("market route");
        if (loupe.facetAddress(IEventFacet.createEvent.selector) != f.eventF) revert DeployFailed("event route");

        // Defense-in-depth for NEW-03: the env-level floor in
        // `DeployAll._requireTimelockFloor` catches typos in
        // `TIMELOCK_DELAY_SECONDS`, but if a team reuses an existing timelock
        // contract whose `getMinDelay()` is below 48h (e.g. a dev timelock),
        // only this post-deploy assertion catches it.
        if (TimelockController(payable(timelock)).getMinDelay() < 48 hours) {
            revert DeployFailed("timelock minDelay");
        }
    }

    // ------------------------------------------------------------------ selectors ---

    function _cut(address facet, bytes4[] memory selectors) private pure returns (IDiamondCut.FacetCut memory) {
        return IDiamondCut.FacetCut({
            facetAddress: facet, action: IDiamondCut.FacetCutAction.Add, functionSelectors: selectors
        });
    }

    function _cutSelectors() private pure returns (bytes4[] memory s) {
        s = new bytes4[](1);
        s[0] = IDiamondCut.diamondCut.selector;
    }

    function _loupeSelectors() private pure returns (bytes4[] memory s) {
        s = new bytes4[](5);
        s[0] = IDiamondLoupe.facets.selector;
        s[1] = IDiamondLoupe.facetFunctionSelectors.selector;
        s[2] = IDiamondLoupe.facetAddresses.selector;
        s[3] = IDiamondLoupe.facetAddress.selector;
        s[4] = IERC165.supportsInterface.selector;
    }

    function _accessSelectors() private pure returns (bytes4[] memory s) {
        s = new bytes4[](5);
        s[0] = IAccessControlFacet.hasRole.selector;
        s[1] = IAccessControlFacet.getRoleAdmin.selector;
        s[2] = IAccessControlFacet.grantRole.selector;
        s[3] = IAccessControlFacet.revokeRole.selector;
        s[4] = IAccessControlFacet.renounceRole.selector;
    }

    function _pausableSelectors() private pure returns (bytes4[] memory s) {
        s = new bytes4[](6);
        s[0] = IPausableFacet.pause.selector;
        s[1] = IPausableFacet.unpause.selector;
        s[2] = IPausableFacet.pauseModule.selector;
        s[3] = IPausableFacet.unpauseModule.selector;
        s[4] = IPausableFacet.paused.selector;
        s[5] = IPausableFacet.isModulePaused.selector;
    }

    function _marketSelectors() private pure returns (bytes4[] memory s) {
        s = new bytes4[](27);
        s[0] = IMarketFacet.createMarket.selector;
        s[1] = IMarketFacet.splitPosition.selector;
        s[2] = IMarketFacet.mergePositions.selector;
        s[3] = IMarketFacet.resolveMarket.selector;
        s[4] = IMarketFacet.emergencyResolve.selector;
        s[5] = IMarketFacet.redeem.selector;
        s[6] = IMarketFacet.enableRefundMode.selector;
        s[7] = IMarketFacet.refund.selector;
        s[8] = IMarketFacet.sweepUnclaimed.selector;
        s[9] = IMarketFacet.approveOracle.selector;
        s[10] = IMarketFacet.revokeOracle.selector;
        s[11] = IMarketFacet.setFeeRecipient.selector;
        s[12] = IMarketFacet.setMarketCreationFee.selector;
        s[13] = IMarketFacet.setDefaultPerMarketCap.selector;
        s[14] = IMarketFacet.setPerMarketCap.selector;
        s[15] = IMarketFacet.getMarket.selector;
        s[16] = IMarketFacet.getMarketStatus.selector;
        s[17] = IMarketFacet.isOracleApproved.selector;
        s[18] = IMarketFacet.feeRecipient.selector;
        s[19] = IMarketFacet.marketCreationFee.selector;
        s[20] = IMarketFacet.defaultPerMarketCap.selector;
        s[21] = IMarketFacet.marketCount.selector;
        s[22] = IMarketFacet.setDefaultRedemptionFeeBps.selector;
        s[23] = IMarketFacet.setPerMarketRedemptionFeeBps.selector;
        s[24] = IMarketFacet.clearPerMarketRedemptionFee.selector;
        s[25] = IMarketFacet.defaultRedemptionFeeBps.selector;
        s[26] = IMarketFacet.effectiveRedemptionFeeBps.selector;
    }

    function _eventSelectors() private pure returns (bytes4[] memory s) {
        s = new bytes4[](6);
        s[0] = IEventFacet.createEvent.selector;
        s[1] = IEventFacet.resolveEvent.selector;
        s[2] = IEventFacet.enableEventRefundMode.selector;
        s[3] = IEventFacet.getEvent.selector;
        s[4] = IEventFacet.eventOfMarket.selector;
        s[5] = IEventFacet.eventCount.selector;
    }
}
