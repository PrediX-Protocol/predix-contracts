// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Vm} from "forge-std/Vm.sol";

import {IPrediXExchange} from "../../src/IPrediXExchange.sol";

import {ExchangeTestBase} from "../base/ExchangeTestBase.sol";

/// @notice Repro for BACKLOG 2026-04-21: taker in the MERGE path receives
///         price improvement (`fillAmt - makerPayout`) instead of its own
///         limit; maker keeps its limit; surplus is 0 by construction so the
///         MERGE path does not emit `FeeCollected`.
///
///         Pre-fix on-chain evidence (Unichain Sepolia):
///           tx 0xe671607491cdd5cf10532d4bbfc8c6d7f68a2a567d687b20a3d0239d65bc194a
///         User SELL_NO @ 0.01 crossed a SELL_YES @ 0.77 maker. Merge proceeds
///         were $1.00; maker received $0.77 (its limit), taker received $0.01
///         (its limit — the bug), and $0.22 was credited to the protocol as a
///         FeeCollected event. Every industry CLOB (Polymarket, Kalshi,
///         Binance, dYdX) routes price improvement to the taker. The X1 fix
///         adopts that convention.
contract Backlog_MergeImprovement is ExchangeTestBase {
    function test_Backlog_MergeFill_TakerGetsImprovement() public {
        // Exact reproduction of the 0xe67160… scenario scaled to 1 share.
        // Maker SELL_YES @ 0.77, taker SELL_NO @ 0.01. `_tryMerge` picks
        // this pair because takerPrice (0.01) + makerPrice (0.77) ≤ 1.00.
        uint256 amount = 1 * ONE_SHARE;

        _placeSellYes(alice, 770_000, amount);
        _giveYesNo(bob, amount);

        uint256 feeRecipientBefore = _usdcBalance(feeRecipient);

        vm.recordLogs();
        vm.prank(bob);
        exchange.placeOrder(MARKET_ID, IPrediXExchange.Side.SELL_NO, 10_000, amount);

        // Maker keeps its limit; taker gets the complement (0.23 USDC per share).
        assertEq(_usdcBalance(alice), 770_000 * amount / 1e6, "maker keeps 0.77 limit");
        assertEq(_usdcBalance(bob), 230_000 * amount / 1e6, "taker gets complement 0.23, not 0.01");
        assertEq(_usdcBalance(feeRecipient), feeRecipientBefore, "no surplus collected in MERGE");

        // No FeeCollected event should have fired from the MERGE path.
        bytes32 feeTopic = keccak256("FeeCollected(uint256,uint256)");
        Vm.Log[] memory logs = vm.getRecordedLogs();
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter == address(exchange) && logs[i].topics.length > 0 && logs[i].topics[0] == feeTopic) {
                fail("MERGE path must not emit FeeCollected");
            }
        }
    }

    function test_Backlog_MergeFill_TakerLimitExactMatch() public {
        // Edge case: taker limit equals the complement of maker price, i.e.
        // there is no improvement. The fix must still fill cleanly (taker
        // limit == takerPayout, maker keeps its limit, no surplus).
        uint256 amount = 10 * ONE_SHARE;

        _placeSellYes(alice, 600_000, amount); // maker 0.60 → complement 0.40
        _giveYesNo(bob, amount);

        vm.prank(bob);
        exchange.placeOrder(MARKET_ID, IPrediXExchange.Side.SELL_NO, 400_000, amount);

        assertEq(_usdcBalance(alice), 6 * ONE_SHARE, "maker gets 0.60 * 10 = 6");
        assertEq(_usdcBalance(bob), 4 * ONE_SHARE, "taker gets 0.40 * 10 = 4 (no improvement)");
        assertEq(_usdcBalance(feeRecipient), 0, "no surplus at exact match");
    }

    function test_Backlog_MergeFill_SolvencyInvariant(uint16 takerBpsRaw, uint16 makerBpsRaw, uint64 sharesRaw) public {
        // Fuzz the invariant directly: across any valid (takerPrice,
        // makerPrice, fillAmt) triple, `takerPayout + makerPayout ==
        // fillAmt`, so the MERGE path never leaves dust or overspends.
        // Bound inputs to the valid price domain `[1, 999] ×
        // [1, 999 - takerBps]` (bps of a $1 share, tick = 10_000).
        uint256 takerBps = bound(uint256(takerBpsRaw), 1, 98);
        uint256 makerBps = bound(uint256(makerBpsRaw), 1, 99 - takerBps);
        uint256 shares = bound(uint256(sharesRaw), 1, 1_000);

        uint256 takerPrice = takerBps * 10_000; // matches PRICE_TICK
        uint256 makerPrice = makerBps * 10_000;
        uint256 amount = shares * ONE_SHARE;

        _placeSellYes(alice, makerPrice, amount);
        _giveYesNo(bob, amount);

        uint256 aliceBefore = _usdcBalance(alice);
        uint256 bobBefore = _usdcBalance(bob);
        uint256 feeBefore = _usdcBalance(feeRecipient);

        vm.prank(bob);
        exchange.placeOrder(MARKET_ID, IPrediXExchange.Side.SELL_NO, takerPrice, amount);

        uint256 aliceGain = _usdcBalance(alice) - aliceBefore;
        uint256 bobGain = _usdcBalance(bob) - bobBefore;
        uint256 feeGain = _usdcBalance(feeRecipient) - feeBefore;

        assertEq(aliceGain + bobGain + feeGain, amount, "USDC conservation across MERGE");
        assertEq(feeGain, 0, "no surplus collected post-X1");
    }

    function test_Backlog_FeeCollected_NotEmittedInMerge() public {
        // Dedicated log-filter test. Uses recordLogs so this still catches
        // a future refactor that re-introduces a FeeCollected in the MERGE
        // path even if USDC balance assertions remain correct by accident
        // (e.g., fee routed elsewhere first).
        _placeSellYes(alice, 550_000, 100 * ONE_SHARE);
        _giveYesNo(bob, 100 * ONE_SHARE);

        vm.recordLogs();
        vm.prank(bob);
        exchange.placeOrder(MARKET_ID, IPrediXExchange.Side.SELL_NO, 400_000, 100 * ONE_SHARE);

        bytes32 feeTopic = keccak256("FeeCollected(uint256,uint256)");
        Vm.Log[] memory logs = vm.getRecordedLogs();
        uint256 feeEventCount;
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter == address(exchange) && logs[i].topics.length > 0 && logs[i].topics[0] == feeTopic) {
                feeEventCount++;
            }
        }
        assertEq(feeEventCount, 0, "MERGE path must not emit FeeCollected");
    }

    function test_Backlog_PreviewMatchesExecute() public {
        // Preview and execute must now agree on the taker's received USDC.
        // Pre-X1 they disagreed: preview returned the complement (correct),
        // execute delivered the limit (bug). Ties to §X2 (GAP-C) preview-
        // execute parity — this test locks the high-level symptom so a
        // later refactor cannot silently re-introduce the drift.
        _placeSellYes(alice, 770_000, 10 * ONE_SHARE);
        _giveYesNo(bob, 10 * ONE_SHARE);

        (uint256 previewFilled,) = exchange.previewFillMarketOrder(
            MARKET_ID, IPrediXExchange.Side.SELL_NO, 10_000, 10 * ONE_SHARE, 0, address(0)
        );

        uint256 bobBefore = _usdcBalance(bob);
        vm.prank(bob);
        (uint256 actualFilled,) = exchange.fillMarketOrder(
            MARKET_ID, IPrediXExchange.Side.SELL_NO, 10_000, 10 * ONE_SHARE, bob, bob, 0, _deadline()
        );
        uint256 bobGain = _usdcBalance(bob) - bobBefore;

        assertEq(previewFilled, actualFilled, "preview.filled == execute.filled");
        assertEq(previewFilled, bobGain, "preview matches taker's actual USDC gain");
    }
}
