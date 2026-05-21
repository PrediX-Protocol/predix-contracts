// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";

import {IAccessControlFacet} from "@predix/shared/interfaces/IAccessControlFacet.sol";
import {IDiamondCut} from "@predix/shared/interfaces/IDiamondCut.sol";
import {IDiamondLoupe} from "@predix/shared/interfaces/IDiamondLoupe.sol";
import {IPausableFacet} from "@predix/shared/interfaces/IPausableFacet.sol";
import {IMarketFacet} from "@predix/shared/interfaces/IMarketFacet.sol";
import {IEventFacet} from "@predix/shared/interfaces/IEventFacet.sol";

import {EventFixture} from "../utils/EventFixture.sol";

/// @notice Pins the diamond's ERC-165 registry. Every facet interface the diamond
///         actually routes must be advertised via `supportsInterface`, and
///         unknown ids must report false. Guards the D-1 fix: `IEventFacet` was
///         previously omitted even though `EventFacet`'s selectors are routable.
contract DiamondErc165InterfacesTest is EventFixture {
    function test_AdvertisesAllRoutedInterfaces() public view {
        assertTrue(diamondErc165.supportsInterface(type(IERC165).interfaceId), "IERC165");
        assertTrue(diamondErc165.supportsInterface(type(IDiamondCut).interfaceId), "IDiamondCut");
        assertTrue(diamondErc165.supportsInterface(type(IDiamondLoupe).interfaceId), "IDiamondLoupe");
        assertTrue(diamondErc165.supportsInterface(type(IAccessControlFacet).interfaceId), "IAccessControlFacet");
        assertTrue(diamondErc165.supportsInterface(type(IPausableFacet).interfaceId), "IPausableFacet");
        assertTrue(diamondErc165.supportsInterface(type(IMarketFacet).interfaceId), "IMarketFacet");
        assertTrue(diamondErc165.supportsInterface(type(IEventFacet).interfaceId), "IEventFacet");
    }

    function test_DoesNotAdvertiseUnknownInterface() public view {
        // A random id that no facet implements must report false (and 0xffffffff
        // is the ERC-165 invalid sentinel that must always be false).
        assertFalse(diamondErc165.supportsInterface(0xdeadbeef), "unknown id");
        assertFalse(diamondErc165.supportsInterface(0xffffffff), "ERC165 invalid sentinel");
    }
}
