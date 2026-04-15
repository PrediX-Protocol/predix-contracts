// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";

import {IAccessControlFacet} from "@predix/shared/interfaces/IAccessControlFacet.sol";
import {IDiamondLoupe} from "@predix/shared/interfaces/IDiamondLoupe.sol";
import {IEventFacet} from "@predix/shared/interfaces/IEventFacet.sol";
import {IMarketFacet} from "@predix/shared/interfaces/IMarketFacet.sol";
import {Roles} from "@predix/shared/constants/Roles.sol";

import {DiamondDeployLib} from "../../script/lib/DiamondDeployLib.sol";
import {MockUSDC} from "../mocks/MockUSDC.sol";

/// @notice Exercises the shared diamond deploy library end-to-end: facet deploy → diamond
///         constructor (with deployer as temporary admin) → MarketInit wiring via second
///         diamondCut → governance handover → post-deploy verification. Runs without any
///         RPC fork — uses MockUSDC as the collateral token.
contract DiamondDeployLibTest is Test {
    address internal deployer = makeAddr("deployer");
    address internal multisig = makeAddr("multisig");
    address internal timelock = makeAddr("timelock");
    address internal feeRecipient = makeAddr("feeRecipient");

    MockUSDC internal usdc;

    function setUp() public {
        usdc = new MockUSDC();
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
}
