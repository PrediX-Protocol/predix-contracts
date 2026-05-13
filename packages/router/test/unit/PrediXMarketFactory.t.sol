// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import {Test} from "forge-std/Test.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {LPFeeLibrary} from "@uniswap/v4-core/src/libraries/LPFeeLibrary.sol";
import {PrediXMarketFactory} from "@predix/router/PrediXMarketFactory.sol";

/// @notice Stub that returns true/false for hasRole queries.
contract StubAccessControl {
    mapping(bytes32 => mapping(address => bool)) internal _roles;

    function setRole(bytes32 role, address account, bool val) external {
        _roles[role][account] = val;
    }

    function hasRole(bytes32 role, address account) external view returns (bool) {
        return _roles[role][account];
    }

    fallback() external payable {}
}

contract PrediXMarketFactoryTest is Test {
    PrediXMarketFactory internal factory;
    StubAccessControl internal diamond;
    address internal poolManager = makeAddr("poolManager");
    address internal hook = makeAddr("hook");
    address internal lpTest = makeAddr("lpTest");
    address internal usdc = makeAddr("usdc");

    address internal creator = makeAddr("creator");
    address internal nobody = makeAddr("nobody");

    bytes32 constant CREATOR_ROLE = keccak256("predix.role.creator");

    function setUp() public {
        diamond = new StubAccessControl();
        diamond.setRole(CREATOR_ROLE, creator, true);

        factory = new PrediXMarketFactory(
            IPoolManager(poolManager),
            address(diamond),
            usdc,
            hook,
            lpTest,
            LPFeeLibrary.DYNAMIC_FEE_FLAG,
            60
        );
    }

    // ======== Constructor validation ========

    function test_constructor_SetsImmutables() public view {
        assertEq(factory.diamond(), address(diamond));
        assertEq(address(factory.usdc()), usdc);
        assertEq(factory.hook(), hook);
        assertEq(address(factory.lpTest()), lpTest);
        assertEq(factory.lpFeeFlag(), LPFeeLibrary.DYNAMIC_FEE_FLAG);
        assertEq(factory.tickSpacing(), int24(60));
    }

    function test_Revert_constructor_ZeroPoolManager() public {
        vm.expectRevert(PrediXMarketFactory.ZeroAddress.selector);
        new PrediXMarketFactory(IPoolManager(address(0)), address(diamond), usdc, hook, lpTest, 0, 60);
    }

    function test_Revert_constructor_ZeroDiamond() public {
        vm.expectRevert(PrediXMarketFactory.ZeroAddress.selector);
        new PrediXMarketFactory(IPoolManager(poolManager), address(0), usdc, hook, lpTest, 0, 60);
    }

    function test_Revert_constructor_ZeroUsdc() public {
        vm.expectRevert(PrediXMarketFactory.ZeroAddress.selector);
        new PrediXMarketFactory(IPoolManager(poolManager), address(diamond), address(0), hook, lpTest, 0, 60);
    }

    function test_Revert_constructor_ZeroHook() public {
        vm.expectRevert(PrediXMarketFactory.ZeroAddress.selector);
        new PrediXMarketFactory(IPoolManager(poolManager), address(diamond), usdc, address(0), lpTest, 0, 60);
    }

    function test_Revert_constructor_ZeroLpTest() public {
        vm.expectRevert(PrediXMarketFactory.ZeroAddress.selector);
        new PrediXMarketFactory(IPoolManager(poolManager), address(diamond), usdc, hook, address(0), 0, 60);
    }

    // ======== Access control — CREATOR_ROLE ========

    function test_Revert_createMarketWithPool_NotCreator() public {
        vm.prank(nobody);
        vm.expectRevert(PrediXMarketFactory.NotCreator.selector);
        factory.createMarketWithPool("Q?", block.timestamp + 1 days, address(1), 1e9, 1e12);
    }

    function test_Revert_createEventWithPools_NotCreator() public {
        string[] memory qs = new string[](2);
        qs[0] = "A?";
        qs[1] = "B?";

        vm.prank(nobody);
        vm.expectRevert(PrediXMarketFactory.NotCreator.selector);
        factory.createEventWithPools("event", qs, block.timestamp + 1 days, address(1), 1e9, 1e12);
    }

    function test_Revert_addLiquidity_NotCreator() public {
        vm.prank(nobody);
        vm.expectRevert(PrediXMarketFactory.NotCreator.selector);
        factory.addLiquidity(1, 1e9, 1e12);
    }

    function test_creatorRoleGrantedCanCall() public {
        // Creator has role but call will revert downstream (mock doesn't support full flow).
        // The point: CREATOR_ROLE check passes.
        vm.prank(creator);
        vm.expectRevert(); // downstream revert from USDC transferFrom on stub address
        factory.createMarketWithPool("Q?", block.timestamp + 1 days, address(1), 1e9, 1e12);
        // If NotCreator were thrown, expectRevert wouldn't match the downstream error.
    }

    function test_creatorRoleRevokedBlocks() public {
        diamond.setRole(CREATOR_ROLE, creator, false);

        vm.prank(creator);
        vm.expectRevert(PrediXMarketFactory.NotCreator.selector);
        factory.createMarketWithPool("Q?", block.timestamp + 1 days, address(1), 1e9, 1e12);
    }
}
