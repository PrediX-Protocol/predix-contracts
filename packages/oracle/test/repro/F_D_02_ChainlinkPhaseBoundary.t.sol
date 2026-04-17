// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";

import {IChainlinkOracle} from "@predix/oracle/interfaces/IChainlinkOracle.sol";
import {ChainlinkOracle} from "@predix/oracle/adapters/ChainlinkOracle.sol";

import {MockChainlinkAggregator} from "../mocks/MockChainlinkAggregator.sol";
import {MockDiamondMarket} from "../mocks/MockDiamondMarket.sol";

/// @notice Repro for F-D-02: `resolve` must take an explicit
///         `prevRoundIdHint` and reject pairs that cross a Chainlink
///         aggregator phase boundary. Pre-fix, the implementation read
///         `roundIdHint - 1` which on proxy feeds can cross phases or
///         read round 0 of a new phase (returns zeros on AggregatorProxy,
///         silently passing the `prevUpdatedAt < snapshotAt` guard).
contract F_D_02_ChainlinkPhaseBoundary is Test {
    ChainlinkOracle internal oracleContract;
    MockChainlinkAggregator internal feed;
    MockDiamondMarket internal diamondMock;

    address internal admin = makeAddr("admin");
    address internal registrar = makeAddr("registrar");

    uint256 internal constant MARKET_ID = 7;
    uint64 internal constant SNAPSHOT_AT = 2_000_000_000;
    int256 internal constant THRESHOLD = 4000e8;

    function setUp() public {
        vm.warp(SNAPSHOT_AT - 1 days);

        diamondMock = new MockDiamondMarket();
        diamondMock.setMarket(MARKET_ID, true);

        oracleContract = new ChainlinkOracle(admin, address(0), address(diamondMock));
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

    function _phase(uint16 phaseId, uint64 aggregatorRoundId) internal pure returns (uint80) {
        return uint80((uint256(phaseId) << 64) | uint256(aggregatorRoundId));
    }

    function test_Revert_F_D_02_invalidPrevRound_equal() public {
        uint80 round = _phase(5, 10);
        vm.warp(SNAPSHOT_AT + 1);
        vm.expectRevert(IChainlinkOracle.ChainlinkOracle_InvalidPrevRound.selector);
        oracleContract.resolve(MARKET_ID, round, round);
    }

    function test_Revert_F_D_02_invalidPrevRound_greater() public {
        uint80 round = _phase(5, 10);
        uint80 later = _phase(5, 11);
        vm.warp(SNAPSHOT_AT + 1);
        vm.expectRevert(IChainlinkOracle.ChainlinkOracle_InvalidPrevRound.selector);
        oracleContract.resolve(MARKET_ID, round, later);
    }

    function test_Revert_F_D_02_phaseMismatchAcrossPhases() public {
        uint80 roundP5 = _phase(5, 1);
        uint80 roundP4 = _phase(4, 100);
        vm.warp(SNAPSHOT_AT + 1);
        vm.expectRevert(IChainlinkOracle.ChainlinkOracle_PhaseMismatch.selector);
        oracleContract.resolve(MARKET_ID, roundP5, roundP4);
    }

    function test_F_D_02_samePhaseAcceptedHappyPath() public {
        uint80 round = _phase(5, 11);
        uint80 prev = _phase(5, 10);

        feed.setRound(prev, 3900e8, SNAPSHOT_AT - 10);
        feed.setRound(round, 4100e8, SNAPSHOT_AT);

        vm.warp(SNAPSHOT_AT + 1);
        oracleContract.resolve(MARKET_ID, round, prev);
        assertTrue(oracleContract.isResolved(MARKET_ID));
        assertTrue(oracleContract.outcome(MARKET_ID));
    }
}
