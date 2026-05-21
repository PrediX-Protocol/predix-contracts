// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import {IV4Quoter} from "@uniswap/v4-periphery/src/interfaces/IV4Quoter.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";

/// @dev Minimal V4Quoter stub. Tests configure a canned `(amountOut, gasEstimate)` pair per
///      direction; each call consumes the queued value. Non-view signature matches the real
///      IV4Quoter (it internally uses the revert-and-decode pattern in production).
contract MockV4Quoter is IV4Quoter {
    struct Canned {
        uint256 amountOut;
        uint256 amountIn;
        bool set;
    }

    Canned internal _exactIn;
    Canned internal _exactOut;
    uint256 public callCount;

    /// @dev Optional override keyed by zeroForOne direction. When unset, the exact-in helper
    ///      falls back to `_exactIn`. Used by tests that need different spot quotes for the
    ///      two swap directions within the same call (e.g. CLOB cap derivation for buy/sell).
    mapping(bool => Canned) internal _exactInByDir;

    /// @dev Optional FIFO queue keyed by zeroForOne direction. Each call to
    ///      `quoteExactInputSingle` consumes the next entry (if any) from the
    ///      matching direction's queue before falling through to the per-direction
    ///      override or the global single-shot canned. Used by tests that exercise
    ///      multi-pass quote paths (NEW-M7 two-pass `_computeBuyNoMintAmount`),
    ///      where two calls in the same direction must return different values.
    mapping(bool => uint256[]) internal _queueByDir;
    mapping(bool => uint256) internal _queueIdxByDir;

    function setExactInResult(uint256 amountOut) external {
        _exactIn = Canned({amountOut: amountOut, amountIn: 0, set: true});
    }

    function setExactInResult(bool zeroForOne, uint256 amountOut) external {
        _exactInByDir[zeroForOne] = Canned({amountOut: amountOut, amountIn: 0, set: true});
    }

    /// @notice Queue `amounts` to be returned on successive `quoteExactInputSingle`
    ///         calls matching `zeroForOne`. Resets the queue pointer.
    function setExactInSequence(bool zeroForOne, uint256[] memory amounts) external {
        delete _queueByDir[zeroForOne];
        for (uint256 i; i < amounts.length; ++i) {
            _queueByDir[zeroForOne].push(amounts[i]);
        }
        _queueIdxByDir[zeroForOne] = 0;
    }

    function setExactOutResult(uint256 amountIn) external {
        _exactOut = Canned({amountOut: 0, amountIn: amountIn, set: true});
    }

    /// @dev Resolution order for a non-sequence query:
    ///        1. Per-direction sequence (FIFO, absolute values)
    ///        2. Per-direction or global canned, interpreted as "output for an input of
    ///           `PRICE_PRECISION` (1e6)" and scaled linearly with `params.exactAmount`.
    ///      Linear scaling models a no-impact pool (spot price independent of size). Tests
    ///      that need impact use the sequence API to provide specific values per call.
    function quoteExactInputSingle(QuoteExactSingleParams memory params)
        external
        override
        returns (uint256 amountOut, uint256 gasEstimate)
    {
        uint256 idx = _queueIdxByDir[params.zeroForOne];
        uint256[] storage q = _queueByDir[params.zeroForOne];
        if (idx < q.length) {
            amountOut = q[idx];
            _queueIdxByDir[params.zeroForOne] = idx + 1;
        } else {
            Canned memory c = _exactInByDir[params.zeroForOne];
            if (!c.set) c = _exactIn;
            // Scale canned (= output for 1e6 input) by the actual input size.
            // Pure-multiplicative model: matches real V4 quoter on infinite-depth pools
            // and keeps existing test fixtures that set canned via `setExactInResult`
            // size-invariant under the new effective-cap derivation in router.
            amountOut = (uint256(params.exactAmount) * c.amountOut) / 1e6;
        }
        gasEstimate = 0;
        callCount += 1;
    }

    function quoteExactInput(QuoteExactParams memory) external pure override returns (uint256, uint256) {
        revert("not used");
    }

    /// @dev Canned `_exactOut.amountIn` is interpreted as "input cost for an
    ///      output of 1e6" and scaled linearly with `params.exactAmount`. Mirrors
    ///      the exact-in scaling so size-aware cap derivation (effective price at
    ///      the actual trade size) is consistent across both quote directions.
    function quoteExactOutputSingle(QuoteExactSingleParams memory params)
        external
        override
        returns (uint256 amountIn, uint256 gasEstimate)
    {
        amountIn = (uint256(params.exactAmount) * _exactOut.amountIn) / 1e6;
        gasEstimate = 0;
        callCount += 1;
    }

    function quoteExactOutput(QuoteExactParams memory) external pure override returns (uint256, uint256) {
        revert("not used");
    }

    // ---- IImmutableState / IMsgSender surfaces ----
    function poolManager() external pure override returns (IPoolManager) {
        return IPoolManager(address(0));
    }

    function msgSender() external view override returns (address) {
        return msg.sender;
    }
}
