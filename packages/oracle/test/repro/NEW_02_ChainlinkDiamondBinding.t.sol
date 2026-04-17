// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";

import {IChainlinkOracle} from "@predix/oracle/interfaces/IChainlinkOracle.sol";
import {ChainlinkOracle} from "@predix/oracle/adapters/ChainlinkOracle.sol";

import {MockChainlinkAggregator} from "../mocks/MockChainlinkAggregator.sol";
import {MockDiamondMarket} from "../mocks/MockDiamondMarket.sol";

/// @notice Repro for NEW-02: ChainlinkOracle must be bound to a diamond at
///         construction, and `register` must reject marketIds the bound
///         diamond does not recognize. Without this, an adapter reused across
///         deployments could suffer cross-diamond marketId collisions.
contract NEW_02_ChainlinkDiamondBinding is Test {
    address internal admin = makeAddr("admin");
    address internal registrar = makeAddr("registrar");

    uint64 internal constant SNAPSHOT_AT = 2_000_000_000;
    int256 internal constant THRESHOLD = 4000e8;
    uint256 internal constant KNOWN_MARKET = 7;
    uint256 internal constant UNKNOWN_MARKET = 999;

    ChainlinkOracle internal oracleContract;
    MockDiamondMarket internal diamondMock;
    MockChainlinkAggregator internal feed;

    function setUp() public {
        vm.warp(SNAPSHOT_AT - 1 days);

        diamondMock = new MockDiamondMarket();
        diamondMock.setMarket(KNOWN_MARKET, true);

        oracleContract = new ChainlinkOracle(admin, address(0), address(diamondMock));
        bytes32 registrarRole = oracleContract.REGISTRAR_ROLE();
        vm.prank(admin);
        oracleContract.grantRole(registrarRole, registrar);

        feed = new MockChainlinkAggregator(8, "ETH / USD");
        feed.setAnswer(1, block.timestamp);
    }

    function test_Revert_NEW_02_constructorZeroDiamond() public {
        vm.expectRevert(IChainlinkOracle.ChainlinkOracle_ZeroDiamond.selector);
        new ChainlinkOracle(admin, address(0), address(0));
    }

    function test_NEW_02_diamondGetterExposesBoundAddress() public view {
        assertEq(oracleContract.diamond(), address(diamondMock), "diamond bound");
    }

    function test_Revert_NEW_02_registerRejectsUnknownMarketId() public {
        vm.prank(registrar);
        vm.expectRevert(IChainlinkOracle.ChainlinkOracle_MarketNotFound.selector);
        oracleContract.register(
            UNKNOWN_MARKET,
            IChainlinkOracle.Config({feed: address(feed), threshold: THRESHOLD, gte: true, snapshotAt: SNAPSHOT_AT})
        );
    }

    function test_NEW_02_registerAcceptsKnownMarketId() public {
        vm.prank(registrar);
        oracleContract.register(
            KNOWN_MARKET,
            IChainlinkOracle.Config({feed: address(feed), threshold: THRESHOLD, gte: true, snapshotAt: SNAPSHOT_AT})
        );
        // Sanity: config persisted.
        assertEq(oracleContract.getConfig(KNOWN_MARKET).feed, address(feed));
    }
}
