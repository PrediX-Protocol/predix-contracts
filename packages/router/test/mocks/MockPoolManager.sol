// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

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

    mapping(bytes32 => bytes32) internal _slots;

    /// @dev Configure extsload return for a pool's slot0. StateLibrary reads
    ///      `pools[poolId]` at a computed slot; for the mock we just store the
    ///      sqrtPriceX96 at the slot key so `_hasPool` sees a non-zero value.
    function setPoolSlot0(bytes32 slotKey, uint160 sqrtPriceX96) external {
        _slots[slotKey] = bytes32(uint256(sqrtPriceX96));
    }

    /// @dev StateLibrary.getLiquidity reads `pools[poolId]` at `stateSlot + LIQUIDITY_OFFSET` (3); store the
    ///      value there so `_hasPool`'s liquidity gate observes it via extsload.
    function setPoolLiquidity(bytes32 stateSlot, uint128 liquidity) external {
        _slots[bytes32(uint256(stateSlot) + 3)] = bytes32(uint256(liquidity));
    }

    /// @dev StateLibrary.getSlot0 calls IPoolManager.extsload(slot).
    function extsload(bytes32 slot) external view returns (bytes32) {
        return _slots[slot];
    }

    // Debt tracking for assertions
    uint256 public lastSettledAmount;
    address public lastTakeTo;
    address public lastTakeCurrency;
    uint256 public lastTakeAmount;
    uint256 public swapCount;

    /// @dev When set, `swap` reverts — exercises the router's AMM-leg try/catch (RTR-1 / clm6.7) so a CLOB
    ///      fill survives an AMM revert (InsufficientLiquidity / QuoteOutsideSafetyMargin) inside the callback.
    bool public revertOnSwap;

    event MockSwap(address indexed caller, int128 amount0, int128 amount1, uint256 sequence);

    function queueSwapResult(int128 amount0, int128 amount1) external {
        _queued = QueuedSwap({amount0: amount0, amount1: amount1, set: true});
    }

    function setRevertOnSwap(bool v) external {
        revertOnSwap = v;
    }

    function unlock(bytes calldata data) external returns (bytes memory) {
        return IUnlockCallback(msg.sender).unlockCallback(data);
    }

    function swap(PoolKey memory, SwapParams memory, bytes calldata) external returns (BalanceDelta delta) {
        if (revertOnSwap) revert("MockPoolManager: forced AMM revert");
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
