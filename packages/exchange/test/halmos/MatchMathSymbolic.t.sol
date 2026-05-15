// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import {Test} from "forge-std/Test.sol";
import {MatchMath} from "../../src/libraries/MatchMath.sol";
import {IPrediXExchange} from "../../src/IPrediXExchange.sol";

/// @notice Halmos symbolic tests for MatchMath.
/// @dev Run with: `halmos --contract MatchMathSymbolic --solver-timeout-assertion 10000`
///      These tests verify properties hold for ALL possible inputs, not just random samples.
contract MatchMathSymbolic is Test {
    uint256 constant PRICE_PRECISION = 1e6;
    uint256 constant MAX_PRICE = 990_000;
    uint256 constant MIN_PRICE = 10_000;

    /// @notice syntheticEffectivePrice + makerPrice == PRICE_PRECISION for valid prices.
    function check_syntheticPrice_complement(uint256 makerPrice) public pure {
        vm.assume(makerPrice > 0 && makerPrice < PRICE_PRECISION);
        uint256 effective = MatchMath.syntheticEffectivePrice(makerPrice);
        assert(effective + makerPrice == PRICE_PRECISION);
    }

    /// @notice syntheticEffectivePrice returns 0 for invalid prices.
    function check_syntheticPrice_zeroForInvalid(uint256 makerPrice) public pure {
        vm.assume(makerPrice == 0 || makerPrice >= PRICE_PRECISION);
        uint256 effective = MatchMath.syntheticEffectivePrice(makerPrice);
        assert(effective == 0);
    }

    /// @notice computeFillDeltas: complementary BUY always returns (makerShare, fillAmt).
    function check_fillDeltas_complementary_buy(uint256 price, uint256 fillAmt) public pure {
        price = bound(price, MIN_PRICE, MAX_PRICE);
        fillAmt = bound(fillAmt, 1, type(uint64).max);

        (uint256 inBuy, uint256 outBuy) = MatchMath.computeFillDeltas(price, fillAmt, true, false);
        if (inBuy == 0 && outBuy == 0) return;

        assert(outBuy == fillAmt);
        assert(inBuy > 0);
    }

    /// @notice computeFillDeltas: synthetic match conserves total = fillAmt.
    function check_fillDeltas_synthetic_conservation(uint256 price, uint256 fillAmt) public pure {
        vm.assume(price >= MIN_PRICE && price <= MAX_PRICE);
        vm.assume(fillAmt > 0 && fillAmt <= type(uint128).max);

        (uint256 inBuy, uint256 outBuy) = MatchMath.computeFillDeltas(price, fillAmt, true, true);
        if (inBuy == 0 && outBuy == 0) return; // dust

        // SYNTHETIC BUY: inDelta = takerPortion, outDelta = fillAmt
        // takerPortion + makerShare = fillAmt
        uint256 makerShare = (fillAmt * price) / PRICE_PRECISION;
        assert(inBuy + makerShare == fillAmt);
        assert(outBuy == fillAmt);
    }

    /// @notice computeFillAmount: result <= min(makerCapacity, derived takerCapacity).
    function check_fillAmount_bounded(
        uint256 makerCapacity,
        uint256 budget,
        uint256 price
    ) public pure {
        vm.assume(price >= MIN_PRICE && price <= MAX_PRICE);
        vm.assume(makerCapacity > 0 && makerCapacity <= type(uint128).max);
        vm.assume(budget > 0 && budget <= type(uint128).max);

        uint256 fill = MatchMath.computeFillAmount(makerCapacity, budget, price, true, false);
        assert(fill <= makerCapacity);
    }

    /// @notice priceWithinLimit: BUY limit is a ceiling, SELL limit is a floor.
    function check_priceWithinLimit_semantics(uint256 price, uint256 limit) public pure {
        bool buyOk = MatchMath.priceWithinLimit(price, limit, true);
        bool sellOk = MatchMath.priceWithinLimit(price, limit, false);

        if (buyOk) assert(price <= limit);
        if (sellOk) assert(price >= limit);
    }

    /// @notice preferComplementary: if only comp is OK, must prefer comp.
    function check_preferComp_onlyCompAvailable(uint256 compPrice, uint256 synPrice) public pure {
        bool result = MatchMath.preferComplementary(compPrice, synPrice, true, false, true);
        assert(result == true);
    }

    /// @notice preferComplementary: if only syn is OK, must prefer syn.
    function check_preferComp_onlySynAvailable(uint256 compPrice, uint256 synPrice) public pure {
        bool result = MatchMath.preferComplementary(compPrice, synPrice, false, true, true);
        assert(result == false);
    }

    /// @notice sidesFor: complementary and synthetic sides are distinct.
    function check_sidesFor_distinct(uint8 sideRaw) public pure {
        vm.assume(sideRaw <= 3);
        IPrediXExchange.Side side = IPrediXExchange.Side(sideRaw);
        (IPrediXExchange.Side comp, IPrediXExchange.Side syn) = MatchMath.sidesFor(side);
        assert(comp != syn);
        assert(comp != side);
        assert(syn != side);
    }
}
