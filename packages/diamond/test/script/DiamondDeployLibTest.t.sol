// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";

import {TimelockController} from "@openzeppelin/contracts/governance/TimelockController.sol";

import {IAccessControlFacet} from "@predix/shared/interfaces/IAccessControlFacet.sol";
import {IDiamondLoupe} from "@predix/shared/interfaces/IDiamondLoupe.sol";
import {IEventFacet} from "@predix/shared/interfaces/IEventFacet.sol";
import {IMarketFacet} from "@predix/shared/interfaces/IMarketFacet.sol";
import {Roles} from "@predix/shared/constants/Roles.sol";

import {DiamondDeployLib} from "../../script/lib/DiamondDeployLib.sol";
import {MockUSDC} from "../mocks/MockUSDC.sol";

/// @dev External wrapper so `vm.expectRevert` can observe library reverts
///      (vm cheatcodes target the next call-depth frame; library internals
///      inline into the test contract and do not cross the frame).
contract VerifyPostDeployWrapper {
    function run(address diamond, DiamondDeployLib.FacetAddresses memory f, address multisig, address timelock)
        external
        view
    {
        DiamondDeployLib.verifyPostDeploy(diamond, f, multisig, timelock);
    }
}

/// @notice Exercises the shared diamond deploy library end-to-end: facet deploy → diamond
///         constructor (with deployer as temporary admin) → MarketInit wiring via second
///         diamondCut → governance handover → post-deploy verification. Runs without any
///         RPC fork — uses MockUSDC as the collateral token.
contract DiamondDeployLibTest is Test {
    address internal deployer = makeAddr("deployer");
    address internal multisig = makeAddr("multisig");
    address internal feeRecipient = makeAddr("feeRecipient");

    // Real TimelockController so `verifyPostDeploy` can assert `getMinDelay()`.
    TimelockController internal timelockController;
    address internal timelock;

    MockUSDC internal usdc;

    function setUp() public {
        usdc = new MockUSDC();

        address[] memory proposers = new address[](1);
        proposers[0] = multisig;
        address[] memory executors = new address[](1);
        executors[0] = multisig;
        timelockController = new TimelockController(48 hours, proposers, executors, address(0));
        timelock = address(timelockController);
    }

    function test_DeployFullDiamond_FinalState() public {
        vm.startPrank(deployer);

        DiamondDeployLib.FacetAddresses memory facets = DiamondDeployLib.deployFacets();
        address diamond = DiamondDeployLib.deployDiamondWithDeployerAdmin(facets, deployer);
        DiamondDeployLib.wireMarketAndEvent(diamond, facets, address(usdc), feeRecipient, 0, 0);

        // Deployer can hit ADMIN_ROLE-gated setters before handover.
        IMarketFacet(diamond).setDefaultRedemptionFeeBps(100);

        DiamondDeployLib.transferGovernance(diamond, deployer, multisig, timelock);

        vm.stopPrank();

        DiamondDeployLib.verifyPostDeploy(diamond, facets, multisig, timelock);

        IAccessControlFacet ac = IAccessControlFacet(diamond);
        assertTrue(ac.hasRole(Roles.DEFAULT_ADMIN_ROLE, multisig), "multisig DEFAULT_ADMIN_ROLE");
        assertTrue(ac.hasRole(Roles.ADMIN_ROLE, multisig), "multisig ADMIN_ROLE");
        assertTrue(ac.hasRole(Roles.OPERATOR_ROLE, multisig), "multisig OPERATOR_ROLE");
        assertTrue(ac.hasRole(Roles.PAUSER_ROLE, multisig), "multisig PAUSER_ROLE");
        assertTrue(ac.hasRole(Roles.CUT_EXECUTOR_ROLE, timelock), "timelock CUT_EXECUTOR_ROLE");

        assertFalse(ac.hasRole(Roles.DEFAULT_ADMIN_ROLE, deployer), "deployer DEFAULT_ADMIN_ROLE revoked");
        assertFalse(ac.hasRole(Roles.ADMIN_ROLE, deployer), "deployer ADMIN_ROLE revoked");
        assertFalse(ac.hasRole(Roles.OPERATOR_ROLE, deployer), "deployer OPERATOR_ROLE revoked");
        assertFalse(ac.hasRole(Roles.PAUSER_ROLE, deployer), "deployer PAUSER_ROLE revoked");
        assertFalse(ac.hasRole(Roles.CUT_EXECUTOR_ROLE, deployer), "deployer CUT_EXECUTOR_ROLE revoked");

        IMarketFacet market = IMarketFacet(diamond);
        assertEq(market.feeRecipient(), feeRecipient, "fee recipient");
        assertEq(market.defaultRedemptionFeeBps(), 100, "redemption fee");
        assertEq(market.marketCount(), 0, "marketCount");

        IDiamondLoupe loupe = IDiamondLoupe(diamond);
        assertEq(loupe.facetAddress(IEventFacet.createEvent.selector), facets.eventF, "event facet route");
        assertEq(loupe.facetAddress(IMarketFacet.createMarket.selector), facets.market, "market facet route");
    }

    /// @notice Repro for NEW-03 defense-in-depth: if a team reuses an existing
    ///         timelock contract whose `getMinDelay() < 48h` (for example a dev
    ///         timelock or a misconfigured instance), the post-deploy assertion
    ///         MUST catch it even though the env-level floor check passed.
    function test_Revert_VerifyPostDeploy_TimelockMinDelayBelowFloor() public {
        address[] memory proposers = new address[](1);
        proposers[0] = multisig;
        address[] memory executors = new address[](1);
        executors[0] = multisig;
        TimelockController shortTimelock = new TimelockController(1 hours, proposers, executors, address(0));

        vm.startPrank(deployer);
        DiamondDeployLib.FacetAddresses memory facets = DiamondDeployLib.deployFacets();
        address diamond = DiamondDeployLib.deployDiamondWithDeployerAdmin(facets, deployer);
        DiamondDeployLib.wireMarketAndEvent(diamond, facets, address(usdc), feeRecipient, 0, 0);
        DiamondDeployLib.transferGovernance(diamond, deployer, multisig, address(shortTimelock));
        vm.stopPrank();

        VerifyPostDeployWrapper wrapper = new VerifyPostDeployWrapper();
        vm.expectRevert(abi.encodeWithSelector(DiamondDeployLib.DeployFailed.selector, "timelock minDelay"));
        wrapper.run(diamond, facets, multisig, address(shortTimelock));
    }
}
