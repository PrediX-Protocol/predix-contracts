// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";

import {DeployAll} from "../../script/DeployAll.s.sol";

/// @dev Test harness exposing the internal floor check as external so
///      `vm.expectRevert` can observe its revert.
contract TimelockFloorHarness is DeployAll {
    function checkFloor(uint256 delay) external pure {
        _requireTimelockFloor(delay);
    }
}

/// @notice Repro for NEW-03: DeployAll must reject a timelock delay below
///         the 48h floor. Prevents a typo-deployed short delay from
///         neutering the CUT_EXECUTOR timelock at boot.
contract NEW_03_TimelockFloor is Test {
    TimelockFloorHarness internal harness;

    function setUp() public {
        harness = new TimelockFloorHarness();
    }

    function test_NEW_03_minTimelockDelayIs48Hours() public view {
        assertEq(harness.MIN_TIMELOCK_DELAY(), 48 hours, "floor must be 48h");
    }

    function test_NEW_03_requireTimelockFloorAccepts48h() public view {
        harness.checkFloor(48 hours);
        harness.checkFloor(72 hours);
        harness.checkFloor(7 days);
    }

    function test_Revert_NEW_03_requireTimelockFloorRejectsZero() public {
        vm.expectRevert(bytes("TIMELOCK_DELAY_SECONDS below 48h floor"));
        harness.checkFloor(0);
    }

    function test_Revert_NEW_03_requireTimelockFloorRejectsOneHour() public {
        vm.expectRevert(bytes("TIMELOCK_DELAY_SECONDS below 48h floor"));
        harness.checkFloor(1 hours);
    }

    function test_Revert_NEW_03_requireTimelockFloorRejectsJustBelow() public {
        vm.expectRevert(bytes("TIMELOCK_DELAY_SECONDS below 48h floor"));
        harness.checkFloor(48 hours - 1);
    }
}
