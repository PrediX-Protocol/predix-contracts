// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import {Test} from "forge-std/Test.sol";

import {LibMarket} from "@predix/diamond/libraries/LibMarket.sol";
import {LibMarketStorage} from "@predix/diamond/libraries/LibMarketStorage.sol";

/// @notice Protocol-fee read-time resolver. `effectiveProtocolFee` is the single source for resolving
///         a market's protocol-fee rate (override ? perMarket : snapshot) AND must never return above the
///         hard cap (MAX_PROTOCOL_FEE_RATE_BPS = 700), even if a stored value exceeds it. Mirrors
///         `LibMarketEffectiveFee.t.sol`. Tested directly on a struct so the clamp branch needs no on-chain
///         >cap value (the setters forbid writing one).
contract LibMarketEffectiveProtocolFeeTest is Test {
    LibMarketStorage.MarketData internal m;

    function test_NoClamp_SnapshotWithinCap() public {
        m.snapshottedProtocolFeeRateBps = 100;
        assertEq(LibMarket.effectiveProtocolFee(m), 100);
    }

    function test_Clamp_SnapshotAboveCap() public {
        m.snapshottedProtocolFeeRateBps = 1500; // legacy/impossible snapshot above the cap
        assertEq(LibMarket.effectiveProtocolFee(m), 700, "snapshot clamped to cap");
    }

    function test_Clamp_OverrideAboveCap() public {
        m.protocolFeeOverridden = true;
        m.protocolFeeRateBps = 1200;
        assertEq(LibMarket.effectiveProtocolFee(m), 700, "override clamped to cap");
    }

    function test_Override_TakesPrecedence_WithinCap() public {
        m.snapshottedProtocolFeeRateBps = 500;
        m.protocolFeeOverridden = true;
        m.protocolFeeRateBps = 200;
        assertEq(LibMarket.effectiveProtocolFee(m), 200, "override wins, no clamp");
    }

    function test_Override_ExplicitZero_WinsOverNonZeroSnapshot() public {
        m.snapshottedProtocolFeeRateBps = 500;
        m.protocolFeeOverridden = true;
        m.protocolFeeRateBps = 0;
        assertEq(LibMarket.effectiveProtocolFee(m), 0, "explicit-0 override wins");
    }

    function testFuzz_NeverAboveCap(uint16 snapshot, uint16 perMarket, bool overridden) public {
        m.snapshottedProtocolFeeRateBps = snapshot;
        m.protocolFeeRateBps = perMarket;
        m.protocolFeeOverridden = overridden;
        assertLe(LibMarket.effectiveProtocolFee(m), 700, "effective protocol fee never exceeds cap");
    }
}
