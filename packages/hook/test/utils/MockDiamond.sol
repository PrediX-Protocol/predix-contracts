// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {IMarketFacet} from "@predix/shared/interfaces/IMarketFacet.sol";

/// @title MockDiamond
/// @notice Minimal `IMarketFacet.getMarket` stub for hook unit tests. Tests `setMarket`
///         the state they need; everything else on `IMarketFacet` reverts.
contract MockDiamond {
    mapping(uint256 marketId => IMarketFacet.MarketView view_) private _markets;

    function setMarket(
        uint256 marketId,
        address yesToken,
        address noToken,
        uint256 endTime,
        bool isResolved,
        bool refundModeActive
    ) external {
        _markets[marketId] = IMarketFacet.MarketView({
            question: "",
            endTime: endTime,
            oracle: address(0),
            creator: address(0),
            yesToken: yesToken,
            noToken: noToken,
            totalCollateral: 0,
            perMarketCap: 0,
            resolvedAt: 0,
            isResolved: isResolved,
            outcome: false,
            refundModeActive: refundModeActive,
            eventId: 0,
            perMarketRedemptionFeeBps: 0,
            redemptionFeeOverridden: false
        });
    }

    function clearMarket(uint256 marketId) external {
        delete _markets[marketId];
    }

    function getMarket(uint256 marketId) external view returns (IMarketFacet.MarketView memory) {
        return _markets[marketId];
    }
}
