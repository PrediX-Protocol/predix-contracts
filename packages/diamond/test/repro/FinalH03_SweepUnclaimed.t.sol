// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {IMarketFacet} from "@predix/shared/interfaces/IMarketFacet.sol";
import {IOutcomeToken} from "@predix/shared/interfaces/IOutcomeToken.sol";

import {MarketFixture} from "../utils/MarketFixture.sol";

/// @notice Repro for FINAL-H03: `sweepUnclaimed` must not seize collateral
///         that still backs live outcome-token supply. Pre-fix it zeroed
///         `totalCollateral` unconditionally and late redeemers underflow-reverted.
contract FinalH03_SweepUnclaimed is MarketFixture {
    uint256 internal id;
    uint256 internal endTime;

    function setUp() public override {
        super.setUp();
        endTime = block.timestamp + 7 days;
        id = _createMarket(endTime);
    }

    function _resolveYes() internal {
        oracle.setResolution(id, true);
        vm.warp(endTime + 1);
        market.resolveMarket(id);
    }

    /// @dev Alice splits 100, never redeems. After grace period, sweep must
    ///      return 0 and leave `totalCollateral` intact so Alice can still
    ///      redeem afterwards.
    function test_Sweep_ResolvedWithLiveSupply_ReturnsZero() public {
        _split(alice, id, 100e6);
        _resolveYes();

        vm.warp(block.timestamp + 365 days + 1);
        vm.prank(admin);
        uint256 swept = market.sweepUnclaimed(id);
        assertEq(swept, 0, "must not seize live backing");
        assertEq(market.getMarket(id).totalCollateral, 100e6);
        assertEq(usdc.balanceOf(feeRecipient), 0);

        // Alice can still redeem the full amount — no underflow.
        vm.prank(alice);
        uint256 payout = market.redeem(id);
        assertEq(payout, 100e6);
    }

    /// @dev Refund-mode path: FINAL-C01 ensures yes.supply == no.supply, so
    ///      sweep reads either leg. Still must return 0 when everyone is live.
    function test_Sweep_RefundModeWithLiveSupply_ReturnsZero() public {
        _split(alice, id, 100e6);
        vm.warp(endTime + 1);
        vm.prank(admin);
        market.enableRefundMode(id);

        vm.warp(block.timestamp + 365 days + 1);
        vm.prank(admin);
        uint256 swept = market.sweepUnclaimed(id);
        assertEq(swept, 0);
        assertEq(market.getMarket(id).totalCollateral, 100e6);
    }

    /// @dev After the winners have all redeemed, collateral is exactly 0 and
    ///      `no.totalSupply` is ignored (losing leg). Sweep still returns 0
    ///      (nothing to sweep).
    function test_Sweep_AfterAllRedeemed_ReturnsZero() public {
        _split(alice, id, 100e6);
        _resolveYes();

        vm.prank(alice);
        market.redeem(id);

        vm.warp(block.timestamp + 365 days + 1);
        vm.prank(admin);
        uint256 swept = market.sweepUnclaimed(id);
        assertEq(swept, 0);
    }
}
