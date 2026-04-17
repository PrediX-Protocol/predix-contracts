// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {IMarketFacet} from "@predix/shared/interfaces/IMarketFacet.sol";

/// @notice Minimal `IMarketFacet.getMarket` stub for oracle adapter tests that
///         need diamond binding (NEW-02). Markets default to empty/unknown;
///         tests call `setMarket(marketId, true)` to mark a marketId as
///         known so the oracle's diamond binding check passes.
contract MockDiamondMarket {
    mapping(uint256 marketId => IMarketFacet.MarketView view_) private _markets;

    function setMarket(uint256 marketId, bool known) external {
        _markets[marketId] = IMarketFacet.MarketView({
            question: "",
            endTime: block.timestamp + 365 days,
            oracle: address(0),
            creator: address(this),
            yesToken: known ? address(uint160(0x1000 + marketId)) : address(0),
            noToken: known ? address(uint160(0x2000 + marketId)) : address(0),
            totalCollateral: 0,
            perMarketCap: 0,
            resolvedAt: 0,
            isResolved: false,
            outcome: false,
            refundModeActive: false,
            eventId: 0,
            perMarketRedemptionFeeBps: 0,
            redemptionFeeOverridden: false
        });
    }

    /// @dev Overload for tests that need to control `endTime` explicitly —
    ///      e.g. NEW-02 snapshot-after-endTime boundary checks.
    function setMarketWithEndTime(uint256 marketId, bool known, uint256 endTime) external {
        _markets[marketId] = IMarketFacet.MarketView({
            question: "",
            endTime: endTime,
            oracle: address(0),
            creator: address(this),
            yesToken: known ? address(uint160(0x1000 + marketId)) : address(0),
            noToken: known ? address(uint160(0x2000 + marketId)) : address(0),
            totalCollateral: 0,
            perMarketCap: 0,
            resolvedAt: 0,
            isResolved: false,
            outcome: false,
            refundModeActive: false,
            eventId: 0,
            perMarketRedemptionFeeBps: 0,
            redemptionFeeOverridden: false
        });
    }

    function getMarket(uint256 marketId) external view returns (IMarketFacet.MarketView memory) {
        return _markets[marketId];
    }
}
