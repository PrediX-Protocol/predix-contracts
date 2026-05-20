// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {IMarketFacet} from "@predix/shared/interfaces/IMarketFacet.sol";
import {IOutcomeToken} from "@predix/shared/interfaces/IOutcomeToken.sol";

import {MarketFixture} from "../utils/MarketFixture.sol";

/// @title Audit_PRE_L04_NothingWorthRedeeming
/// @notice Fix-lock for PRE-L04: `redeem` now reverts with
///         `Market_NothingWorthRedeeming` when the caller holds only losing
///         tokens. Without the guard, the unconditional burn of both legs
///         destroyed the user's balance for zero payout — a destructive UX
///         trap rather than an intentional cleanup.
contract Audit_PRE_L04_NothingWorthRedeeming is MarketFixture {
    uint256 internal id;
    uint256 internal endTime;
    uint256 internal constant SPLIT_AMT = 1_000_000e6;

    function setUp() public override {
        super.setUp();
        endTime = block.timestamp + 7 days;
        id = _createMarket(endTime);
    }

    /// @dev Alice splits, transfers away her YES (the winning leg post-resolve),
    ///      and is left holding only NO. Calling `redeem` must revert and
    ///      preserve her NO balance instead of burning it for nothing.
    function test_Redeem_OnlyLosingTokens_Reverts() public {
        _split(alice, id, SPLIT_AMT);

        IOutcomeToken yes = _yes(id);
        IOutcomeToken no = _no(id);

        vm.prank(alice);
        yes.transfer(bob, SPLIT_AMT);

        assertEq(yes.balanceOf(alice), 0, "alice has no YES");
        assertEq(no.balanceOf(alice), SPLIT_AMT, "alice still has NO");

        // Resolve YES — so NO is the losing leg.
        oracle.setResolution(id, true);
        vm.warp(endTime + 1);
        market.resolveMarket(id);

        uint256 aliceUsdcBefore = usdc.balanceOf(alice);

        vm.prank(alice);
        vm.expectRevert(IMarketFacet.Market_NothingWorthRedeeming.selector);
        market.redeem(id);

        // Alice's losing tokens preserved — no silent burn.
        assertEq(no.balanceOf(alice), SPLIT_AMT, "NO preserved on revert");
        // Alice's USDC unchanged — no fee or payout side-effect.
        assertEq(usdc.balanceOf(alice), aliceUsdcBefore, "USDC unchanged");
    }

    /// @dev Same as above but for the YES-loses-to-NO resolution polarity.
    function test_Redeem_OnlyLosingTokens_NoOutcome_Reverts() public {
        _split(alice, id, SPLIT_AMT);

        IOutcomeToken yes = _yes(id);
        IOutcomeToken no = _no(id);

        vm.prank(alice);
        no.transfer(bob, SPLIT_AMT);

        // Resolve NO — so YES is the losing leg.
        oracle.setResolution(id, false);
        vm.warp(endTime + 1);
        market.resolveMarket(id);

        vm.prank(alice);
        vm.expectRevert(IMarketFacet.Market_NothingWorthRedeeming.selector);
        market.redeem(id);

        assertEq(yes.balanceOf(alice), SPLIT_AMT, "YES preserved");
    }

    /// @dev Sanity: holders with winning tokens still redeem normally — the
    ///      fix does not regress the happy path.
    function test_Redeem_WithWinningTokens_StillWorks() public {
        _split(alice, id, SPLIT_AMT);
        oracle.setResolution(id, true);
        vm.warp(endTime + 1);
        market.resolveMarket(id);

        uint256 aliceUsdcBefore = usdc.balanceOf(alice);

        vm.prank(alice);
        uint256 payout = market.redeem(id);

        assertEq(payout, SPLIT_AMT, "full payout on winning leg");
        assertEq(usdc.balanceOf(alice) - aliceUsdcBefore, SPLIT_AMT);
    }

    /// @dev Sanity: holders with mixed YES+NO still redeem the winning side.
    function test_Redeem_MixedHoldings_RedeemsWinningOnly() public {
        _split(alice, id, SPLIT_AMT);
        // Alice now holds SPLIT_AMT of each.
        oracle.setResolution(id, true);
        vm.warp(endTime + 1);
        market.resolveMarket(id);

        vm.prank(alice);
        uint256 payout = market.redeem(id);
        assertEq(payout, SPLIT_AMT, "winning leg paid out");
        assertEq(_yes(id).balanceOf(alice), 0, "YES burnt");
        assertEq(_no(id).balanceOf(alice), 0, "NO burnt");
    }
}
