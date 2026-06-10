// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import {IEventFacet} from "@predix/shared/interfaces/IEventFacet.sol";
import {IMarketFacet} from "@predix/shared/interfaces/IMarketFacet.sol";
import {IOutcomeToken} from "@predix/shared/interfaces/IOutcomeToken.sol";

import {EventFixture} from "../utils/EventFixture.sol";

/// @title RedemptionFeeFqn8Adversarial
/// @notice Attack sequences + edge regimes the per-function reviews + the fork cut-sim DIDN'T cover for
///         the keyti-fqn8 redemption-fee change. Each test tries to BREAK a money-flow invariant:
///           (3) read-time cap clamp must hold for a LEGACY raw value > cap planted on the LIVE diamond
///               (`vm.store`) — redeem / redeemEvent must charge <= 10% and never revert-DoS;
///           (1/2) cross-function temporal: split -> admin raises/lowers per-child fee -> resolve ->
///               PARTIAL redeems by MULTIPLE holders with MIXED per-child fees -> conservation +
///               pool -> exactly 0;
///           (4) rescueSurplus mid-drain must never seize un-redeemed holders' pooled backing.
/// @dev Storage slot math for the `vm.store` clamp planting is taken from the compiler layout of
///      `LibMarketStorage.MarketData` (verified via `forge inspect Gap1LayoutProbe storage-layout --json`):
///      MarketData base slot = keccak256(abi.encode(marketId, MARKET_SLOT + 1)); slot 12 packs
///      perMarketRedemptionFeeBps(uint16) at byte 0, redemptionFeeOverridden(bool) at byte 2,
///      snapshottedDefaultRedemptionFeeBps(uint16) at byte 3, linkedChild(bool) at byte 5. Same convention as
///      `LegacyEventForge`, cross-checked through the public `effectiveRedemptionFeeBps` view.
contract RedemptionFeeFqn8Adversarial is EventFixture {
    bytes32 internal constant MARKET_SLOT = keccak256("predix.storage.market.v1");
    uint256 internal constant MAX_FEE_BPS = 1000; // 10% hard cap
    uint256 internal constant BPS = 10_000;

    uint256 internal endTime;

    function setUp() public override {
        super.setUp();
        endTime = block.timestamp + 7 days;
    }

    // -----------------------------------------------------------------------
    // helpers
    // -----------------------------------------------------------------------

    function _marketBase(uint256 marketId) internal pure returns (bytes32) {
        return keccak256(abi.encode(marketId, uint256(MARKET_SLOT) + 1));
    }

    /// @dev Plant a raw snapshot fee (uint16) directly into storage, bypassing the setter cap guards, to
    ///      simulate a legacy value written before the 1500->1000 cap drop.
    function _plantSnapshotFee(uint256 marketId, uint16 rawBps) internal {
        bytes32 slot12 = bytes32(uint256(_marketBase(marketId)) + 12);
        uint256 word = uint256(vm.load(address(diamond), slot12));
        // Clear bytes 3-4 (snapshottedDefaultRedemptionFeeBps), then set them.
        word &= ~(uint256(0xFFFF) << (8 * 3));
        word |= uint256(rawBps) << (8 * 3);
        vm.store(address(diamond), slot12, bytes32(word));
    }

    /// @dev Plant a raw override fee (uint16) + the overridden flag directly into storage.
    function _plantOverrideFee(uint256 marketId, uint16 rawBps) internal {
        bytes32 slot12 = bytes32(uint256(_marketBase(marketId)) + 12);
        uint256 word = uint256(vm.load(address(diamond), slot12));
        word &= ~(uint256(0xFFFF)); // clear bytes 0-1 (perMarketRedemptionFeeBps)
        word |= uint256(rawBps);
        word |= uint256(1) << (8 * 2); // set redemptionFeeOverridden @ byte 2
        vm.store(address(diamond), slot12, bytes32(word));
    }

    function _resolveYes(uint256 marketId) internal {
        oracle.setResolution(marketId, true);
        vm.warp(endTime + 1);
        market.resolveMarket(marketId);
    }

    function _mintSet(address user, uint256 eventId, uint256 amount) internal {
        _fundAndApprove(user, amount);
        vm.prank(user);
        eventFacet.splitEvent(eventId, amount);
    }

    function _resolveEventWinner(uint256 eventId, uint256 winIdx) internal {
        vm.warp(endTime + 1);
        eventOracle.setEventResolution(eventId, winIdx);
        eventFacet.resolveEvent(eventId);
    }

    function _setPerMarket(uint256 marketId, uint16 bps) internal {
        vm.prank(admin);
        market.setPerMarketRedemptionFeeBps(marketId, bps);
    }

    // =======================================================================
    // INVARIANT 3 — read-time clamp holds on the LIVE redeem path even for a
    // LEGACY raw value > cap. Existing LibMarketEffectiveFeeTest only hits the
    // bare-struct resolver; this drives the real diamond redeem / redeemEvent.
    // =======================================================================

    /// @dev Plant a legacy snapshot of 1500 bps (15%, above the new 1000 cap) on a standalone binary
    ///      market via vm.store, then redeem. The fee charged MUST clamp to 10%, payout MUST be
    ///      grossClaim - clampedFee, and the call MUST NOT revert (no `grossClaim - fee` underflow DoS).
    function test_Inv3_BinaryRedeem_LegacySnapshotAboveCap_ClampsTo10pct_NoRevert() public {
        uint256 id = _createMarket(endTime); // snapshot 0 (default 0)
        _split(alice, id, 100e6);

        _plantSnapshotFee(id, 1500); // legacy 15% raw
        // View confirms the clamp lands before any money moves.
        assertEq(market.effectiveRedemptionFeeBps(id), MAX_FEE_BPS, "view clamps planted 1500 -> 1000");

        _resolveYes(id);

        uint256 feeBefore = usdc.balanceOf(feeRecipient);
        uint256 aliceBefore = usdc.balanceOf(alice);
        vm.prank(alice);
        uint256 payout = market.redeem(id);

        // Fee charged is 10% of 100, NOT 15%. payout + fee == winningBurned (conservation).
        uint256 fee = usdc.balanceOf(feeRecipient) - feeBefore;
        assertEq(fee, 10e6, "fee clamped to 10% of 100 on live path");
        assertEq(payout, 90e6, "payout = gross - clamped fee");
        assertEq(usdc.balanceOf(alice) - aliceBefore, 90e6, "alice transfer matches payout");
        assertEq(fee + payout, 100e6, "fee + payout == winningBurned");
        assertEq(market.totalCollateralLocked(), 0, "lockstep back to baseline (full gross debited)");
    }

    /// @dev Same as above but with a PER-MARKET OVERRIDE of 5000 bps (50%) planted via vm.store. The
    ///      override branch of the resolver must also clamp on the live redeem path.
    function test_Inv3_BinaryRedeem_LegacyOverrideAboveCap_ClampsTo10pct_NoRevert() public {
        uint256 id = _createMarket(endTime);
        _split(alice, id, 100e6);

        _plantOverrideFee(id, 5000); // absurd 50% override
        assertEq(market.effectiveRedemptionFeeBps(id), MAX_FEE_BPS, "override 5000 clamps to 1000");

        _resolveYes(id);

        uint256 feeBefore = usdc.balanceOf(feeRecipient);
        vm.prank(alice);
        uint256 payout = market.redeem(id);

        assertEq(usdc.balanceOf(feeRecipient) - feeBefore, 10e6, "override clamped to 10%");
        assertEq(payout, 90e6, "payout = gross - clamped override fee");
        assertEq(market.totalCollateralLocked(), 0, "lockstep restored");
    }

    /// @dev Worst case for the underflow-DoS hypothesis: plant the MAX uint16 (65535 bps = 655%) as the
    ///      override. If the clamp were missing, `grossClaim - fee` would underflow and revert, bricking
    ///      every winner's redemption forever. Prove it clamps to 10% and pays out.
    function test_Inv3_BinaryRedeem_MaxUint16Override_NoUnderflowBrick() public {
        uint256 id = _createMarket(endTime);
        _split(alice, id, 100e6);

        _plantOverrideFee(id, type(uint16).max); // 65535 bps
        assertEq(market.effectiveRedemptionFeeBps(id), MAX_FEE_BPS, "uint16 max clamps to cap");

        _resolveYes(id);

        vm.prank(alice);
        uint256 payout = market.redeem(id); // MUST NOT revert
        assertEq(payout, 90e6, "winner still paid 90% despite a 655% legacy fee");
    }

    /// @dev redeemEvent path: plant a legacy snapshot > cap on the WINNING child of a linked event. The
    ///      per-child fee accumulation in the loop reads `effectiveRedemptionFee`, which must clamp; the
    ///      pool must still drain to exactly 0 and `fee + payout == grossClaim`.
    function test_Inv3_RedeemEvent_LegacyChildSnapshotAboveCap_ClampsTo10pct_PoolDrainsToZero() public {
        (uint256 eventId, uint256[] memory ids) = _createThreeCandidateEvent(endTime);
        _mintSet(alice, eventId, 100e6); // pool 100, alice holds YES of each child

        // Plant a legacy 1500 bps snapshot on the child that will win (index 2).
        _plantSnapshotFee(ids[2], 1500);
        assertEq(market.effectiveRedemptionFeeBps(ids[2]), MAX_FEE_BPS, "winning child clamps to cap");

        _resolveEventWinner(eventId, 2);

        uint256 feeBefore = usdc.balanceOf(feeRecipient);
        uint256 aliceBefore = usdc.balanceOf(alice);
        vm.prank(alice);
        uint256 payout = eventFacet.redeemEvent(eventId); // MUST NOT revert (pool >= grossClaim always)

        uint256 fee = usdc.balanceOf(feeRecipient) - feeBefore;
        assertEq(fee, 10e6, "redeemEvent clamps the planted 15% child fee to 10%");
        assertEq(payout, 90e6, "payout = gross 100 - clamped fee 10");
        assertEq(usdc.balanceOf(alice) - aliceBefore, 90e6, "alice transfer matches");
        assertEq(fee + payout, 100e6, "fee + payout == grossClaim");
        assertEq(eventFacet.eventPoolOf(eventId), 0, "pool drains to exactly 0 under a >cap child fee");
        assertEq(market.totalCollateralLocked(), 0, "lockstep restored");
    }

    /// @dev redeemEvent with EVERY child planted at uint16-max raw fee across a winner + losers in one
    ///      claim — the summed clamped fee must never exceed grossClaim (else payout underflows).
    function test_Inv3_RedeemEvent_AllChildrenMaxRaw_AcrossWinnerAndLosers_NoUnderflow() public {
        (uint256 eventId, uint256[] memory ids) = _createThreeCandidateEvent(endTime);
        _mintSet(alice, eventId, 100e6); // YES of every child
        // bob adds NO exposure on losing children via per-child split so alice's claim spans
        // winner-YES + loser-NO when she redeems (she holds NO on the losers too after a split).
        _split(alice, ids[0], 40e6); // alice now also holds NO0 (a loser-NO == payable) + extra YES0
        _split(alice, ids[1], 25e6);

        for (uint256 i; i < ids.length; ++i) {
            _plantSnapshotFee(ids[i], type(uint16).max);
            assertEq(market.effectiveRedemptionFeeBps(ids[i]), MAX_FEE_BPS, "each child clamps to cap");
        }

        _resolveEventWinner(eventId, 2); // child2 wins; alice claims YES2 + NO0 + NO1

        uint256 pool = eventFacet.eventPoolOf(eventId);
        uint256 feeBefore = usdc.balanceOf(feeRecipient);
        uint256 aliceBefore = usdc.balanceOf(alice);
        vm.prank(alice);
        uint256 payout = eventFacet.redeemEvent(eventId); // MUST NOT underflow-revert

        uint256 fee = usdc.balanceOf(feeRecipient) - feeBefore;
        // alice owns the entire pool's claim (sole holder), so grossClaim == pool; fee == 10% of pool.
        assertEq(fee + payout, pool, "fee + payout == grossClaim (== full pool)");
        assertEq(fee, (pool * MAX_FEE_BPS) / BPS, "summed clamped fee == 10% of gross, never more");
        assertEq(usdc.balanceOf(alice) - aliceBefore, payout, "alice transfer matches payout");
        assertEq(eventFacet.eventPoolOf(eventId), 0, "pool drains to 0");
        assertEq(market.totalCollateralLocked(), 0, "lockstep restored");
    }

    // =======================================================================
    // INVARIANT 1/2 — cross-function temporal: split -> raise/lower per-child
    // fee mid-flight -> resolve -> MULTIPLE partial redeemers, MIXED per-child
    // fees -> conservation holds at EVERY step + pool -> exactly 0.
    // =======================================================================

    /// @dev THE sequence per-function reviews miss: a linked event with admin churning a child's fee
    ///      (raise to cap, then lower) BEFORE endTime, then THREE holders redeeming across a winner + two
    ///      losers, each holding mixed per-child positions. After every redeem the pool must equal the
    ///      cash still owed; after the last it must be exactly 0 and the fee recipient must hold exactly
    ///      Σ(per-child floored fee) and not a wei more.
    function test_Inv12_MixedFees_MultiPartialRedeem_ConservesAndDrainsToZero() public {
        _setDefault(0); // children snapshot 0
        (uint256 eventId, uint256[] memory ids) = _createThreeCandidateEvent(endTime);

        // Admin churns child0's fee before endTime: raise to cap, then lower to 900.
        _setPerMarket(ids[0], uint16(MAX_FEE_BPS)); // 10%
        _setPerMarket(ids[0], 900); // 9% (a lower; allowed pre-end)
        _setPerMarket(ids[1], 100); // child1 = 1%
        // child2 stays at snapshot 0%.

        // Three holders build mixed positions.
        _mintSet(alice, eventId, 100e6); // alice: YES of each child (pool 100)
        _split(bob, ids[0], 33_333_333); // bob: YES0 + NO0  (pool += 33.333333)
        _split(carol, ids[1], 17_000_001); // carol: YES1 + NO1 (pool += 17.000001)

        uint256 poolStart = eventFacet.eventPoolOf(eventId);
        assertEq(poolStart, 100e6 + 33_333_333 + 17_000_001, "pool = sum NO + M");

        _resolveEventWinner(eventId, 0); // child0 wins

        // Holdings after resolution (winner = child0):
        //   alice claims YES0(100)@9% + NO1(0)+NO2(0) -> she has only YES of each; YES1/YES2 are
        //   losing-YES (worthless), NO1/NO2 she does NOT hold. So alice claim = YES0 100 @9%.
        //   Actually alice from splitEvent holds YES of EVERY child only -> winner claim = YES0 only.
        //   bob: YES0(33.333333)@9% winner + NO0 is winner's NO (worthless). claim = YES0 33.333333 @9%.
        //   carol: YES1 losing-YES worthless + NO1 is a loser-NO (payable!) @1%. claim = NO1 17.000001 @1%.
        uint256 feeRecip0 = usdc.balanceOf(feeRecipient);

        // ---- alice redeems (partial: only her claim leaves) ----
        uint256 aliceGross = 100e6; // YES0
        uint256 aliceFee = (aliceGross * 900) / BPS;
        uint256 aBefore = usdc.balanceOf(alice);
        vm.prank(alice);
        uint256 aPay = eventFacet.redeemEvent(eventId);
        assertEq(aPay, aliceGross - aliceFee, "alice payout = gross0 - 9%");
        assertEq(usdc.balanceOf(alice) - aBefore, aPay, "alice transfer");
        // Pool must now equal the remaining owed gross (bob's YES0 + carol's NO1).
        assertEq(
            eventFacet.eventPoolOf(eventId),
            poolStart - aliceGross,
            "pool debited by alice FULL gross, equals remaining owed"
        );

        // ---- bob redeems ----
        uint256 bobGross = 33_333_333; // YES0
        uint256 bobFee = (bobGross * 900) / BPS;
        uint256 bBefore = usdc.balanceOf(bob);
        vm.prank(bob);
        uint256 bPay = eventFacet.redeemEvent(eventId);
        assertEq(bPay, bobGross - bobFee, "bob payout = gross - 9%");
        assertEq(usdc.balanceOf(bob) - bBefore, bPay, "bob transfer");

        // ---- carol redeems (loser-NO on child1 @1%) ----
        uint256 carolGross = 17_000_001; // NO1
        uint256 carolFee = (carolGross * 100) / BPS;
        uint256 cBefore = usdc.balanceOf(carol);
        vm.prank(carol);
        uint256 cPay = eventFacet.redeemEvent(eventId);
        assertEq(cPay, carolGross - carolFee, "carol payout = gross - 1%");
        assertEq(usdc.balanceOf(carol) - cBefore, cPay, "carol transfer");

        // ---- Global conservation after all three ----
        uint256 totalFee = usdc.balanceOf(feeRecipient) - feeRecip0;
        assertEq(totalFee, aliceFee + bobFee + carolFee, "fee recipient holds exactly sum of per-child floored fee");
        assertEq(aPay + bPay + cPay + totalFee, poolStart, "sum payout + sum fee == starting pool (no leak/strand)");
        assertEq(eventFacet.eventPoolOf(eventId), 0, "pool drains to EXACTLY 0");
        assertEq(usdc.balanceOf(address(diamond)), 0, "diamond holds zero residual cash");
        assertEq(market.totalCollateralLocked(), 0, "lockstep restored to baseline");
    }

    // =======================================================================
    // INVARIANT 4 — rescueSurplus must NEVER seize un-redeemed holders' pooled
    // backing, even mid-drain after a fee'd partial redeem has left the pool.
    // =======================================================================

    /// @dev After one holder redeems with a fee, the diamond's USDC balance == remaining pool (the fee
    ///      left via transfer; payout left via transfer; the rest is still owed). `rescueSurplus` computes
    ///      `balance - totalCollateralLocked`; since the fee debit decremented the lock by the FULL gross,
    ///      balance must still equal lock, so rescue returns 0 and cannot grab the other holder's backing.
    function test_Inv4_RescueSurplus_MidDrain_AfterFeedRedeem_SeizesNothing() public {
        _setDefault(MAX_FEE_BPS); // 10% so a real fee leaves on the first redeem
        (uint256 eventId, uint256[] memory ids) = _createThreeCandidateEvent(endTime);

        _mintSet(alice, eventId, 100e6); // pool 100
        _split(bob, ids[0], 60e6); // pool 160; bob holds YES0(60) + NO0(60)

        _resolveEventWinner(eventId, 0); // child0 wins

        // alice redeems first (YES0 100 @10%): fee 10 to recipient, payout 90 to alice.
        vm.prank(alice);
        eventFacet.redeemEvent(eventId);

        uint256 poolAfter = eventFacet.eventPoolOf(eventId);
        assertEq(poolAfter, 60e6, "pool = bob's remaining owed gross (YES0 60)");
        // Real cash held == remaining pool == lock (fee debit decremented lock by full gross 100).
        assertEq(usdc.balanceOf(address(diamond)), poolAfter, "diamond cash == remaining pool");
        assertEq(market.totalCollateralLocked(), poolAfter, "lock == remaining pool");

        // rescueSurplus must seize NOTHING — bob's backing is locked, not surplus.
        uint256 feeRecipBefore = usdc.balanceOf(feeRecipient);
        vm.prank(admin);
        uint256 rescued = market.rescueSurplus();
        assertEq(rescued, 0, "rescueSurplus must not seize un-redeemed pooled backing mid-drain");
        assertEq(usdc.balanceOf(feeRecipient), feeRecipBefore, "fee recipient balance unchanged by rescue");

        // bob can still fully redeem his 60 @10% afterwards: pool -> 0, no shortfall.
        uint256 bobBefore = usdc.balanceOf(bob);
        vm.prank(bob);
        uint256 bobPay = eventFacet.redeemEvent(eventId);
        assertEq(bobPay, 54e6, "bob still paid 90% of 60 after the rescue attempt");
        assertEq(usdc.balanceOf(bob) - bobBefore, 54e6, "bob transfer intact");
        assertEq(eventFacet.eventPoolOf(eventId), 0, "pool drains to 0 after both holders");
        assertEq(usdc.balanceOf(address(diamond)), 0, "no residual cash");
    }

    function _setDefault(uint256 bps) internal {
        vm.prank(admin);
        market.setDefaultRedemptionFeeBps(bps);
    }
}
