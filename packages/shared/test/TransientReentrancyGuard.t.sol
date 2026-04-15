// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";

import {TransientReentrancyGuard} from "@predix/shared/utils/TransientReentrancyGuard.sol";

contract Reentrant is TransientReentrancyGuard {
    uint256 public counter;

    function safeIncrement() external nonReentrant {
        counter += 1;
    }

    function reenter() external nonReentrant {
        this.safeIncrement();
    }

    function nestedAfterReturn() external {
        this.safeIncrement();
        this.safeIncrement();
    }
}

contract TransientReentrancyGuardTest is Test {
    Reentrant internal r;

    function setUp() public {
        r = new Reentrant();
    }

    function test_NonReentrant_AllowsSequentialCalls() public {
        r.safeIncrement();
        r.safeIncrement();
        assertEq(r.counter(), 2);
    }

    function test_NonReentrant_AllowsTwoNonNestedCallsWithinOuter() public {
        r.nestedAfterReturn();
        assertEq(r.counter(), 2);
    }

    function test_Revert_NonReentrant_BlocksNestedCall() public {
        vm.expectRevert(TransientReentrancyGuard.ReentrantCall.selector);
        r.reenter();
    }
}
