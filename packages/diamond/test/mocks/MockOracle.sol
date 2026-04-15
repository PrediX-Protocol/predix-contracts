// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {IOracle} from "@predix/shared/interfaces/IOracle.sol";

contract MockOracle is IOracle {
    error MockOracle_NotResolved();

    mapping(uint256 => bool) internal _resolved;
    mapping(uint256 => bool) internal _outcome;

    function setResolution(uint256 marketId, bool outcome_) external {
        _resolved[marketId] = true;
        _outcome[marketId] = outcome_;
    }

    function isResolved(uint256 marketId) external view override returns (bool) {
        return _resolved[marketId];
    }

    function outcome(uint256 marketId) external view override returns (bool) {
        if (!_resolved[marketId]) revert MockOracle_NotResolved();
        return _outcome[marketId];
    }
}
