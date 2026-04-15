// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {IERC20Permit} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Permit.sol";

/// @title IOutcomeToken
/// @notice ERC20 + Permit outcome token (YES or NO leg) for a single PrediX market.
/// @dev `mint` / `burn` are factory-only. The token self-identifies via `marketId()` and
///      `isYes()` so external consumers (hook, exchange, router) can verify that an arbitrary
///      ERC20 belongs to a known PrediX market without reading diamond storage.
interface IOutcomeToken is IERC20, IERC20Metadata, IERC20Permit {
    /// @notice Thrown when a non-factory address calls a factory-only function.
    error OutcomeToken_NotFactory();

    /// @notice Address allowed to mint and burn (the diamond proxy at deploy time).
    function factory() external view returns (address);

    /// @notice Identifier of the market this token belongs to.
    function marketId() external view returns (uint256);

    /// @notice Whether this token represents the YES outcome (true) or NO outcome (false).
    function isYes() external view returns (bool);

    /// @notice Mint `amount` to `to`. Factory-only.
    function mint(address to, uint256 amount) external;

    /// @notice Burn `amount` from `from`. Factory-only; no allowance check (trust boundary
    ///         is enforced by `onlyFactory`, and the factory only burns under user-initiated flows).
    function burn(address from, uint256 amount) external;
}
