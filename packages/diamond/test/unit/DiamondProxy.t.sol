// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {IDiamondCut} from "@predix/shared/interfaces/IDiamondCut.sol";

import {Diamond} from "@predix/diamond/proxy/Diamond.sol";
import {DiamondInit} from "@predix/diamond/init/DiamondInit.sol";

import {DiamondFixture} from "../utils/DiamondFixture.sol";

contract DiamondProxyTest is DiamondFixture {
    function test_Revert_Constructor_ZeroAdmin() public {
        DiamondInit init = new DiamondInit();
        IDiamondCut.FacetCut[] memory cuts = new IDiamondCut.FacetCut[](0);
        bytes memory initData = abi.encodeCall(DiamondInit.init, (address(0xBEEF), timelock));
        vm.expectRevert(Diamond.Diamond_ZeroAdmin.selector);
        new Diamond(address(0), cuts, address(init), initData);
    }

    function test_Revert_Fallback_FunctionNotFound() public {
        bytes4 unknown = bytes4(keccak256("nonExistent()"));
        vm.expectRevert(abi.encodeWithSelector(Diamond.Diamond_FunctionNotFound.selector, unknown));
        (bool ok,) = address(diamond).call(abi.encodeWithSelector(unknown));
        ok;
    }

    /// @notice F5 regression — ETH sent to diamond is rejected with explicit error.
    function test_Revert_Fallback_BareEthRejected() public {
        vm.deal(address(this), 1 ether);
        vm.expectRevert(Diamond.Diamond_NoETHAccepted.selector);
        (bool ok,) = address(diamond).call{value: 1 ether}("");
        ok;
    }

    /// @notice F5 regression — ETH sent WITH a valid selector also reverts.
    function test_Revert_Fallback_ETHWithValidSelector() public {
        vm.deal(address(this), 1 ether);
        vm.expectRevert(Diamond.Diamond_NoETHAccepted.selector);
        (bool ok,) = address(diamond).call{value: 1 ether}(abi.encodeWithSignature("marketCount()"));
        ok;
    }

    function test_Revert_DiamondInit_CannotBeReinitialized() public {
        bytes memory initData = abi.encodeCall(DiamondInit.init, (admin, timelock));
        vm.expectRevert(DiamondInit.DiamondInit_AlreadyInitialized.selector);
        vm.prank(timelock);
        diamondCut.diamondCut(new IDiamondCut.FacetCut[](0), address(diamondInit), initData);
    }
}
