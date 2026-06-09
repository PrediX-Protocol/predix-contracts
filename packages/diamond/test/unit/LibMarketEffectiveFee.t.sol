// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import {Test} from "forge-std/Test.sol";

import {LibMarket} from "@predix/diamond/libraries/LibMarket.sol";
import {LibMarketStorage} from "@predix/diamond/libraries/LibMarketStorage.sol";

/// @notice keyti-fqn8 ① — read-time cap clamp. `effectiveRedemptionFee` is the single source for resolving
///         a market's fee (override ? perMarket : snapshot) AND must never return above the hard cap, even
///         if a stored value exceeds it (legacy state from before the 1500->1000 cap drop). Tested directly
///         on a struct so the clamp branch needs no on-chain >cap value (the setters forbid writing one).
contract LibMarketEffectiveFeeTest is Test {
    LibMarketStorage.MarketData internal m;

    function test_NoClamp_SnapshotWithinCap() public {
        m.snapshottedDefaultRedemptionFeeBps = 100;
        assertEq(LibMarket.effectiveRedemptionFee(m), 100);
    }

    function test_Clamp_SnapshotAboveCap() public {
        m.snapshottedDefaultRedemptionFeeBps = 1500; // legacy snapshot above the new cap
        assertEq(LibMarket.effectiveRedemptionFee(m), 1000, "snapshot clamped to cap");
    }

    function test_Clamp_OverrideAboveCap() public {
        m.redemptionFeeOverridden = true;
        m.perMarketRedemptionFeeBps = 1200;
        assertEq(LibMarket.effectiveRedemptionFee(m), 1000, "override clamped to cap");
    }

    function test_Override_TakesPrecedence_WithinCap() public {
        m.snapshottedDefaultRedemptionFeeBps = 500;
        m.redemptionFeeOverridden = true;
        m.perMarketRedemptionFeeBps = 200;
        assertEq(LibMarket.effectiveRedemptionFee(m), 200, "override wins, no clamp");
    }

    function testFuzz_NeverAboveCap(uint16 snapshot, uint16 perMarket, bool overridden) public {
        m.snapshottedDefaultRedemptionFeeBps = snapshot;
        m.perMarketRedemptionFeeBps = perMarket;
        m.redemptionFeeOverridden = overridden;
        assertLe(LibMarket.effectiveRedemptionFee(m), 1000, "effective fee never exceeds cap");
    }
}
