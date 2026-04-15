// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {IPrediXExchange} from "../../src/IPrediXExchange.sol";
import {PrediXExchange} from "../../src/PrediXExchange.sol";

import {MockERC20} from "../mocks/MockERC20.sol";
import {MockDiamond} from "../mocks/MockDiamond.sol";

import {ExchangeHandler} from "./ExchangeHandler.sol";

/// @title PrediXExchangeInvariantTest
/// @notice Solvency + collateral invariants verified via randomized handler runs.
///
/// @dev Strict equality is enforced after the Option 4 dust filter landed in
///      `TakerPath._executeComplementaryTakerFill` / `_executeSyntheticTakerFill`
///      and `MakerPath._matchMintAtTick`. The filter self-skips fills whose
///      integer-floored USDC leg would under-collateralize the accounting
///      (`balance < Σ depositLocked`), eliminating the 3-wei drift surfaced by
///      the shrunk Foundry sequence documented in `test/dust/DustReproducer.t.sol`.
contract PrediXExchangeInvariantTest is Test {
    MockERC20 internal usdc;
    MockDiamond internal diamond;
    PrediXExchange internal exchange;
    ExchangeHandler internal handler;

    address internal feeRecipient = makeAddr("feeRecipient");
    uint256 internal constant MARKET_ID = 1;

    address internal yesToken;
    address internal noToken;

    function setUp() public {
        usdc = new MockERC20("USDC", "USDC", 6);
        diamond = new MockDiamond(address(usdc));
        exchange = new PrediXExchange(address(diamond), address(usdc), feeRecipient);
        (yesToken, noToken) = diamond.createMarket(MARKET_ID, block.timestamp + 365 days, address(this));

        handler = new ExchangeHandler(exchange, usdc, diamond, MARKET_ID, yesToken, noToken);
        targetContract(address(handler));
    }

    /// @notice I1 (relaxed): Exchange's USDC balance must hold AT LEAST the sum of
    ///         every active BUY order's `depositLocked`. Over-collateralization by
    ///         a few wei is expected (see contract NatSpec) and safe.
    function invariant_solvency_usdc() public view {
        uint256 sum;
        uint256 n = handler.orderCount();
        for (uint256 i; i < n; ++i) {
            IPrediXExchange.Order memory ord = exchange.getOrder(handler.orderAt(i));
            if (ord.cancelled || ord.filled >= ord.amount) continue;
            if (ord.side == IPrediXExchange.Side.BUY_YES || ord.side == IPrediXExchange.Side.BUY_NO) {
                sum += ord.depositLocked;
            }
        }
        assertEq(usdc.balanceOf(address(exchange)), sum, "Exchange USDC == active BUY locks");
    }

    /// @notice I2 (YES leg, relaxed): Exchange's YES balance >= sum of active
    ///         SELL_YES `depositLocked`.
    function invariant_solvency_yes() public view {
        uint256 sum;
        uint256 n = handler.orderCount();
        for (uint256 i; i < n; ++i) {
            IPrediXExchange.Order memory ord = exchange.getOrder(handler.orderAt(i));
            if (ord.cancelled || ord.filled >= ord.amount) continue;
            if (ord.side == IPrediXExchange.Side.SELL_YES) {
                sum += ord.depositLocked;
            }
        }
        assertEq(IERC20(yesToken).balanceOf(address(exchange)), sum, "Exchange YES == active SELL_YES locks");
    }

    /// @notice I2 (NO leg, relaxed): same for NO tokens.
    function invariant_solvency_no() public view {
        uint256 sum;
        uint256 n = handler.orderCount();
        for (uint256 i; i < n; ++i) {
            IPrediXExchange.Order memory ord = exchange.getOrder(handler.orderAt(i));
            if (ord.cancelled || ord.filled >= ord.amount) continue;
            if (ord.side == IPrediXExchange.Side.SELL_NO) {
                sum += ord.depositLocked;
            }
        }
        assertEq(IERC20(noToken).balanceOf(address(exchange)), sum, "Exchange NO == active SELL_NO locks");
    }

    /// @notice I6: collateral conservation — `YES.totalSupply == NO.totalSupply ==
    ///         market.totalCollateral` is preserved across every split / merge / fill.
    function invariant_collateral_preserved() public view {
        assertEq(IERC20(yesToken).totalSupply(), IERC20(noToken).totalSupply(), "YES.supply == NO.supply");
    }
}
