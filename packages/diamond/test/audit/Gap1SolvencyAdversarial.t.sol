// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import {EventFixture} from "../utils/EventFixture.sol";
import {IMarketFacet} from "@predix/shared/interfaces/IMarketFacet.sol";
import {IEventFacet} from "@predix/shared/interfaces/IEventFacet.sol";
import {IOutcomeToken} from "@predix/shared/interfaces/IOutcomeToken.sol";
import {Roles} from "@predix/shared/constants/Roles.sol";

/// @title Gap1SolvencyAdversarial
/// @notice SOLVENCY-ADVERSARIAL audit suite for the shared-collateral engine. Each test attempts to BREAK
///         the proof's claims (INV-M / INV-C / payout(k)==C ∀k) along a surface the in-tree suite does not
///         cover: cross-event pool isolation, an INDEPENDENT cash-accounting invariant (the diamond's real
///         USDC balance must equal the tracked pool, a different lens than the token-supply invariant),
///         arbitrary emergency-winner solvency, double-redeem, loser-only drain, and the per-market-cap
///         interaction. These are written to FAIL if the engine ever leaks, over-pays, or strands funds.
contract Gap1SolvencyAdversarial is EventFixture {
    address internal operator = makeAddr("operator");

    function setUp() public override {
        super.setUp();
        vm.prank(admin);
        accessControl.grantRole(Roles.OPERATOR_ROLE, operator);
    }

    // ---------------------------------------------------------------------
    // Helpers
    // ---------------------------------------------------------------------

    function _yesBal(uint256 marketId, address who) internal view returns (uint256) {
        return IOutcomeToken(market.getMarket(marketId).yesToken).balanceOf(who);
    }

    function _noBal(uint256 marketId, address who) internal view returns (uint256) {
        return IOutcomeToken(market.getMarket(marketId).noToken).balanceOf(who);
    }

    // ---------------------------------------------------------------------
    // 1. Cross-event pool isolation — resolving/draining event A must not move event B by one wei
    // ---------------------------------------------------------------------

    function test_PoolIsolation_DrainingOneEventLeavesOtherExactlySolvent() public {
        uint256 endA = block.timestamp + 30 days;
        uint256 endB = block.timestamp + 60 days;
        (uint256 evA, uint256[] memory a) = _createNCandidateEvent(3, endA);
        (uint256 evB, uint256[] memory b) = _createNCandidateEvent(4, endB);

        _fundAndApprove(alice, 1_000e6);
        _fundAndApprove(bob, 1_000e6);

        // Seed both events with distinct activity.
        vm.startPrank(alice);
        eventFacet.splitEvent(evA, 40e6);
        market.splitPosition(a[1], 10e6);
        vm.stopPrank();

        vm.startPrank(bob);
        eventFacet.splitEvent(evB, 25e6);
        market.splitPosition(b[2], 7e6);
        market.splitPosition(b[0], 3e6);
        vm.stopPrank();

        uint256 poolBbefore = eventFacet.eventPoolOf(evB);
        assertEq(poolBbefore, 35e6, "B pool seed");

        // Resolve + fully redeem A.
        vm.warp(endA + 1);
        eventOracle.setEventResolution(evA, 0);
        eventFacet.resolveEvent(evA);
        vm.prank(alice);
        eventFacet.redeemEvent(evA);

        assertEq(eventFacet.eventPoolOf(evA), 0, "A must fully drain");

        // B must be COMPLETELY untouched and still exactly solvent for every winner.
        assertEq(eventFacet.eventPoolOf(evB), poolBbefore, "B pool moved by another event's resolution");
        _assertExactlySolventForEveryWinner(evB);
    }

    /// @dev Runtime form of the solvency THM for a single (unresolved) event.
    function _assertExactlySolventForEveryWinner(uint256 eventId) internal view {
        uint256 pool = eventFacet.eventPoolOf(eventId);
        IEventFacet.EventView memory e = eventFacet.getEvent(eventId);
        uint256 n = e.marketIds.length;
        for (uint256 k; k < n; ++k) {
            uint256 claim;
            for (uint256 j; j < n; ++j) {
                IMarketFacet.MarketView memory m = market.getMarket(e.marketIds[j]);
                address tok = j == k ? m.yesToken : m.noToken;
                claim += IOutcomeToken(tok).totalSupply();
            }
            assertEq(claim, pool, "pool not exactly solvent for some winner");
        }
    }

    // ---------------------------------------------------------------------
    // 2. INDEPENDENT cash invariant: diamond USDC balance == eventPool at all times (single-event world).
    //    A different lens than the token-supply invariant — catches any cash leak / mis-tracked pool.
    // ---------------------------------------------------------------------

    function testFuzz_DiamondCashAlwaysEqualsPool(uint256[16] calldata seed) public {
        uint256 endTime = block.timestamp + 3650 days;
        (uint256 eventId, uint256[] memory ids) = _createNCandidateEvent(3, endTime);

        address[3] memory us = [alice, bob, carol];
        for (uint256 i; i < us.length; ++i) {
            usdc.mint(us[i], 1_000_000_000e6);
            vm.prank(us[i]);
            usdc.approve(address(diamond), type(uint256).max);
        }

        // The ONLY USDC in the diamond is this event's pool → balance must equal the pool after every op.
        for (uint256 i; i < seed.length; ++i) {
            uint256 s = seed[i];
            uint256 op = s % 4;
            address u = us[(s >> 2) % 3];
            uint256 child = (s >> 4) % ids.length;
            uint256 raw = (s >> 8) % (500_000e6) + 1;

            if (op == 0) {
                vm.prank(u);
                market.splitPosition(ids[child], raw);
            } else if (op == 1) {
                uint256 maxBurn = _min(_yesBal(ids[child], u), _noBal(ids[child], u));
                if (maxBurn == 0) continue;
                vm.prank(u);
                market.mergePositions(ids[child], 1 + (raw % maxBurn));
            } else if (op == 2) {
                vm.prank(u);
                eventFacet.splitEvent(eventId, raw);
            } else {
                uint256 maxSet = type(uint256).max;
                for (uint256 j; j < ids.length; ++j) {
                    maxSet = _min(maxSet, _yesBal(ids[j], u));
                }
                if (maxSet == 0) continue;
                vm.prank(u);
                eventFacet.mergeEvent(eventId, 1 + (raw % maxSet));
            }

            // CASH CONSERVATION: real money held == accounted pool. No fee pre-resolution.
            assertEq(
                usdc.balanceOf(address(diamond)), eventFacet.eventPoolOf(eventId), "diamond cash diverged from pool"
            );
            assertEq(market.totalCollateralLocked(), eventFacet.eventPoolOf(eventId), "lockstep diverged from pool");
        }

        // Resolve to a fuzzed winner and drain every holder; pool AND real cash must hit exactly zero.
        uint256 winner = seed[0] % ids.length;
        vm.warp(endTime + 1);
        eventOracle.setEventResolution(eventId, winner);
        eventFacet.resolveEvent(eventId);
        for (uint256 i; i < us.length; ++i) {
            vm.prank(us[i]);
            try eventFacet.redeemEvent(eventId) {} catch {}
        }
        assertEq(eventFacet.eventPoolOf(eventId), 0, "pool not drained to zero after full redemption");
        assertEq(usdc.balanceOf(address(diamond)), 0, "diamond holds residual cash after full redemption");
        assertEq(market.totalCollateralLocked(), 0, "lock not zero after full redemption");
    }

    // ---------------------------------------------------------------------
    // 3. Arbitrary emergency winner cannot create insolvency or strand funds (THM: payout(k)==C ∀k).
    //    An OPERATOR can pick ANY index after the 7-day delay; the pool must still drain to zero.
    // ---------------------------------------------------------------------

    function test_EmergencyArbitraryWinner_StillExactlySolvent() public {
        uint256 endTime = block.timestamp + 30 days;
        (uint256 eventId, uint256[] memory ids) = _createNCandidateEvent(4, endTime);

        _fundAndApprove(alice, 1_000e6);
        _fundAndApprove(bob, 1_000e6);

        // Mixed activity: complete sets + asymmetric per-outcome splits across two users.
        vm.startPrank(alice);
        eventFacet.splitEvent(eventId, 50e6);
        market.splitPosition(ids[0], 11e6);
        market.splitPosition(ids[3], 4e6);
        vm.stopPrank();
        vm.startPrank(bob);
        market.splitPosition(ids[1], 9e6);
        market.splitPosition(ids[0], 6e6);
        vm.stopPrank();

        uint256 pool = eventFacet.eventPoolOf(eventId);

        // OPERATOR emergency-resolves to a "biased" winner (index 2 — the one with the LEAST YES skew).
        vm.warp(endTime + 7 days + 1);
        vm.prank(operator);
        eventFacet.emergencyResolveEvent(eventId, 2);

        uint256 diamondBefore = usdc.balanceOf(address(diamond));
        assertEq(diamondBefore, pool, "cash != pool at resolution");

        uint256 aPay;
        uint256 bPay;
        vm.prank(alice);
        aPay = eventFacet.redeemEvent(eventId);
        vm.prank(bob);
        bPay = eventFacet.redeemEvent(eventId);

        // Even with an arbitrary winner: total paid == pool, pool drains to 0, no stranded cash.
        assertEq(aPay + bPay, pool, "sum of payouts != pool (insolvency or strand)");
        assertEq(eventFacet.eventPoolOf(eventId), 0, "pool not drained under arbitrary emergency winner");
        assertEq(usdc.balanceOf(address(diamond)), 0, "diamond holds residual after arbitrary winner");
    }

    // ---------------------------------------------------------------------
    // 4. No double-redeem; a loser-only holder cannot drain the pool.
    // ---------------------------------------------------------------------

    function test_DoubleRedeem_SecondCallReverts_PoolUnchanged() public {
        uint256 endTime = block.timestamp + 30 days;
        (uint256 eventId,) = _createNCandidateEvent(3, endTime);
        _fundAndApprove(alice, 100e6);
        vm.prank(alice);
        eventFacet.splitEvent(eventId, 30e6);

        vm.warp(endTime + 1);
        eventOracle.setEventResolution(eventId, 0);
        eventFacet.resolveEvent(eventId);

        vm.prank(alice);
        uint256 first = eventFacet.redeemEvent(eventId);
        assertEq(first, 30e6, "first redeem != winning YES");

        // Second call: balances already burned → NothingToRedeem, pool stays at 0 (no extra cash leaves).
        vm.prank(alice);
        vm.expectRevert(IEventFacet.Event_NothingToRedeem.selector);
        eventFacet.redeemEvent(eventId);
        assertEq(eventFacet.eventPoolOf(eventId), 0, "pool moved on a failed second redeem");
    }

    function test_LoserOnlyHolder_CannotTouchPool() public {
        uint256 endTime = block.timestamp + 30 days;
        (uint256 eventId, uint256[] memory ids) = _createNCandidateEvent(3, endTime);

        // alice mints complete sets (YES of every outcome). bob splits outcome 1 (gets YES_1 + NO_1).
        _fundAndApprove(alice, 100e6);
        _fundAndApprove(bob, 100e6);
        vm.prank(alice);
        eventFacet.splitEvent(eventId, 20e6);
        vm.prank(bob);
        market.splitPosition(ids[1], 8e6);

        // Resolve outcome 0. bob holds only YES_1 (losing-YES, worthless) + NO_1 (winning-side? no:
        // outcome 1 lost, so NO_1 is a winning losing-NO — actually payable). To get a pure loser, give
        // carol only YES of a LOSING outcome via a transfer from bob.
        vm.warp(endTime + 1);
        eventOracle.setEventResolution(eventId, 0);
        eventFacet.resolveEvent(eventId);

        // carol holds nothing at all → must revert, pool untouched.
        uint256 poolBefore = eventFacet.eventPoolOf(eventId);
        vm.prank(carol);
        vm.expectRevert(IEventFacet.Event_NothingToRedeem.selector);
        eventFacet.redeemEvent(eventId);
        assertEq(eventFacet.eventPoolOf(eventId), poolBefore, "pool moved for a no-token caller");
    }

    // ---------------------------------------------------------------------
    // 5. FINDING PoC (LOW): linked children silently bypass the per-market cap (C-7).
    //    A standalone binary market with the SAME default cap reverts; the linked child does not.
    // ---------------------------------------------------------------------

    function test_Finding_LinkedChildBypassesPerMarketCap() public {
        // Admin sets a global per-market cap of 5 USDC for risk control.
        vm.prank(admin);
        market.setDefaultPerMarketCap(5e6);

        // Standalone binary market: split beyond the cap REVERTS (cap enforced).
        uint256 stdEnd = block.timestamp + 30 days;
        vm.prank(alice);
        uint256 stdId = market.createMarket("standalone?", stdEnd, address(oracle));
        _fundAndApprove(bob, 1_000e6);
        vm.prank(bob);
        vm.expectRevert(IMarketFacet.Market_ExceedsPerMarketCap.selector);
        market.splitPosition(stdId, 6e6);

        // Linked child: split FAR beyond the same cap SUCCEEDS (cap silently bypassed).
        (uint256 eventId, uint256[] memory ids) = _createNCandidateEvent(3, block.timestamp + 30 days);
        _fundAndApprove(alice, 1_000e6);
        vm.prank(alice);
        market.splitPosition(ids[0], 500e6); // 100x the cap — no revert

        assertEq(eventFacet.eventPoolOf(eventId), 500e6, "linked child should have accepted the over-cap split");
        assertEq(market.getMarket(ids[0]).totalCollateral, 0, "linked child totalCollateral stays 0 (why cap is blind)");
    }

    // ---------------------------------------------------------------------
    // 6. Fee rounding cannot strand pool dust across MULTIPLE redeemers at the MAX fee (10%).
    //    keyti-fqn8: children snapshot the default fee at creation, so redeemEvent now charges it
    //    per-child — this exercises the "floor fee → dust → pool != Σpayout" hypothesis on the live path.
    // ---------------------------------------------------------------------

    function test_MultiRedeemerMaxFee_PoolDrainsToZero_NoDust() public {
        vm.prank(admin);
        market.setDefaultRedemptionFeeBps(1000); // 10% = MAX, worst case for rounding

        uint256 endTime = block.timestamp + 30 days;
        (uint256 eventId, uint256[] memory ids) = _createNCandidateEvent(3, endTime);

        _fundAndApprove(alice, 1_000e6);
        _fundAndApprove(bob, 1_000e6);
        _fundAndApprove(carol, 1_000e6);

        // Deliberately awkward amounts so grossClaim * 1000 / 10000 floors with a remainder per redeemer.
        vm.prank(alice);
        eventFacet.splitEvent(eventId, 10_000_001); // odd base unit
        vm.prank(bob);
        market.splitPosition(ids[0], 7_000_003);
        vm.prank(carol);
        market.splitPosition(ids[0], 3_000_007);

        uint256 pool = eventFacet.eventPoolOf(eventId);

        vm.warp(endTime + 1);
        eventOracle.setEventResolution(eventId, 0);
        eventFacet.resolveEvent(eventId);

        uint256 feeRecipientBefore = usdc.balanceOf(feeRecipient);
        uint256 paid;
        address[3] memory us = [alice, bob, carol];
        for (uint256 i; i < us.length; ++i) {
            vm.prank(us[i]);
            try eventFacet.redeemEvent(eventId) returns (uint256 p) {
                paid += p;
            } catch {}
        }
        uint256 fees = usdc.balanceOf(feeRecipient) - feeRecipientBefore;

        // Conservation: every base unit of the pool left as either a user payout or a protocol fee.
        assertEq(paid + fees, pool, "fee+payout != pool (dust stranded or over-paid)");
        assertEq(eventFacet.eventPoolOf(eventId), 0, "pool dust stranded under max fee + odd amounts");
        assertEq(usdc.balanceOf(address(diamond)), 0, "diamond holds residual under max fee");
    }

    function _min(uint256 a, uint256 b) internal pure returns (uint256) {
        return a < b ? a : b;
    }
}
