// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

/// @title LibMarketStorage
/// @notice Diamond storage layout for the market lifecycle facet.
/// @dev Layout is append-only. Never reorder, remove, or change types of existing fields.
library LibMarketStorage {
    bytes32 internal constant SLOT = keccak256("predix.storage.market.v1");

    struct MarketData {
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
        /// @dev Append-only field added in v1.1 to support `EventFacet` mutual-exclusion
        ///      grouping. `0` = standalone binary market; non-zero = child of an event.
        uint256 eventId;
        /// @dev Append-only fields added in v1.3 for per-market redemption fee override.
        ///      When `redemptionFeeOverridden == true`, `perMarketRedemptionFeeBps` is
        ///      used verbatim (including 0); otherwise the default from `LibConfigStorage`
        ///      applies. `uint16` is sufficient because `MAX_REDEMPTION_FEE_BPS = 1500`.
        uint16 perMarketRedemptionFeeBps;
        bool redemptionFeeOverridden;
        /// @dev Append-only field added in v1.4. Snapshot of the global
        ///      `defaultRedemptionFeeBps` taken at market creation. Protects users
        ///      from retroactive admin fee hikes applied after split/resolve. Read
        ///      by `_effectiveRedemptionFee` when no per-market override is set.
        uint16 snapshottedDefaultRedemptionFeeBps;
    }

    struct Layout {
        uint256 marketCount;
        mapping(uint256 => MarketData) markets;
    }

    function layout() internal pure returns (Layout storage l) {
        bytes32 slot = SLOT;
        assembly ("memory-safe") {
            l.slot := slot
        }
    }
}
