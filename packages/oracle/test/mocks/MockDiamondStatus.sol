// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {IMarketFacet} from "@predix/shared/interfaces/IMarketFacet.sol";

/// @notice Minimal `IMarketFacet` stub exposing only `getMarketStatus` with a
///         configurable `endTime`. Used by ManualOracle adapter unit tests so
///         they can exercise the new endTime gate without pulling in the
///         diamond package (monorepo boundary §2).
contract MockDiamondStatus {
    mapping(uint256 => uint256) public endTimeOf;

    function setEndTime(uint256 marketId, uint256 endTime) external {
        endTimeOf[marketId] = endTime;
    }

    function getMarketStatus(uint256 marketId)
        external
        view
        returns (address yesToken, address noToken, uint256 endTime, bool isResolved, bool refundModeActive)
    {
        return (address(0), address(0), endTimeOf[marketId], false, false);
    }
}
