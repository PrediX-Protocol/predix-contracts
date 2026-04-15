// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {IDiamondCut} from "@predix/shared/interfaces/IDiamondCut.sol";
import {IAccessControlFacet} from "@predix/shared/interfaces/IAccessControlFacet.sol";
import {Roles} from "@predix/shared/constants/Roles.sol";

import {Diamond} from "@predix/diamond/proxy/Diamond.sol";

import {DiamondFixture} from "../utils/DiamondFixture.sol";
import {IMockFacet, MockFacetA, MockFacetB} from "../utils/MockFacet.sol";

contract DiamondCutTest is DiamondFixture {
    MockFacetA internal mockA;
    MockFacetB internal mockB;

    function setUp() public override {
        super.setUp();
        mockA = new MockFacetA();
        mockB = new MockFacetB();
    }

    function _mockSelectors() internal pure returns (bytes4[] memory s) {
        s = new bytes4[](2);
        s[0] = IMockFacet.mockReadValue.selector;
        s[1] = IMockFacet.mockWriteValue.selector;
    }

    function _addMockA() internal {
        IDiamondCut.FacetCut[] memory cuts = new IDiamondCut.FacetCut[](1);
        cuts[0] = _add(address(mockA), _mockSelectors());
        vm.prank(timelock);
        diamondCut.diamondCut(cuts, address(0), "");
    }

    function test_Add_NewFacet_RoutesCalls() public {
        _addMockA();
        IMockFacet(address(diamond)).mockWriteValue(42);
        assertEq(IMockFacet(address(diamond)).mockReadValue(), 42);
    }

    function test_Replace_FacetSwapsImplementation() public {
        _addMockA();
        IMockFacet(address(diamond)).mockWriteValue(10);
        assertEq(IMockFacet(address(diamond)).mockReadValue(), 10);

        IDiamondCut.FacetCut[] memory cuts = new IDiamondCut.FacetCut[](1);
        cuts[0] = _replace(address(mockB), _mockSelectors());
        vm.prank(timelock);
        diamondCut.diamondCut(cuts, address(0), "");

        IMockFacet(address(diamond)).mockWriteValue(10);
        assertEq(IMockFacet(address(diamond)).mockReadValue(), 11);
    }

    function test_Remove_SelectorMakesItUnreachable() public {
        _addMockA();

        IDiamondCut.FacetCut[] memory cuts = new IDiamondCut.FacetCut[](1);
        cuts[0] = _remove(_mockSelectors());
        vm.prank(timelock);
        diamondCut.diamondCut(cuts, address(0), "");

        vm.expectRevert(
            abi.encodeWithSelector(Diamond.Diamond_FunctionNotFound.selector, IMockFacet.mockReadValue.selector)
        );
        IMockFacet(address(diamond)).mockReadValue();
    }

    function test_Revert_DiamondCut_NotCutExecutor() public {
        IDiamondCut.FacetCut[] memory cuts = new IDiamondCut.FacetCut[](1);
        cuts[0] = _add(address(mockA), _mockSelectors());

        address attacker = makeAddr("attacker");
        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControlFacet.AccessControl_MissingRole.selector, Roles.CUT_EXECUTOR_ROLE, attacker
            )
        );
        vm.prank(attacker);
        diamondCut.diamondCut(cuts, address(0), "");
    }

    function test_Revert_Add_ZeroAddress() public {
        IDiamondCut.FacetCut[] memory cuts = new IDiamondCut.FacetCut[](1);
        cuts[0] = _add(address(0), _mockSelectors());
        vm.expectRevert(IDiamondCut.DiamondCut_AddZeroAddress.selector);
        vm.prank(timelock);
        diamondCut.diamondCut(cuts, address(0), "");
    }

    function test_Revert_Add_NoSelectors() public {
        IDiamondCut.FacetCut[] memory cuts = new IDiamondCut.FacetCut[](1);
        cuts[0] = _add(address(mockA), new bytes4[](0));
        vm.expectRevert(IDiamondCut.DiamondCut_NoSelectors.selector);
        vm.prank(timelock);
        diamondCut.diamondCut(cuts, address(0), "");
    }

    function test_Revert_Add_ExistingSelector() public {
        _addMockA();
        IDiamondCut.FacetCut[] memory cuts = new IDiamondCut.FacetCut[](1);
        cuts[0] = _add(address(mockB), _mockSelectors());
        vm.expectRevert(
            abi.encodeWithSelector(
                IDiamondCut.DiamondCut_AddExistingSelector.selector, IMockFacet.mockReadValue.selector
            )
        );
        vm.prank(timelock);
        diamondCut.diamondCut(cuts, address(0), "");
    }

    function test_Revert_Replace_MissingSelector() public {
        IDiamondCut.FacetCut[] memory cuts = new IDiamondCut.FacetCut[](1);
        cuts[0] = _replace(address(mockA), _mockSelectors());
        vm.expectRevert(
            abi.encodeWithSelector(
                IDiamondCut.DiamondCut_ReplaceMissingSelector.selector, IMockFacet.mockReadValue.selector
            )
        );
        vm.prank(timelock);
        diamondCut.diamondCut(cuts, address(0), "");
    }

    function test_Revert_Replace_SameFacet() public {
        _addMockA();
        IDiamondCut.FacetCut[] memory cuts = new IDiamondCut.FacetCut[](1);
        cuts[0] = _replace(address(mockA), _mockSelectors());
        vm.expectRevert(
            abi.encodeWithSelector(IDiamondCut.DiamondCut_ReplaceSameFacet.selector, IMockFacet.mockReadValue.selector)
        );
        vm.prank(timelock);
        diamondCut.diamondCut(cuts, address(0), "");
    }

    function test_Revert_Remove_NonZeroAddress() public {
        IDiamondCut.FacetCut[] memory cuts = new IDiamondCut.FacetCut[](1);
        cuts[0] = IDiamondCut.FacetCut({
            facetAddress: address(mockA), action: IDiamondCut.FacetCutAction.Remove, functionSelectors: _mockSelectors()
        });
        vm.expectRevert(IDiamondCut.DiamondCut_RemoveNonZeroAddress.selector);
        vm.prank(timelock);
        diamondCut.diamondCut(cuts, address(0), "");
    }

    function test_Revert_Remove_MissingSelector() public {
        IDiamondCut.FacetCut[] memory cuts = new IDiamondCut.FacetCut[](1);
        cuts[0] = _remove(_mockSelectors());
        vm.expectRevert(
            abi.encodeWithSelector(
                IDiamondCut.DiamondCut_RemoveMissingSelector.selector, IMockFacet.mockReadValue.selector
            )
        );
        vm.prank(timelock);
        diamondCut.diamondCut(cuts, address(0), "");
    }

    function test_Revert_Add_FacetHasNoCode() public {
        address eoa = makeAddr("eoa");
        IDiamondCut.FacetCut[] memory cuts = new IDiamondCut.FacetCut[](1);
        cuts[0] = _add(eoa, _mockSelectors());
        vm.expectRevert(abi.encodeWithSelector(IDiamondCut.DiamondCut_FacetHasNoCode.selector, eoa));
        vm.prank(timelock);
        diamondCut.diamondCut(cuts, address(0), "");
    }

    function test_Revert_Init_NoCode_WithData() public {
        address eoa = makeAddr("noCode");
        vm.expectRevert(abi.encodeWithSelector(IDiamondCut.DiamondCut_InitHasNoCode.selector, eoa));
        vm.prank(timelock);
        diamondCut.diamondCut(new IDiamondCut.FacetCut[](0), eoa, hex"deadbeef");
    }

    function test_Revert_Init_InitWithoutData() public {
        vm.expectRevert(IDiamondCut.DiamondCut_InitWithoutData.selector);
        vm.prank(timelock);
        diamondCut.diamondCut(new IDiamondCut.FacetCut[](0), address(diamondInit), "");
    }

    function test_Revert_Init_DataWithoutInit() public {
        vm.expectRevert(IDiamondCut.DiamondCut_DataWithoutInit.selector);
        vm.prank(timelock);
        diamondCut.diamondCut(new IDiamondCut.FacetCut[](0), address(0), hex"1234");
    }

    function test_Revert_Remove_DiamondCutSelector_Immutable() public {
        bytes4[] memory s = new bytes4[](1);
        s[0] = IDiamondCut.diamondCut.selector;
        IDiamondCut.FacetCut[] memory cuts = new IDiamondCut.FacetCut[](1);
        cuts[0] = _remove(s);
        vm.expectRevert(
            abi.encodeWithSelector(
                IDiamondCut.DiamondCut_RemoveImmutableSelector.selector, IDiamondCut.diamondCut.selector
            )
        );
        vm.prank(timelock);
        diamondCut.diamondCut(cuts, address(0), "");
    }

    function test_Revert_Replace_DiamondCutSelector_Immutable() public {
        bytes4[] memory s = new bytes4[](1);
        s[0] = IDiamondCut.diamondCut.selector;
        IDiamondCut.FacetCut[] memory cuts = new IDiamondCut.FacetCut[](1);
        cuts[0] = _replace(address(mockA), s);
        vm.expectRevert(
            abi.encodeWithSelector(
                IDiamondCut.DiamondCut_RemoveImmutableSelector.selector, IDiamondCut.diamondCut.selector
            )
        );
        vm.prank(timelock);
        diamondCut.diamondCut(cuts, address(0), "");
    }
}
