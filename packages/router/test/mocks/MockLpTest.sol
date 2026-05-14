// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {ModifyLiquidityParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";

/// @title MockLpTest
/// @notice Stand-in for the production liquidity router used by `PrediXMarketFactory`
///         in the M-06 allowance-bounding test. Captures the YES/USDC allowance the
///         factory grants at the moment `modifyLiquidity` runs so the test can assert
///         the bound is non-max (i.e. scoped to the call's actual budget) and that
///         the post-call allowance is zero.
contract MockLpTest {
    uint256 public observedYesAllowance;
    uint256 public observedUsdcAllowance;
    address public yesToken;
    address public usdc;

    function setObservedTokens(address yes_, address usdc_) external {
        yesToken = yes_;
        usdc = usdc_;
    }

    function modifyLiquidity(PoolKey memory, ModifyLiquidityParams memory, bytes memory)
        external
        payable
        returns (int256)
    {
        if (yesToken != address(0)) {
            observedYesAllowance = IERC20(yesToken).allowance(msg.sender, address(this));
        }
        if (usdc != address(0)) {
            observedUsdcAllowance = IERC20(usdc).allowance(msg.sender, address(this));
        }
        return 0;
    }
}
