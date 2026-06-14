// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import {Test} from "forge-std/Test.sol";
import {ExchangeStorage} from "../../src/ExchangeStorage.sol";

/// @dev Concrete shim exposing the pure fee helpers for direct unit testing.
contract FeeHelperHarness is ExchangeStorage {
    function feeOn(uint256 notional, uint16 bps) external pure returns (uint256) {
        return _feeOn(notional, bps);
    }

    function curveFee(uint256 fillShares, uint16 feeCoefBps, uint256 p) external pure returns (uint256) {
        return _curveFee(fillShares, feeCoefBps, p);
    }
}

contract ExchangeFeeHelpersTest is Test {
    FeeHelperHarness internal h;

    function setUp() public {
        h = new FeeHelperHarness();
    }

    function test_feeOn_flatBps() public view {
        // 100 USDC notional * 100bps / 10_000 = 1 USDC
        assertEq(h.feeOn(100e6, 100), 1e6);
        assertEq(h.feeOn(0, 700), 0);
        assertEq(h.feeOn(123_456, 0), 0);
    }

    function test_curveFee_polymarketParity_175_at_50c() public view {
        // 100 shares (1e8), coef 700, p = 500_000 -> $1.75 (1_750_000)
        assertEq(h.curveFee(1e8, 700, 500_000), 1_750_000);
    }

    function test_curveFee_tail_063_at_10c() public view {
        // p = 100_000 (10c): 1e8*700*1e5*9e5/1e16 = 630_000 = $0.63
        assertEq(h.curveFee(1e8, 700, 100_000), 630_000);
    }

    function test_curveFee_symmetric_yesNo() public view {
        // p and 1e6-p give identical fee (curve symmetry about 0.5)
        assertEq(h.curveFee(1e8, 700, 300_000), h.curveFee(1e8, 700, 700_000));
    }

    function test_curveFee_dustFloorsToZero() public view {
        // tiny shares * tiny coef -> floors to 0 (divisor 1e16), no revert
        assertEq(h.curveFee(1, 1, 1), 0);
    }

    function test_curveFee_divisorIs1e16_notE12() public view {
        // regression guard: divisor 1e12 would be 10_000x too large.
        // 1e8*700*5e5*5e5 = 1.75e22; /1e16 = 1.75e6 (correct), /1e12 = 1.75e10 (wrong).
        assertEq(h.curveFee(1e8, 700, 500_000), 1_750_000);
        assertTrue(h.curveFee(1e8, 700, 500_000) < 2e6);
    }
}
