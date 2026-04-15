// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";

import {IChainlinkOracle} from "@predix/oracle/interfaces/IChainlinkOracle.sol";
import {ChainlinkOracle} from "@predix/oracle/adapters/ChainlinkOracle.sol";

import {MockChainlinkAggregator} from "../mocks/MockChainlinkAggregator.sol";

/// @notice Repro for FINAL-H07.
///         Pre-fix: `ChainlinkOracle.resolve(uint256)` reads `latestRoundData`
///         and is bounded only by a 1h staleness window — within that window
///         any caller can choose the most favourable heartbeat.
///         Post-fix: `resolve(uint256, uint80 roundIdHint)` binds the answer
///         to the specific round that *contains* `snapshotAt`. Callers cannot
///         swap a later heartbeat in.
contract FinalH07_ResolveMevWindow is Test {
    ChainlinkOracle internal oracleContract;
    MockChainlinkAggregator internal feed;

    address internal admin = makeAddr("admin");
    address internal registrar = makeAddr("registrar");

    uint256 internal constant MARKET_ID = 42;
    uint64 internal constant SNAPSHOT_AT = 2_000_000_000;
    int256 internal constant THRESHOLD = 4000e8;

    function setUp() public {
        vm.warp(SNAPSHOT_AT - 1 days);

        oracleContract = new ChainlinkOracle(admin, address(0));
        bytes32 registrarRole = oracleContract.REGISTRAR_ROLE();
        vm.prank(admin);
        oracleContract.grantRole(registrarRole, registrar);

        feed = new MockChainlinkAggregator(8, "ETH / USD");
        feed.setAnswer(1, block.timestamp);

        vm.prank(registrar);
        oracleContract.register(
            MARKET_ID,
            IChainlinkOracle.Config({feed: address(feed), threshold: THRESHOLD, gte: true, snapshotAt: SNAPSHOT_AT})
        );
    }

    /// @notice Post-fix: resolving with the snapshot round binds outcome to
    ///         the round containing `snapshotAt`, independent of later rounds.
    function test_Resolve_BindsToSnapshotRound() public {
        // Round 10: answer BELOW threshold just before snapshotAt (NO)
        feed.setRound(10, 3900e8, SNAPSHOT_AT - 10);
        // Round 11: answer ABOVE threshold strictly after snapshotAt (YES)
        feed.setRound(11, 4100e8, SNAPSHOT_AT + 10);

        vm.warp(SNAPSHOT_AT + 30 minutes);

        // Round 11 is the first round whose updatedAt is >= snapshotAt.
        oracleContract.resolve(MARKET_ID, 11);
        assertTrue(oracleContract.isResolved(MARKET_ID));
        assertTrue(oracleContract.outcome(MARKET_ID), "round 11 > threshold => YES");
    }

    /// @notice Post-fix: a hint that points at a round *before* snapshotAt
    ///         must be rejected with `ChainlinkOracle_WrongRoundForSnapshot`.
    function test_Revert_Resolve_HintTooEarly() public {
        feed.setRound(10, 3900e8, SNAPSHOT_AT - 10);
        feed.setRound(11, 4100e8, SNAPSHOT_AT + 10);

        vm.warp(SNAPSHOT_AT + 30 minutes);

        vm.expectRevert(IChainlinkOracle.ChainlinkOracle_WrongRoundForSnapshot.selector);
        oracleContract.resolve(MARKET_ID, 10);
    }

    /// @notice Post-fix: a hint whose previous round is already past
    ///         snapshotAt — i.e. the hinted round is not the snapshot round —
    ///         must also revert.
    function test_Revert_Resolve_HintTooLate() public {
        feed.setRound(10, 3900e8, SNAPSHOT_AT - 10);
        feed.setRound(11, 4100e8, SNAPSHOT_AT + 10);
        feed.setRound(12, 4500e8, SNAPSHOT_AT + 20);

        vm.warp(SNAPSHOT_AT + 30 minutes);

        vm.expectRevert(IChainlinkOracle.ChainlinkOracle_WrongRoundForSnapshot.selector);
        oracleContract.resolve(MARKET_ID, 12);
    }
}
