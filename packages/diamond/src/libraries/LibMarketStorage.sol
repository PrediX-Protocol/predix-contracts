// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

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
        /// @dev Append-only field added in v1.6 for Gap#1 (shared-collateral linked events). `true` =
        ///      this market is a child of a LINKED event: its collateral lives in
        ///      `LibEventStorage.eventPool[eventId]`, not in `totalCollateral` (which stays 0). Read by
        ///      `MarketFacet` to route split/merge to the pool and to reject per-child
        ///      redeem/refund/sweep. `false` for standalone markets and legacy per-child event children.
        bool linkedChild;
    }

    struct Layout {
        uint256 marketCount;
        mapping(uint256 => MarketData) markets;
        /// @dev Append-only field added in v1.5. Running sum of every market's
        ///      `totalCollateral`, maintained in lockstep with split / merge /
        ///      redeem / refund / sweep. Lets `rescueSurplus` recover only
        ///      collateral sent to the diamond OUTSIDE the split flow
        ///      (`balanceOf(diamond) - totalCollateralLocked`) without ever
        ///      touching backing for live outcome-token supply. Also doubles as a
        ///      protocol-wide solvency reference (`balance >= totalCollateralLocked`).
        uint256 totalCollateralLocked;
    }

    function layout() internal pure returns (Layout storage l) {
        bytes32 slot = SLOT;
        assembly ("memory-safe") {
            l.slot := slot
        }
    }
}
