// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import {IPrediXExchange} from "../../src/IPrediXExchange.sol";

import {ExchangeTestBase} from "../base/ExchangeTestBase.sol";

/// @notice Pins the scoped-approval hardening: the exchange grants the diamond
///         only an EXACT, single-use USDC allowance per synthetic-MINT
///         `splitPosition` (consumed straight back to zero by the split) instead
///         of a standing max allowance. This removes the cross-trust-domain
///         blast radius where a malicious diamond upgrade could drain idle CLOB
///         deposits via a dormant allowance. `MockDiamond.splitPosition` performs
///         a real `transferFrom(exchange, ...)`, so a MINT only settles if the
///         per-call approval is correct.
contract MintScopedApprovalTest is ExchangeTestBase {
    function _diamondAllowance() internal view returns (uint256) {
        return usdc.allowance(address(exchange), address(diamond));
    }

    function test_NoStandingAllowanceAfterInit() public view {
        assertEq(_diamondAllowance(), 0, "no standing allowance at init");
    }

    /// @dev Maker-path MINT: BUY_YES placer vs resting BUY_NO maker at prices
    ///      summing to >= $1.00 routes through `_executeMintFill` → split.
    function test_MakerPathMint_LeavesZeroAllowance() public {
        _placeBuyNo(bob, 600_000, 10 * ONE_SHARE); // resting BUY_NO @ $0.60
        _placeBuyYes(alice, 600_000, 10 * ONE_SHARE); // BUY_YES @ $0.60 → MINT

        assertEq(_yesBalance(alice), 10 * ONE_SHARE, "alice received YES via MINT");
        assertEq(_noBalance(bob), 10 * ONE_SHARE, "bob received NO via MINT");
        assertEq(_diamondAllowance(), 0, "no residual allowance after maker-path MINT");
    }

    /// @dev Taker-path MINT: BUY_YES `fillMarketOrder` vs resting BUY_NO maker
    ///      routes through `_executeSyntheticTakerFill` → split. Effective
    ///      synthetic price is $0.40 (= 1 - 0.60).
    function test_TakerPathMint_LeavesZeroAllowance() public {
        _placeBuyNo(bob, 600_000, 10 * ONE_SHARE); // resting BUY_NO @ $0.60
        _giveUsdc(alice, 4 * ONE_SHARE); // 4 USDC funds 10 YES at $0.40

        vm.prank(alice);
        (uint256 filled, uint256 cost) = exchange.fillMarketOrder(
            MARKET_ID, IPrediXExchange.Side.BUY_YES, 500_000, 4 * ONE_SHARE, alice, alice, 10, _deadline(), bytes32(0)
        );

        assertEq(filled, 10 * ONE_SHARE, "taker received YES via synthetic MINT");
        assertEq(cost, 4 * ONE_SHARE, "taker spent exactly the synthetic cost");
        assertEq(_diamondAllowance(), 0, "no residual allowance after taker-path MINT");
    }
}
