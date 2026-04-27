// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IPrediXExchangeView} from "@predix/router/interfaces/IPrediXExchangeView.sol";
import {MockERC20} from "./MockERC20.sol";

/// @dev Configurable CLOB stub. Tests queue canned `(filled, cost)` results via {setResult};
///      each `fillMarketOrder` consumes the queued result and performs the matching token
///      transfers so the router's balance invariants stay consistent. If `revertOnFill` is
///      set, `fillMarketOrder` reverts — used to exercise the try/catch fallback path.
contract MockExchange {
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
        uint256 deadline
    ) external returns (uint256 filled, uint256 cost) {
        require(!revertOnFill, "MockExchange: revertOnFill");
        require(block.timestamp <= deadline, "MockExchange: deadline");
        lastLimitPrice = limitPrice;
        lastMaxFills = maxFills;

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
        uint256, /*limitPrice*/
        uint256 amountIn,
        uint256, /*maxFills*/
        address /*taker*/
    ) external view returns (uint256 filled, uint256 cost) {
        if (revertOnPreview) revert("MockExchange: revertOnPreview");
        Canned memory c = _canned[marketId][takerSide];
        if (!c.set) return (0, 0);
        filled = c.filled;
        cost = c.cost > amountIn ? amountIn : c.cost;
    }
}
