// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";
import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";

import {IAccessControlFacet} from "@predix/shared/interfaces/IAccessControlFacet.sol";
import {IDiamondCut} from "@predix/shared/interfaces/IDiamondCut.sol";
import {IDiamondLoupe} from "@predix/shared/interfaces/IDiamondLoupe.sol";
import {IPausableFacet} from "@predix/shared/interfaces/IPausableFacet.sol";

import {AccessControlFacet} from "@predix/diamond/facets/access/AccessControlFacet.sol";
import {DiamondCutFacet} from "@predix/diamond/facets/cut/DiamondCutFacet.sol";
import {DiamondLoupeFacet} from "@predix/diamond/facets/loupe/DiamondLoupeFacet.sol";
import {PausableFacet} from "@predix/diamond/facets/pausable/PausableFacet.sol";
import {DiamondInit} from "@predix/diamond/init/DiamondInit.sol";
import {Diamond} from "@predix/diamond/proxy/Diamond.sol";

abstract contract DiamondFixture is Test {
    Diamond internal diamond;
    DiamondCutFacet internal cutFacet;
    DiamondLoupeFacet internal loupeFacet;
    AccessControlFacet internal accessFacet;
    PausableFacet internal pausableFacet;
    DiamondInit internal diamondInit;

    IDiamondCut internal diamondCut;
    IDiamondLoupe internal diamondLoupe;
    IERC165 internal diamondErc165;
    IAccessControlFacet internal accessControl;
    IPausableFacet internal pausable;

    address internal admin = makeAddr("admin");
    address internal timelock = makeAddr("timelock");

    function setUp() public virtual {
        cutFacet = new DiamondCutFacet();
        loupeFacet = new DiamondLoupeFacet();
        accessFacet = new AccessControlFacet();
        pausableFacet = new PausableFacet();
        diamondInit = new DiamondInit();

        IDiamondCut.FacetCut[] memory cuts = new IDiamondCut.FacetCut[](4);
        cuts[0] = _add(address(cutFacet), _cutSelectors());
        cuts[1] = _add(address(loupeFacet), _loupeSelectors());
        cuts[2] = _add(address(accessFacet), _accessSelectors());
        cuts[3] = _add(address(pausableFacet), _pausableSelectors());

        bytes memory initData = abi.encodeCall(DiamondInit.init, (admin, timelock));
        diamond = new Diamond(admin, cuts, address(diamondInit), initData);

        diamondCut = IDiamondCut(address(diamond));
        diamondLoupe = IDiamondLoupe(address(diamond));
        diamondErc165 = IERC165(address(diamond));
        accessControl = IAccessControlFacet(address(diamond));
        pausable = IPausableFacet(address(diamond));
    }

    function _add(address facet, bytes4[] memory selectors) internal pure returns (IDiamondCut.FacetCut memory) {
        return IDiamondCut.FacetCut({
            facetAddress: facet, action: IDiamondCut.FacetCutAction.Add, functionSelectors: selectors
        });
    }

    function _remove(bytes4[] memory selectors) internal pure returns (IDiamondCut.FacetCut memory) {
        return IDiamondCut.FacetCut({
            facetAddress: address(0), action: IDiamondCut.FacetCutAction.Remove, functionSelectors: selectors
        });
    }

    function _replace(address facet, bytes4[] memory selectors) internal pure returns (IDiamondCut.FacetCut memory) {
        return IDiamondCut.FacetCut({
            facetAddress: facet, action: IDiamondCut.FacetCutAction.Replace, functionSelectors: selectors
        });
    }

    function _cutSelectors() internal pure returns (bytes4[] memory s) {
        s = new bytes4[](1);
        s[0] = IDiamondCut.diamondCut.selector;
    }

    function _loupeSelectors() internal pure returns (bytes4[] memory s) {
        s = new bytes4[](5);
        s[0] = IDiamondLoupe.facets.selector;
        s[1] = IDiamondLoupe.facetFunctionSelectors.selector;
        s[2] = IDiamondLoupe.facetAddresses.selector;
        s[3] = IDiamondLoupe.facetAddress.selector;
        s[4] = IERC165.supportsInterface.selector;
    }

    function _accessSelectors() internal pure returns (bytes4[] memory s) {
        s = new bytes4[](5);
        s[0] = IAccessControlFacet.hasRole.selector;
        s[1] = IAccessControlFacet.getRoleAdmin.selector;
        s[2] = IAccessControlFacet.grantRole.selector;
        s[3] = IAccessControlFacet.revokeRole.selector;
        s[4] = IAccessControlFacet.renounceRole.selector;
    }

    function _pausableSelectors() internal pure returns (bytes4[] memory s) {
        s = new bytes4[](6);
        s[0] = IPausableFacet.pause.selector;
        s[1] = IPausableFacet.unpause.selector;
        s[2] = IPausableFacet.pauseModule.selector;
        s[3] = IPausableFacet.unpauseModule.selector;
        s[4] = IPausableFacet.paused.selector;
        s[5] = IPausableFacet.isModulePaused.selector;
    }
}
