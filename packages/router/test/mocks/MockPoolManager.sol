// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {BalanceDelta, toBalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {IUnlockCallback} from "@uniswap/v4-core/src/interfaces/callback/IUnlockCallback.sol";

import {MockERC20} from "./MockERC20.sol";

/// @dev Minimal IPoolManager stub that implements only the surface the router touches:
///      unlock (bounces into IUnlockCallback.unlockCallback), swap (returns a queued
///      BalanceDelta), sync + settle + take (simulate v4 flash accounting).
///
///      The fixture pre-mints YES outcome tokens to this mock so `take(yesToken, ...)`
///      can physically deliver tokens. USDC owed back to the mock via `settle` is tracked
///      against the synced baseline.
///
///      Tests queue a swap result with {queueSwapResult}; the next `swap` call consumes
///      it. If no result is queued, `swap` reverts — makes missing setup loud.
contract MockPoolManager {
    struct QueuedSwap {
        int128 amount0;
        int128 amount1;
        bool set;
    }

    QueuedSwap internal _queued;

    Currency internal _syncedCurrency;
    uint256 internal _syncedBalance;
    bool internal _hasSync;

    // Debt tracking for assertions
    uint256 public lastSettledAmount;
    address public lastTakeTo;
    address public lastTakeCurrency;
    uint256 public lastTakeAmount;
    uint256 public swapCount;

    event MockSwap(address indexed caller, int128 amount0, int128 amount1, uint256 sequence);

    function queueSwapResult(int128 amount0, int128 amount1) external {
        _queued = QueuedSwap({amount0: amount0, amount1: amount1, set: true});
    }

    function unlock(bytes calldata data) external returns (bytes memory) {
        return IUnlockCallback(msg.sender).unlockCallback(data);
    }

    function swap(PoolKey memory, SwapParams memory, bytes calldata) external returns (BalanceDelta delta) {
        require(_queued.set, "MockPoolManager: no queued swap");
        QueuedSwap memory q = _queued;
        delete _queued;
        swapCount += 1;
        emit MockSwap(msg.sender, q.amount0, q.amount1, swapCount);
        return toBalanceDelta(q.amount0, q.amount1);
    }

    function sync(Currency currency) external {
        _syncedCurrency = currency;
        address tok = Currency.unwrap(currency);
        _syncedBalance = IERC20(tok).balanceOf(address(this));
        _hasSync = true;
    }

    function settle() external payable returns (uint256 paid) {
        require(_hasSync, "MockPoolManager: no sync");
        address tok = Currency.unwrap(_syncedCurrency);
        uint256 nowBal = IERC20(tok).balanceOf(address(this));
        paid = nowBal - _syncedBalance;
        lastSettledAmount = paid;
        _hasSync = false;
    }

    function take(Currency currency, address to, uint256 amount) external {
        lastTakeCurrency = Currency.unwrap(currency);
        lastTakeTo = to;
        lastTakeAmount = amount;
        address tok = Currency.unwrap(currency);
        uint256 bal = IERC20(tok).balanceOf(address(this));
        if (bal >= amount) {
            IERC20(tok).transfer(to, amount);
        } else {
            // For outcome tokens we can mint on demand — the fixture uses MockERC20 pattern.
            MockERC20(tok).mint(to, amount);
        }
    }
}
