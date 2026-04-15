// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {AggregatorV3Interface} from "@chainlink/contracts/src/v0.8/shared/interfaces/AggregatorV3Interface.sol";

/// @notice Test double for a Chainlink AggregatorV3 feed. Supports two modes:
///         (1) simple `setAnswer(answer, updatedAt)` mirrors the same data on
///         every round id via `latestRoundData` / `getRoundData`; (2)
///         `setRound(roundId, answer, updatedAt)` lets a test register a
///         historical round that can be played back through `getRoundData`.
///         `setLatestRound(roundId)` selects which stored round is returned
///         by `latestRoundData`.
contract MockChainlinkAggregator is AggregatorV3Interface {
    struct Round {
        int256 answer;
        uint256 updatedAt;
        bool set;
    }

    uint8 private immutable _decimals;
    string private _description;

    int256 private _answer;
    uint256 private _updatedAt;

    uint80 private _latestRoundId;
    mapping(uint80 => Round) private _rounds;

    constructor(uint8 decimals_, string memory description_) {
        _decimals = decimals_;
        _description = description_;
    }

    function setAnswer(int256 answer_, uint256 updatedAt_) external {
        _answer = answer_;
        _updatedAt = updatedAt_;
    }

    function setRound(uint80 roundId_, int256 answer_, uint256 updatedAt_) external {
        _rounds[roundId_] = Round({answer: answer_, updatedAt: updatedAt_, set: true});
    }

    function setLatestRound(uint80 roundId_) external {
        _latestRoundId = roundId_;
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
        returns (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound)
    {
        Round memory r = _rounds[roundId_];
        if (r.set) {
            return (roundId_, r.answer, r.updatedAt, r.updatedAt, roundId_);
        }
        // Unset rounds return zeros so callers checking `updatedAt` bounds
        // against an adjacent round see a truthful "no data" sentinel.
        return (roundId_, 0, 0, 0, roundId_);
    }

    function latestRoundData()
        external
        view
        returns (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound)
    {
        if (_latestRoundId != 0) {
            Round memory r = _rounds[_latestRoundId];
            if (r.set) {
                return (_latestRoundId, r.answer, r.updatedAt, r.updatedAt, _latestRoundId);
            }
        }
        return (1, _answer, _updatedAt, _updatedAt, 1);
    }
}
