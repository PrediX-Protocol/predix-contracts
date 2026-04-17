// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {AggregatorV3Interface} from "@chainlink/contracts/src/v0.8/shared/interfaces/AggregatorV3Interface.sol";

/// @notice Minimal Chainlink aggregator double used by the Phase 7 e2e
///         regression-guard suite. Matches the shape oracle-package mocks
///         follow but is defined locally so the diamond package does not
///         reach into another package's `test/mocks/` (per SC/CLAUDE.md §7.3).
contract MockE2EAggregator is AggregatorV3Interface {
    uint8 private immutable _decimals;
    int256 public latestAnswer;
    uint256 public latestUpdatedAt;
    uint80 public latestRoundId;
    uint256 public latestStartedAt;

    constructor(uint8 dec, int256 answer, uint256 updatedAt) {
        _decimals = dec;
        latestAnswer = answer;
        latestUpdatedAt = updatedAt;
        latestRoundId = 1;
        latestStartedAt = updatedAt;
    }

    function setStartedAt(uint256 startedAt_) external {
        latestStartedAt = startedAt_;
    }

    function setRound(uint80 roundId_, int256 answer, uint256 updatedAt) external {
        latestRoundId = roundId_;
        latestAnswer = answer;
        latestUpdatedAt = updatedAt;
    }

    function decimals() external view override returns (uint8) {
        return _decimals;
    }

    function description() external pure override returns (string memory) {
        return "MockE2EAggregator";
    }

    function version() external pure override returns (uint256) {
        return 0;
    }

    function getRoundData(uint80 roundId_) external view override returns (uint80, int256, uint256, uint256, uint80) {
        return (roundId_, latestAnswer, latestUpdatedAt, latestUpdatedAt, roundId_);
    }

    function latestRoundData() external view override returns (uint80, int256, uint256, uint256, uint80) {
        return (latestRoundId, latestAnswer, latestStartedAt, latestUpdatedAt, latestRoundId);
    }
}
