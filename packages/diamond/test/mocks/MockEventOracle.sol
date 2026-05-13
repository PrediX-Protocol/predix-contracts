// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import {IEventOracle} from "@predix/shared/interfaces/IEventOracle.sol";

contract MockEventOracle is IEventOracle {
    error MockEventOracle_NotResolved();

    mapping(uint256 => bool) internal _resolved;
    mapping(uint256 => uint256) internal _outcome;

    function setEventResolution(uint256 eventId, uint256 winningIndex) external {
        _resolved[eventId] = true;
        _outcome[eventId] = winningIndex;
    }

    function isEventResolved(uint256 eventId) external view override returns (bool) {
        return _resolved[eventId];
    }

    function eventOutcome(uint256 eventId) external view override returns (uint256) {
        if (!_resolved[eventId]) revert MockEventOracle_NotResolved();
        return _outcome[eventId];
    }
}
