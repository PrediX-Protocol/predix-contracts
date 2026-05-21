// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IPrediXExchangeView} from "@predix/router/interfaces/IPrediXExchangeView.sol";
import {MockERC20} from "./MockERC20.sol";

/// @dev Configurable CLOB stub. Tests queue canned `(filled, cost)` results via {setResult};
///      each `fillMarketOrder` consumes the queued result and performs the matching token
///      transfers so the router's balance invariants stay consistent. If `revertOnFill` is
///      set, `fillMarketOrder` reverts — used to exercise the try/catch fallback path.
contract MockExchange {
    error ExchangePaused();

    address public immutable usdc;

    struct Canned {
        uint256 filled;
        uint256 cost;
        bool set;
    }

    // market → side → canned result
    mapping(uint256 => mapping(IPrediXExchangeView.Side => Canned)) internal _canned;
    // yesToken/noToken lookup per market for settlement
    mapping(uint256 => address) public marketYes;
    mapping(uint256 => address) public marketNo;
    bool public revertOnFill;
    bool public revertOnPreview;

    uint256 public lastLimitPrice;
    uint256 public lastMaxFills;

    /// @dev Opt-in cap-aware order book. When a book is set for (market, side),
    ///      preview/fill walk the price tranches respecting the taker `limitPrice`
    ///      cap (BUY: price ≤ cap; SELL: price ≥ cap), instead of the flat canned
    ///      result. Used by the effective-cap convergence tests where the cap
    ///      changes the eligible depth. Tranches are pre-sorted best-first by the
    ///      test (BUY makers = SELL_* asks ascending; SELL makers = BUY_* bids
    ///      descending).
    struct Tranche {
        uint256 price; // 1e6 units
        uint256 shares; // YES/NO depth at this price
    }

    mapping(uint256 => mapping(IPrediXExchangeView.Side => Tranche[])) internal _book;
    mapping(uint256 => mapping(IPrediXExchangeView.Side => bool)) internal _bookSet;

    function setBook(uint256 marketId, IPrediXExchangeView.Side side, uint256[] calldata prices, uint256[] calldata shares)
        external
    {
        require(prices.length == shares.length, "len");
        delete _book[marketId][side];
        for (uint256 i; i < prices.length; ++i) {
            _book[marketId][side].push(Tranche({price: prices[i], shares: shares[i]}));
        }
        _bookSet[marketId][side] = true;
    }

    /// @dev Walk the book respecting cap + budget + maxFills. BUY taker spends
    ///      USDC (budget = amountIn USDC, output = shares); SELL taker spends
    ///      shares (budget = amountIn shares, output = USDC).
    function _walkBook(
        uint256 marketId,
        IPrediXExchangeView.Side side,
        uint256 cap,
        uint256 amountIn,
        uint256 maxFills
    ) internal view returns (uint256 filled, uint256 cost) {
        Tranche[] storage book = _book[marketId][side];
        bool takerIsBuy = side == IPrediXExchangeView.Side.BUY_YES || side == IPrediXExchangeView.Side.BUY_NO;
        uint256 fills;
        for (uint256 i; i < book.length; ++i) {
            if (fills >= maxFills) break;
            uint256 price = book[i].price;
            // Cap gate: BUY takes price ≤ cap; SELL takes price ≥ cap.
            if (takerIsBuy ? price > cap : price < cap) continue;
            uint256 shares = book[i].shares;
            if (shares == 0) continue;
            if (takerIsBuy) {
                uint256 remBudget = amountIn - cost; // USDC left
                uint256 affordable = (remBudget * 1e6) / price; // shares affordable
                uint256 take = shares < affordable ? shares : affordable;
                if (take == 0) break;
                cost += (take * price) / 1e6;
                filled += take;
            } else {
                uint256 remShares = amountIn - cost; // shares left to sell
                uint256 take = shares < remShares ? shares : remShares;
                if (take == 0) break;
                cost += take; // shares consumed
                filled += (take * price) / 1e6; // USDC out
            }
            fills++;
        }
    }

    constructor(address _usdc) {
        usdc = _usdc;
    }

    function setMarketTokens(uint256 marketId, address yes, address no) external {
        marketYes[marketId] = yes;
        marketNo[marketId] = no;
    }

    function setResult(uint256 marketId, IPrediXExchangeView.Side side, uint256 filled, uint256 cost) external {
        _canned[marketId][side] = Canned({filled: filled, cost: cost, set: true});
    }

    function setRevertOnFill(bool v) external {
        revertOnFill = v;
    }

    function setRevertOnPreview(bool v) external {
        revertOnPreview = v;
    }

    function fillMarketOrder(
        uint256 marketId,
        IPrediXExchangeView.Side takerSide,
        uint256 limitPrice,
        uint256 amountIn,
        address taker,
        address recipient,
        uint256 maxFills,
        uint256 deadline,
        bytes32 /* takerBuilder */
    ) external returns (uint256 filled, uint256 cost) {
        if (revertOnFill) revert ExchangePaused();
        require(block.timestamp <= deadline, "MockExchange: deadline");
        lastLimitPrice = limitPrice;
        lastMaxFills = maxFills;

        if (_bookSet[marketId][takerSide]) {
            (filled, cost) = _walkBook(marketId, takerSide, limitPrice, amountIn, maxFills);
            if (filled == 0) return (0, cost);
            _consumeBook(marketId, takerSide, limitPrice, amountIn, maxFills);
        } else {
            Canned memory c = _canned[marketId][takerSide];
            if (!c.set) {
                return (0, 0);
            }
            filled = c.filled;
            cost = c.cost;
            if (cost > amountIn) cost = amountIn;
            if (filled == 0) return (0, cost);
            // Clear canned so consecutive test calls can set fresh expectations.
            delete _canned[marketId][takerSide];
        }

        address inToken;
        address outToken;
        if (takerSide == IPrediXExchangeView.Side.BUY_YES) {
            inToken = usdc;
            outToken = marketYes[marketId];
        } else if (takerSide == IPrediXExchangeView.Side.SELL_YES) {
            inToken = marketYes[marketId];
            outToken = usdc;
        } else if (takerSide == IPrediXExchangeView.Side.BUY_NO) {
            inToken = usdc;
            outToken = marketNo[marketId];
        } else {
            inToken = marketNo[marketId];
            outToken = usdc;
        }

        if (cost > 0) IERC20(inToken).transferFrom(taker, address(this), cost);
        if (outToken == usdc) {
            IERC20(usdc).transfer(recipient, filled);
        } else {
            MockERC20(outToken).mint(recipient, filled);
        }
    }

    function previewFillMarketOrder(
        uint256 marketId,
        IPrediXExchangeView.Side takerSide,
        uint256 limitPrice,
        uint256 amountIn,
        uint256 maxFills,
        address /*taker*/
    ) external view returns (uint256 filled, uint256 cost) {
        if (revertOnPreview) revert("MockExchange: revertOnPreview");
        if (_bookSet[marketId][takerSide]) {
            return _walkBook(marketId, takerSide, limitPrice, amountIn, maxFills == 0 ? type(uint256).max : maxFills);
        }
        Canned memory c = _canned[marketId][takerSide];
        if (!c.set) return (0, 0);
        filled = c.filled;
        cost = c.cost > amountIn ? amountIn : c.cost;
    }

    /// @dev Mutating twin of {_walkBook}: subtracts consumed shares from each
    ///      eligible tranche so a subsequent fill round sees the depleted book.
    function _consumeBook(
        uint256 marketId,
        IPrediXExchangeView.Side side,
        uint256 cap,
        uint256 amountIn,
        uint256 maxFills
    ) internal {
        Tranche[] storage book = _book[marketId][side];
        bool takerIsBuy = side == IPrediXExchangeView.Side.BUY_YES || side == IPrediXExchangeView.Side.BUY_NO;
        uint256 fills;
        uint256 spent; // USDC (buy) or shares (sell) consumed so far
        for (uint256 i; i < book.length; ++i) {
            if (fills >= maxFills) break;
            uint256 price = book[i].price;
            if (takerIsBuy ? price > cap : price < cap) continue;
            uint256 shares = book[i].shares;
            if (shares == 0) continue;
            uint256 take;
            if (takerIsBuy) {
                uint256 remBudget = amountIn - spent;
                uint256 affordable = (remBudget * 1e6) / price;
                take = shares < affordable ? shares : affordable;
                if (take == 0) break;
                spent += (take * price) / 1e6;
            } else {
                uint256 remShares = amountIn - spent;
                take = shares < remShares ? shares : remShares;
                if (take == 0) break;
                spent += take;
            }
            book[i].shares = shares - take;
            fills++;
        }
    }
}
