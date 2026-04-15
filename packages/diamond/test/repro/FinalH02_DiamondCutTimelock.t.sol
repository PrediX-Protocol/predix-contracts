// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {IAccessControlFacet} from "@predix/shared/interfaces/IAccessControlFacet.sol";
import {IDiamondCut} from "@predix/shared/interfaces/IDiamondCut.sol";
import {IPausableFacet} from "@predix/shared/interfaces/IPausableFacet.sol";
import {Modules} from "@predix/shared/constants/Modules.sol";
import {Roles} from "@predix/shared/constants/Roles.sol";

import {DiamondFixture} from "../utils/DiamondFixture.sol";

/// @notice Repro for FINAL-H02: diamondCut must require the dedicated
///         CUT_EXECUTOR_ROLE (held by an external timelock) and honour the
///         diamond-scoped pause. DEFAULT_ADMIN_ROLE alone is insufficient.
contract FinalH02_DiamondCutTimelock is DiamondFixture {
    function test_Revert_DiamondCut_AdminWithoutExecutorRole() public {
        // Admin holds DEFAULT_ADMIN_ROLE and every operational role but NOT
        // CUT_EXECUTOR_ROLE. A cut attempt from admin must revert — in the
        // pre-fix world it would succeed.
        IDiamondCut.FacetCut[] memory cuts = new IDiamondCut.FacetCut[](0);
        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControlFacet.AccessControl_MissingRole.selector, Roles.CUT_EXECUTOR_ROLE, admin
            )
        );
        vm.prank(admin);
        diamondCut.diamondCut(cuts, address(0), "");
    }

    function test_DiamondCut_TimelockPermitted() public {
        IDiamondCut.FacetCut[] memory cuts = new IDiamondCut.FacetCut[](0);
        vm.prank(timelock);
        diamondCut.diamondCut(cuts, address(0), "");
    }

    function test_Revert_DiamondCut_PausedModule() public {
        // Pauser pauses the diamond module — timelock-authorised cut must
        // still revert mid-flight so incident response can block further
        // facet mutation.
        vm.prank(admin);
        pausable.pauseModule(Modules.DIAMOND);

        IDiamondCut.FacetCut[] memory cuts = new IDiamondCut.FacetCut[](0);
        vm.expectRevert(
            abi.encodeWithSelector(IPausableFacet.Pausable_EnforcedPause.selector, Modules.DIAMOND)
        );
        vm.prank(timelock);
        diamondCut.diamondCut(cuts, address(0), "");
    }
}
