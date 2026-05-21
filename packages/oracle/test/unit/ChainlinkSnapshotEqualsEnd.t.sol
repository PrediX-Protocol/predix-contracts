// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import {Test} from "forge-std/Test.sol";

import {IChainlinkOracle} from "@predix/oracle/interfaces/IChainlinkOracle.sol";
import {ChainlinkOracle} from "@predix/oracle/adapters/ChainlinkOracle.sol";

import {MockChainlinkAggregator} from "../mocks/MockChainlinkAggregator.sol";
import {MockDiamondMarket} from "../mocks/MockDiamondMarket.sol";

/// @notice Pins the `snapshotAt == endTime` register guard. A snapshot before
///         endTime would fix the outcome while the market still trades (trading
///         freezes only at endTime), opening a risk-free informed-trading window.
contract ChainlinkSnapshotEqualsEndTest is Test {
    ChainlinkOracle internal oracle;
    MockChainlinkAggregator internal feed;
    MockDiamondMarket internal diamondMock;

    address internal admin = makeAddr("admin");
    address internal registrar = makeAddr("registrar");

    uint256 internal constant MARKET_ID = 7;
    uint64 internal endTime;

    function setUp() public {
        vm.warp(1_000_000_000);
        endTime = uint64(block.timestamp + 30 days);

        diamondMock = new MockDiamondMarket();
        diamondMock.setMarketWithEndTime(MARKET_ID, true, endTime);

        oracle = new ChainlinkOracle(admin, address(0), address(diamondMock));
        bytes32 registrarRole = oracle.REGISTRAR_ROLE();
        vm.prank(admin);
        oracle.grantRole(registrarRole, registrar);

        feed = new MockChainlinkAggregator(8, "ETH / USD");
        feed.setAnswer(1, block.timestamp);
    }

    function _cfg(uint64 snapshotAt) internal view returns (IChainlinkOracle.Config memory) {
        return IChainlinkOracle.Config({feed: address(feed), threshold: 4000e8, gte: true, snapshotAt: snapshotAt});
    }

    function test_Register_SnapshotEqualsEndTime_Succeeds() public {
        vm.prank(registrar);
        oracle.register(MARKET_ID, _cfg(endTime));
        assertEq(oracle.getConfig(MARKET_ID).snapshotAt, endTime);
    }

    function test_Revert_Register_SnapshotBeforeEndTime() public {
        vm.prank(registrar);
        vm.expectRevert(IChainlinkOracle.ChainlinkOracle_SnapshotNotMarketEnd.selector);
        oracle.register(MARKET_ID, _cfg(endTime - 1));
    }

    function test_Revert_Register_SnapshotAfterEndTime() public {
        // Still within (now, now + MAX_SNAPSHOT_FUTURE], so the equality check is
        // what rejects it — not the bound checks that run earlier.
        vm.prank(registrar);
        vm.expectRevert(IChainlinkOracle.ChainlinkOracle_SnapshotNotMarketEnd.selector);
        oracle.register(MARKET_ID, _cfg(endTime + 1));
    }
}
