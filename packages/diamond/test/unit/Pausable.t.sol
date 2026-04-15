// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {IAccessControlFacet} from "@predix/shared/interfaces/IAccessControlFacet.sol";
import {IPausableFacet} from "@predix/shared/interfaces/IPausableFacet.sol";
import {Modules} from "@predix/shared/constants/Modules.sol";
import {Roles} from "@predix/shared/constants/Roles.sol";

import {DiamondFixture} from "../utils/DiamondFixture.sol";

contract PausableTest is DiamondFixture {
    address internal attacker = makeAddr("attacker");

    function test_Pause_HappyPath() public {
        vm.expectEmit(false, false, false, true);
        emit IPausableFacet.GlobalPaused(admin);
        vm.prank(admin);
        pausable.pause();
        assertTrue(pausable.paused());
    }

    function test_Unpause_HappyPath() public {
        vm.startPrank(admin);
        pausable.pause();
        pausable.unpause();
        vm.stopPrank();
        assertFalse(pausable.paused());
    }

    function test_PauseModule_OnlyAffectsOneModule() public {
        bytes32 other = keccak256("other");
        vm.prank(admin);
        pausable.pauseModule(Modules.MARKET);
        assertTrue(pausable.isModulePaused(Modules.MARKET));
        assertFalse(pausable.isModulePaused(other));
        assertFalse(pausable.paused());
    }

    function test_GlobalPause_OverridesAllModules() public {
        bytes32 other = keccak256("other");
        vm.prank(admin);
        pausable.pause();
        assertTrue(pausable.isModulePaused(Modules.MARKET));
        assertTrue(pausable.isModulePaused(other));
    }

    function test_UnpauseModule_HappyPath() public {
        vm.startPrank(admin);
        pausable.pauseModule(Modules.MARKET);
        pausable.unpauseModule(Modules.MARKET);
        vm.stopPrank();
        assertFalse(pausable.isModulePaused(Modules.MARKET));
    }

    function test_Revert_Pause_NotPauser() public {
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControlFacet.AccessControl_MissingRole.selector, Roles.PAUSER_ROLE, attacker)
        );
        vm.prank(attacker);
        pausable.pause();
    }

    function test_Revert_Pause_AlreadyPaused() public {
        vm.startPrank(admin);
        pausable.pause();
        vm.expectRevert(IPausableFacet.Pausable_GlobalAlreadyPaused.selector);
        pausable.pause();
        vm.stopPrank();
    }

    function test_Revert_Unpause_NotPaused() public {
        vm.expectRevert(IPausableFacet.Pausable_GlobalNotPaused.selector);
        vm.prank(admin);
        pausable.unpause();
    }

    function test_Revert_PauseModule_AlreadyPaused() public {
        vm.startPrank(admin);
        pausable.pauseModule(Modules.MARKET);
        vm.expectRevert(abi.encodeWithSelector(IPausableFacet.Pausable_ModuleAlreadyPaused.selector, Modules.MARKET));
        pausable.pauseModule(Modules.MARKET);
        vm.stopPrank();
    }

    function test_Revert_UnpauseModule_NotPaused() public {
        vm.expectRevert(abi.encodeWithSelector(IPausableFacet.Pausable_ModuleNotPaused.selector, Modules.MARKET));
        vm.prank(admin);
        pausable.unpauseModule(Modules.MARKET);
    }
}
