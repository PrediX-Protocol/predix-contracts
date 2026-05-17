// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {IPrediXExchange} from "../../src/IPrediXExchange.sol";

import {ExchangeTestBase} from "../base/ExchangeTestBase.sol";

/// @title Audit_E0910_MakerPathSyntheticDust
/// @notice Audit E-NEW-09 + E-NEW-10 (pass-2): pass-1 M-04 added Type-A dust
///         force-clean to the Complementary path but missed the two synthetic
///         paths (MINT for crossed BUYs, MERGE for crossed SELLs). The MINT
///         gap left structural-dust makers in the queue forever; the MERGE
///         gap silently wealth-transferred from maker to taker every time a
///         floored maker share rounded to zero. Both paths now share the
///         same force-clean discipline.
contract Audit_E0910_MakerPathSyntheticDust is ExchangeTestBase {
    uint256 internal constant DUST_PRICE = 10_000; // 1 cent — lowest tick
    uint256 internal constant HIGH_PRICE = 990_000; // 99 cents — complement

    // ============================================================
    // E-NEW-09 — MINT path (taker BUY_YES vs maker BUY_NO)
    // ============================================================

    /// @notice After a maker reaches structural-dust state on the MINT path
    ///         (`remaining * price / 1e6 == 0`), the next placer's MakerPath
    ///         must force-clean it. Without the fix the dust maker rotted in
    ///         queue and every subsequent placer wasted a `MAX_FILLS_PER_PLACE`
    ///         slot revisiting it.
    function test_E09_MintPath_StructuralDustMaker_IsForceClean() public {
        // Alice posts a BUY_NO maker just above MIN_ORDER_AMOUNT so a first
        // taker can leave behind ≤99 wei of dust.
        bytes32 aliceId = _placeBuyNo(alice, DUST_PRICE, 1_000_099);

        // Bob crosses with BUY_YES 1_000_000 → MINT fills 1_000_000, leaves
        // Alice with 99 wei remaining at 1¢, which is structural dust.
        _placeBuyYes(bob, HIGH_PRICE, 1_000_000);

        // Sanity: Alice is filled to 1_000_000 (not yet force-cleaned).
        IPrediXExchange.Order memory aliceMid = exchange.getOrder(aliceId);
        assertEq(aliceMid.filled, 1_000_000, "first taker fills 1M");

        // Carol places another BUY_YES that would otherwise hit Alice's dust.
        // The MakerPath dust check fires first, force-cleans Alice, then
        // settles a clean fill against the next available maker (none here,
        // so Carol's order rests in queue).
        _placeBuyYes(carol, HIGH_PRICE, 1_000_000);

        IPrediXExchange.Order memory aliceAfter = exchange.getOrder(aliceId);
        assertEq(aliceAfter.filled, aliceAfter.amount, "Alice marked fully filled by force-clean");
        assertEq(aliceAfter.depositLocked, 0, "Alice's USDC deposit zeroed by sweep path");
        // Note: no `assertGt(swept, 0)` — Alice's first fill consumed her
        // full USDC deposit by construction, so the post-fill residual is
        // already 0. The force-clean's sweep is a no-op on USDC here; the
        // assertion that matters is that Alice is no longer in the queue.
    }

    // ============================================================
    // E-NEW-10 — MERGE path (taker SELL_YES vs maker SELL_NO)
    // ============================================================

    /// @notice MERGE path dust filter: a maker whose remaining produces zero
    ///         USDC payout is force-cleaned instead of burning tokens for
    ///         nothing. Without the fix, the maker silently transferred
    ///         value to the taker every time the floored share rounded to 0.
    function test_E10_MergePath_StructuralDustMaker_IsForceClean() public {
        // Alice posts SELL_NO at 1¢ just above MIN_ORDER_AMOUNT.
        bytes32 aliceId = _placeSellNo(alice, DUST_PRICE, 1_000_099);

        // Bob crosses with SELL_YES at 99¢, amount 1_000_000 → MERGE settles
        // 1_000_000 cleanly, leaves Alice with 99 wei remaining (dust at 1¢).
        _placeSellYes(bob, HIGH_PRICE, 1_000_000);

        IPrediXExchange.Order memory aliceMid = exchange.getOrder(aliceId);
        assertEq(aliceMid.filled, 1_000_000, "first MERGE leg fills 1M");

        // Snapshot feeRecipient's NO balance — the SELL_NO maker's dust
        // residual is in NO tokens, so the force-clean sweep lands there.
        uint256 feeRecipientNoBefore = IERC20(noToken).balanceOf(feeRecipient);

        // Carol places another SELL_YES that would otherwise burn Alice's
        // 99 NO for 0 USDC. The new MERGE-path dust check fires first.
        _placeSellYes(carol, HIGH_PRICE, 1_000_000);

        IPrediXExchange.Order memory aliceAfter = exchange.getOrder(aliceId);
        assertEq(aliceAfter.filled, aliceAfter.amount, "Alice force-cleaned, not silently merged");
        assertEq(aliceAfter.depositLocked, 0, "Alice's NO residual swept");

        uint256 swept = IERC20(noToken).balanceOf(feeRecipient) - feeRecipientNoBefore;
        assertEq(swept, 99, "feeRecipient receives the 99-wei NO residual");
    }
}
