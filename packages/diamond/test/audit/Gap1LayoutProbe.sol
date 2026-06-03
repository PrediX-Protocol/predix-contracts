// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import {LibMarketStorage} from "@predix/diamond/libraries/LibMarketStorage.sol";
import {LibEventStorage} from "@predix/diamond/libraries/LibEventStorage.sol";

/// @dev Audit-only storage-layout probe (no engine src touched). `forge inspect Gap1LayoutProbe
///      storage-layout` reports compiler-computed (slot, offset) for every field of the LIVE Gap#1
///      structs alongside an inlined copy of the BASELINE (a26467f, pre-Gap#1) structs. Append-only
///      safety holds iff every pre-existing field has identical (slot, offset) in both, and the new
///      Gap#1 fields land in previously-unused slot tail / a fresh slot.
contract Gap1LayoutProbe {
    // LIVE (post-Gap#1) structs — the real libraries.
    LibMarketStorage.MarketData public liveMarket;
    LibEventStorage.EventData public liveEvent;

    // BASELINE (a26467f) — exact pre-Gap#1 field order, inlined verbatim from `git show`.
    struct MarketDataBaseline {
        string question;
        uint256 endTime;
        address oracle;
        address creator;
        address yesToken;
        address noToken;
        uint256 totalCollateral;
        uint256 perMarketCap;
        uint256 resolvedAt;
        uint256 refundEnabledAt;
        bool isResolved;
        bool outcome;
        bool refundModeActive;
        uint256 eventId;
        uint16 perMarketRedemptionFeeBps;
        bool redemptionFeeOverridden;
        uint16 snapshottedDefaultRedemptionFeeBps;
    }

    struct EventDataBaseline {
        string name;
        uint256[] marketIds;
        uint256 endTime;
        address creator;
        uint256 resolvedAt;
        uint256 refundEnabledAt;
        uint256 winningIndex;
        bool isResolved;
        bool refundModeActive;
        address oracle;
    }

    MarketDataBaseline public baseMarket;
    EventDataBaseline public baseEvent;
}
