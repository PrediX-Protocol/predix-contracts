// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";

import {IAccessControlFacet} from "@predix/shared/interfaces/IAccessControlFacet.sol";
import {IDiamondCut} from "@predix/shared/interfaces/IDiamondCut.sol";
import {IDiamondLoupe} from "@predix/shared/interfaces/IDiamondLoupe.sol";
import {IPausableFacet} from "@predix/shared/interfaces/IPausableFacet.sol";

import {DiamondFixture} from "../utils/DiamondFixture.sol";

contract DiamondLoupeTest is DiamondFixture {
    function test_FacetAddresses_ReturnsAllFour() public view {
        address[] memory addrs = diamondLoupe.facetAddresses();
        assertEq(addrs.length, 4);
    }

    function test_Facets_GroupsSelectorsByFacet() public view {
        IDiamondLoupe.Facet[] memory all = diamondLoupe.facets();
        assertEq(all.length, 4);
        for (uint256 i; i < all.length; ++i) {
            assertGt(all[i].functionSelectors.length, 0);
        }
    }

    function test_FacetAddress_FindsRegisteredSelector() public view {
        assertEq(diamondLoupe.facetAddress(IDiamondCut.diamondCut.selector), address(cutFacet));
        assertEq(diamondLoupe.facetAddress(IPausableFacet.pause.selector), address(pausableFacet));
        assertEq(diamondLoupe.facetAddress(IAccessControlFacet.grantRole.selector), address(accessFacet));
    }

    function test_FacetAddress_UnknownSelector_ReturnsZero() public view {
        assertEq(diamondLoupe.facetAddress(0xdeadbeef), address(0));
    }

    function test_FacetFunctionSelectors_ListsExactSelectors() public view {
        bytes4[] memory s = diamondLoupe.facetFunctionSelectors(address(cutFacet));
        assertEq(s.length, 1);
        assertEq(s[0], IDiamondCut.diamondCut.selector);
    }

    function test_SupportsInterface_RegisteredOnes() public view {
        assertTrue(diamondErc165.supportsInterface(type(IERC165).interfaceId));
        assertTrue(diamondErc165.supportsInterface(type(IDiamondCut).interfaceId));
        assertTrue(diamondErc165.supportsInterface(type(IDiamondLoupe).interfaceId));
        assertTrue(diamondErc165.supportsInterface(type(IAccessControlFacet).interfaceId));
        assertTrue(diamondErc165.supportsInterface(type(IPausableFacet).interfaceId));
    }

    function test_SupportsInterface_Unknown_False() public view {
        assertFalse(diamondErc165.supportsInterface(0xdeadbeef));
    }
}
