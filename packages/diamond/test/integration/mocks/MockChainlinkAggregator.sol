// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {AggregatorV3Interface} from "@chainlink/contracts/src/v0.8/shared/interfaces/AggregatorV3Interface.sol";

/// @notice Test double for a Chainlink AggregatorV3 feed used by the diamond
///         oracle integration test.
/// @dev Supports multi-round state so tests can exercise the round-pinning
///      logic in `ChainlinkOracle.resolve(marketId, roundIdHint)`. Each call
///      to `setAnswer(answer, updatedAt)` appends a new round and advances
///      `latestRound`. Tests that only need a single round can call
///      `setAnswer` once and treat `latestRound == 1`.
contract MockChainlinkAggregator is AggregatorV3Interface {
    uint8 private immutable _decimals;
    string private _description;

    mapping(uint80 roundId => int256) private _answers;
    mapping(uint80 roundId => uint256) private _updatedAts;
    uint80 private _latestRound;

    constructor(uint8 decimals_, string memory description_) {
        _decimals = decimals_;
        _description = description_;
    }

    /// @notice Append a new round with the supplied answer and `updatedAt`.
    ///         Advances `latestRound` by one on every call.
    function setAnswer(int256 answer_, uint256 updatedAt_) external {
        _latestRound++;
        _answers[_latestRound] = answer_;
        _updatedAts[_latestRound] = updatedAt_;
    }

    function latestRound() external view returns (uint80) {
        return _latestRound;
    }

    function decimals() external view returns (uint8) {
        return _decimals;
    }

    function description() external view returns (string memory) {
        return _description;
    }

    function version() external pure returns (uint256) {
        return 1;
    }

    function getRoundData(uint80 roundId_)
        external
        view
        returns (uint80, int256, uint256, uint256, uint80)
    {
        return (roundId_, _answers[roundId_], _updatedAts[roundId_], _updatedAts[roundId_], roundId_);
    }

    function latestRoundData() external view returns (uint80, int256, uint256, uint256, uint80) {
        return (
            _latestRound,
            _answers[_latestRound],
            _updatedAts[_latestRound],
            _updatedAts[_latestRound],
            _latestRound
        );
    }
}
