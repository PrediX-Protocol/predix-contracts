// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import {Test} from "forge-std/Test.sol";

import {DeployAll} from "../../script/DeployAll.s.sol";

/// @dev Test harness exposing the internal floor check as external so
///      `vm.expectRevert` can observe its revert.
contract TimelockFloorHarness is DeployAll {
    function checkFloor(uint256 delay, uint256 floor) external pure {
        _requireTimelockFloor(delay, floor);
    }
}

/// @notice DeployAll must reject a timelock delay below the configured floor.
///         Default floor is 48h (production); dev-beta deploys may lower it
///         via `MIN_TIMELOCK_DELAY_SECONDS` env, bounded by an absolute 1h
///         floor that prevents misconfiguration entirely.
contract NEW_03_TimelockFloor is Test {
    TimelockFloorHarness internal harness;

    function setUp() public {
        harness = new TimelockFloorHarness();
    }

    function test_NEW_03_defaultMinTimelockIs48Hours() public view {
        assertEq(harness.DEFAULT_MIN_TIMELOCK_DELAY(), 48 hours, "default floor must be 48h");
        assertEq(harness.ABSOLUTE_MIN_TIMELOCK_DELAY(), 1 hours, "absolute floor must be 1h");
    }

    function test_NEW_03_requireTimelockFloorAccepts48h_WithDefaultFloor() public view {
        harness.checkFloor(48 hours, 48 hours);
        harness.checkFloor(72 hours, 48 hours);
        harness.checkFloor(7 days, 48 hours);
    }

    function test_NEW_03_requireTimelockFloorAcceptsLowDelay_WithLowFloorOverride() public view {
        // Dev-beta posture: override floor to 4h, supply delay = 4h.
        harness.checkFloor(4 hours, 4 hours);
        harness.checkFloor(8 hours, 4 hours);
    }

    function test_Revert_NEW_03_requireTimelockFloorRejectsZero() public {
        vm.expectRevert(bytes("TIMELOCK_DELAY_SECONDS below configured floor"));
        harness.checkFloor(0, 48 hours);
    }

    function test_Revert_NEW_03_requireTimelockFloorRejectsOneHour_WithDefaultFloor() public {
        vm.expectRevert(bytes("TIMELOCK_DELAY_SECONDS below configured floor"));
        harness.checkFloor(1 hours, 48 hours);
    }

    function test_Revert_NEW_03_requireTimelockFloorRejectsJustBelow_WithDefaultFloor() public {
        vm.expectRevert(bytes("TIMELOCK_DELAY_SECONDS below configured floor"));
        harness.checkFloor(48 hours - 1, 48 hours);
    }

    function test_Revert_NEW_03_absoluteFloorRejectsSubHourOverride() public {
        // Operators cannot override the floor below the absolute 1h limit.
        vm.expectRevert(bytes("MIN_TIMELOCK_DELAY_SECONDS below 1h absolute floor"));
        harness.checkFloor(30 minutes, 30 minutes);
    }
}
