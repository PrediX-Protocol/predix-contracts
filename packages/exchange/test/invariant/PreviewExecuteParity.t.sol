// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {IPrediXExchange} from "../../src/IPrediXExchange.sol";
import {PrediXExchange} from "../../src/PrediXExchange.sol";

import {MockERC20} from "../mocks/MockERC20.sol";
import {MockDiamond} from "../mocks/MockDiamond.sol";

/// @title PreviewExecuteParityTest
/// @notice Differential fuzz: for any (side, amountIn, maxFills, orderbook state),
///         `previewFillMarketOrder(...)` MUST return the same `(filled, cost)` tuple
///         as the subsequent `fillMarketOrder(...)` would produce, taken in the same
///         block and against the same orderbook.
/// @dev Motivation (session 2026-04-20 diagnosis): a fresh-deploy BUY_YES $1 trace
///      showed `previewFillMarketOrder` reporting `cost=1_000_000` while the
///      execute path consumed `cost=999_999` on identical inputs. The 1-wei skew
///      leaked into the Router, where the remainder fell into the AMM leg and
///      reverted with `InsufficientLiquidity` after the dynamic fee consumed the
///      sub-fee input. The Router now tolerates dust (prior session fix) but the
///      skew itself is a correctness issue — this fuzz is meant to surface the
///      divergent input space so a root-cause patch can be scoped to the exact
///      math branch.
///
///      Expected to FAIL at call time on the current deploy. Once the math is
///      aligned between `_previewFillMarketOrder` (Views.sol) and
///      `_fillMarketOrder` / `_execute{Complementary,Synthetic}TakerFill`
///      (TakerPath.sol), the invariant flips to PASS and guards against future
///      drift.
contract PreviewExecuteParityTest is Test {
    MockERC20 internal usdc;
    MockDiamond internal diamond;
    PrediXExchange internal exchange;

    address internal feeRecipient = makeAddr("feeRecipient");
    uint256 internal constant MARKET_ID = 1;

    address internal yesToken;
    address internal noToken;

    // Deterministic seed set of maker orders covering complementary + synthetic
    // sides at common price points. Avoids fuzzing the orderbook structure itself
    // — the fuzz dimension is the taker input, not the book shape.
    address[] internal makers;

    function setUp() public {
        usdc = new MockERC20("USDC", "USDC", 6);
        diamond = new MockDiamond(address(usdc));
        exchange = new PrediXExchange(address(diamond), address(usdc), feeRecipient);
        (yesToken, noToken) = diamond.createMarket(MARKET_ID, block.timestamp + 365 days, address(this));

        for (uint256 i = 0; i < 8; ++i) {
            address m = makeAddr(string.concat("maker-", vm.toString(i)));
            makers.push(m);
            usdc.mint(m, 1_000_000e6);
            vm.startPrank(m);
            usdc.approve(address(exchange), type(uint256).max);
            usdc.approve(address(diamond), type(uint256).max);
            diamond.splitPosition(MARKET_ID, 500_000e6);
            IERC20(yesToken).approve(address(exchange), type(uint256).max);
            IERC20(noToken).approve(address(exchange), type(uint256).max);
            vm.stopPrank();
        }

        _seedBook();
    }

    // Seeds a layered orderbook: SELL_YES asks at 0.47, 0.48, 0.49; BUY_YES bids
    // at 0.46, 0.45; plus SELL_NO / BUY_NO so the synthetic path is reachable.
    function _seedBook() internal {
        _place(makers[0], IPrediXExchange.Side.SELL_YES, 470_000, 10e6);
        _place(makers[1], IPrediXExchange.Side.SELL_YES, 480_000, 15e6);
        _place(makers[2], IPrediXExchange.Side.SELL_YES, 490_000, 20e6);
        _place(makers[3], IPrediXExchange.Side.BUY_YES, 460_000, 12e6);
        _place(makers[4], IPrediXExchange.Side.BUY_YES, 450_000, 18e6);
        _place(makers[5], IPrediXExchange.Side.SELL_NO, 530_000, 10e6);
        _place(makers[6], IPrediXExchange.Side.BUY_NO, 540_000, 12e6);
        _place(makers[7], IPrediXExchange.Side.SELL_NO, 520_000, 8e6);
    }

    function _place(address owner, IPrediXExchange.Side side, uint256 price, uint256 amount) internal {
        vm.prank(owner);
        exchange.placeOrder(MARKET_ID, side, price, amount);
    }

    /// @notice Fuzz dimension: `sideRaw` ∈ {0..3}, `amountIn` sized so it can
    ///         partially fill the seeded book, `maxFills` ∈ {1..20}. For each
    ///         sample, snapshot state → run preview → rewind → run execute →
    ///         compare tuples byte-for-byte.
    /// forge-config: default.fuzz.runs = 1024
    function testFuzz_PreviewMatchesExecute(uint8 sideRaw, uint256 amountIn, uint8 maxFillsRaw) public {
        IPrediXExchange.Side side = IPrediXExchange.Side(uint8(sideRaw % 4));
        uint256 maxFills = uint256(maxFillsRaw % 20) + 1;
        amountIn = bound(amountIn, 1, 50e6);

        address taker = makeAddr("parity-taker");
        // Pre-fund taker generously so execute never reverts on lack of balance.
        usdc.mint(taker, 1_000_000e6);
        vm.startPrank(taker);
        usdc.approve(address(exchange), type(uint256).max);
        usdc.approve(address(diamond), type(uint256).max);
        diamond.splitPosition(MARKET_ID, 500_000e6);
        IERC20(yesToken).approve(address(exchange), type(uint256).max);
        IERC20(noToken).approve(address(exchange), type(uint256).max);
        vm.stopPrank();

        uint256 snap = vm.snapshot();

        uint256 limitPrice = _isBuy(side) ? 990_000 : 1;
        (uint256 previewFilled, uint256 previewCost) =
            exchange.previewFillMarketOrder(MARKET_ID, side, limitPrice, amountIn, maxFills);

        vm.revertTo(snap);

        vm.prank(taker);
        (uint256 actualFilled, uint256 actualCost) =
            exchange.fillMarketOrder(MARKET_ID, side, limitPrice, amountIn, taker, taker, maxFills, block.timestamp + 1);

        assertEq(previewFilled, actualFilled, "filled drift");
        assertEq(previewCost, actualCost, "cost drift");
    }

    function _isBuy(IPrediXExchange.Side s) internal pure returns (bool) {
        return s == IPrediXExchange.Side.BUY_YES || s == IPrediXExchange.Side.BUY_NO;
    }
}
