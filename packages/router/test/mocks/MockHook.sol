// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";

/// @dev Records every `commitSwapIdentity` so tests can assert the commit happened before
///      the router's unlock call and that the committed user is the real msg.sender.
contract MockHook {
    struct Commit {
        address user;
        PoolId poolId;
        uint256 sequence;
    }

    Commit[] public commits;
    uint256 public commitCount;
    uint256 public lastCommitSequence;

    function commitSwapIdentity(address user, PoolId poolId) external {
        commitCount += 1;
        commits.push(Commit({user: user, poolId: poolId, sequence: commitCount}));
        lastCommitSequence = commitCount;
    }

    function commitSwapIdentityFor(
        address,
        /*caller*/
        address user,
        PoolId poolId
    )
        external
    {
        commitCount += 1;
        commits.push(Commit({user: user, poolId: poolId, sequence: commitCount}));
        lastCommitSequence = commitCount;
    }

    function lastCommitUser() external view returns (address) {
        if (commitCount == 0) return address(0);
        return commits[commitCount - 1].user;
    }
}
