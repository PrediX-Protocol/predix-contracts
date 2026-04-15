// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";

import {IChainlinkOracle} from "@predix/oracle/interfaces/IChainlinkOracle.sol";
import {ChainlinkOracle} from "@predix/oracle/adapters/ChainlinkOracle.sol";

import {MockChainlinkAggregator} from "../mocks/MockChainlinkAggregator.sol";

/// @notice Repro for FINAL-H08.
///         Pre-fix: `register` accepted unhealthy feeds and an unbounded
///         `snapshotAt`, and there was no `unregister` to recover from a
///         mis-registration before the snapshot.
///         Post-fix: register probes `latestRoundData`, captures `decimals`,
///         caps `snapshotAt` at `block.timestamp + MAX_SNAPSHOT_FUTURE`, and
///         `unregister` lets the registrar clear a market pre-snapshot.
contract FinalH08_RegisterHardening is Test {
    ChainlinkOracle internal oracleContract;
    MockChainlinkAggregator internal healthyFeed;
    MockChainlinkAggregator internal unhealthyFeed;

    address internal admin = makeAddr("admin");
    address internal registrar = makeAddr("registrar");
    address internal stranger = makeAddr("stranger");

    uint256 internal constant MARKET_ID = 101;
    uint64 internal constant SNAPSHOT_AT = 2_000_000_000;
    int256 internal constant THRESHOLD = 4000e8;

    function setUp() public {
        vm.warp(SNAPSHOT_AT - 1 days);

        oracleContract = new ChainlinkOracle(admin, address(0));
        bytes32 registrarRole = oracleContract.REGISTRAR_ROLE();
        vm.prank(admin);
        oracleContract.grantRole(registrarRole, registrar);

        healthyFeed = new MockChainlinkAggregator(8, "ETH / USD");
        healthyFeed.setAnswer(4200e8, block.timestamp);

        unhealthyFeed = new MockChainlinkAggregator(8, "Broken");
        // probe <= 0 and/or updatedAt == 0 => unhealthy
    }

    function test_Revert_Register_FeedUnhealthy_ZeroAnswer() public {
        // unhealthyFeed leaves (_answer, _updatedAt) at (0, 0) by default.
        vm.expectRevert(IChainlinkOracle.ChainlinkOracle_FeedUnhealthy.selector);
        vm.prank(registrar);
        oracleContract.register(
            MARKET_ID,
            IChainlinkOracle.Config({
                feed: address(unhealthyFeed), threshold: THRESHOLD, gte: true, snapshotAt: SNAPSHOT_AT
            })
        );
    }

    function test_Revert_Register_FeedUnhealthy_ZeroUpdatedAt() public {
        unhealthyFeed.setAnswer(4200e8, 0);
        vm.expectRevert(IChainlinkOracle.ChainlinkOracle_FeedUnhealthy.selector);
        vm.prank(registrar);
        oracleContract.register(
            MARKET_ID,
            IChainlinkOracle.Config({
                feed: address(unhealthyFeed), threshold: THRESHOLD, gte: true, snapshotAt: SNAPSHOT_AT
            })
        );
    }

    function test_Revert_Register_SnapshotTooFar() public {
        uint64 tooFar = uint64(block.timestamp + oracleContract.MAX_SNAPSHOT_FUTURE() + 1);
        vm.expectRevert(IChainlinkOracle.ChainlinkOracle_SnapshotTooFar.selector);
        vm.prank(registrar);
        oracleContract.register(
            MARKET_ID,
            IChainlinkOracle.Config({feed: address(healthyFeed), threshold: THRESHOLD, gte: true, snapshotAt: tooFar})
        );
    }

    function test_Register_SnapshotAtMaxBoundary_OK() public {
        uint64 ok = uint64(block.timestamp + oracleContract.MAX_SNAPSHOT_FUTURE());
        vm.prank(registrar);
        oracleContract.register(
            MARKET_ID,
            IChainlinkOracle.Config({feed: address(healthyFeed), threshold: THRESHOLD, gte: true, snapshotAt: ok})
        );
        assertEq(oracleContract.getConfig(MARKET_ID).snapshotAt, ok);
    }

    function test_Unregister_ClearsConfigAndEmits() public {
        vm.prank(registrar);
        oracleContract.register(
            MARKET_ID,
            IChainlinkOracle.Config({
                feed: address(healthyFeed), threshold: THRESHOLD, gte: true, snapshotAt: SNAPSHOT_AT
            })
        );

        vm.expectEmit(true, true, true, true);
        emit IChainlinkOracle.MarketUnregistered(MARKET_ID);
        vm.prank(registrar);
        oracleContract.unregister(MARKET_ID);

        assertEq(oracleContract.getConfig(MARKET_ID).feed, address(0));
    }

    function test_Revert_Unregister_NotRegistered() public {
        vm.expectRevert(IChainlinkOracle.ChainlinkOracle_NotRegistered.selector);
        vm.prank(registrar);
        oracleContract.unregister(MARKET_ID);
    }

    function test_Revert_Unregister_SnapshotPassed() public {
        vm.prank(registrar);
        oracleContract.register(
            MARKET_ID,
            IChainlinkOracle.Config({
                feed: address(healthyFeed), threshold: THRESHOLD, gte: true, snapshotAt: SNAPSHOT_AT
            })
        );
        vm.warp(SNAPSHOT_AT);
        vm.expectRevert(IChainlinkOracle.ChainlinkOracle_SnapshotPassed.selector);
        vm.prank(registrar);
        oracleContract.unregister(MARKET_ID);
    }
}
