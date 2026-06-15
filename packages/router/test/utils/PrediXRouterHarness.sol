// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import {PrediXRouter} from "@predix/router/PrediXRouter.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IV4Quoter} from "@uniswap/v4-periphery/src/interfaces/IV4Quoter.sol";
import {IAllowanceTransfer} from "permit2/src/interfaces/IAllowanceTransfer.sol";
import {IBuilderRegistry} from "@predix/shared/interfaces/IBuilderRegistry.sol";

/// @dev Test-only subclass re-exporting the router's internal fee helpers. Adds NO production
///      behaviour — every entry/callback is inherited verbatim.
contract PrediXRouterHarness is PrediXRouter {
    constructor(
        IPoolManager _poolManager,
        address _diamond,
        address _usdc,
        address _hook,
        address _exchange,
        IV4Quoter _quoter,
        IAllowanceTransfer _permit2,
        uint24 _lpFeeFlag,
        int24 _tickSpacing,
        IBuilderRegistry _builderRegistry
    )
        PrediXRouter(
            _poolManager,
            _diamond,
            _usdc,
            _hook,
            _exchange,
            _quoter,
            _permit2,
            _lpFeeFlag,
            _tickSpacing,
            _builderRegistry
        )
    {}

    function exposed_feeOn(uint256 amount, uint16 bps) external pure returns (uint256) {
        return _feeOn(amount, bps);
    }

    function exposed_curveFee(uint256 shares, uint16 coefBps, uint256 p) external pure returns (uint256) {
        return _curveFee(shares, coefBps, p);
    }
}
