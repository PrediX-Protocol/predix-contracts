// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {BeforeSwapDelta} from "@uniswap/v4-core/src/types/BeforeSwapDelta.sol";
import {SwapParams, ModifyLiquidityParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";

import {PrediXHookV2} from "../../src/hooks/PrediXHookV2.sol";

/// @title TestHookHarness
/// @notice Inherits `PrediXHookV2` and exposes the internal `_beforeX` / `_afterSwap`
///         helpers as external functions so unit tests can exercise pure logic without
///         going through the IHooks dispatchers (which require `msg.sender == poolManager`).
contract TestHookHarness is PrediXHookV2 {
    constructor(IPoolManager poolManager_, address quoter_) PrediXHookV2(poolManager_, quoter_) {
        // Reset the defense-in-depth guard that PrediXHookV2's constructor sets.
        // In production the proxy's delegatecall writes to proxy storage (different
        // address) so the impl's `_initialized = true` is irrelevant. In test
        // harnesses there is no proxy — the harness IS the contract — so we must
        // clear the flag to allow `initialize()` to run.
        _initialized = false;
    }

    function exposed_beforeInitialize(address sender, PoolKey calldata key, uint160 sqrtPriceX96)
        external
        view
        returns (bytes4)
    {
        return _beforeInitialize(sender, key, sqrtPriceX96);
    }

    function exposed_beforeAddLiquidity(
        address sender,
        PoolKey calldata key,
        ModifyLiquidityParams calldata params,
        bytes calldata hookData
    ) external view returns (bytes4) {
        return _beforeAddLiquidity(sender, key, params, hookData);
    }

    function exposed_beforeRemoveLiquidity(
        address sender,
        PoolKey calldata key,
        ModifyLiquidityParams calldata params,
        bytes calldata hookData
    ) external view returns (bytes4) {
        return _beforeRemoveLiquidity(sender, key, params, hookData);
    }

    function exposed_beforeDonate(
        address sender,
        PoolKey calldata key,
        uint256 amount0,
        uint256 amount1,
        bytes calldata hookData
    ) external view returns (bytes4) {
        return _beforeDonate(sender, key, amount0, amount1, hookData);
    }

    function exposed_beforeSwap(
        address sender,
        PoolKey calldata key,
        SwapParams calldata params,
        bytes calldata hookData
    ) external returns (bytes4, BeforeSwapDelta, uint24) {
        return _beforeSwap(sender, key, params, hookData);
    }

    function exposed_afterSwap(
        address sender,
        PoolKey calldata key,
        SwapParams calldata params,
        BalanceDelta delta,
        bytes calldata hookData
    ) external returns (bytes4, int128) {
        return _afterSwap(sender, key, params, delta, hookData);
    }
}
