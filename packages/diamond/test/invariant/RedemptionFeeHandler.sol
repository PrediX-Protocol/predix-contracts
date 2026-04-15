// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {CommonBase} from "forge-std/Base.sol";
import {StdCheats} from "forge-std/StdCheats.sol";
import {StdUtils} from "forge-std/StdUtils.sol";

import {IMarketFacet} from "@predix/shared/interfaces/IMarketFacet.sol";
import {IOutcomeToken} from "@predix/shared/interfaces/IOutcomeToken.sol";

/// @notice Stateful handler that exercises `redeem` on a resolved market with the
///         protocol redemption fee enabled. Used by `invariant_FeeRecipientBalanceMonotonic`
///         to assert the fee recipient's USDC balance never decreases.
contract RedemptionFeeHandler is CommonBase, StdCheats, StdUtils {
    IMarketFacet internal immutable market;
    uint256 internal immutable marketId;
    address[5] internal users;

    constructor(address _diamond, uint256 _marketId, address[5] memory _users) {
        market = IMarketFacet(_diamond);
        marketId = _marketId;
        users = _users;
    }

    function redeem(uint8 userIdx) external {
        address user = users[userIdx % users.length];
        IMarketFacet.MarketView memory m = market.getMarket(marketId);
        uint256 yesBal = IOutcomeToken(m.yesToken).balanceOf(user);
        uint256 noBal = IOutcomeToken(m.noToken).balanceOf(user);
        if (yesBal + noBal == 0) return;
        vm.prank(user);
        market.redeem(marketId);
    }
}
