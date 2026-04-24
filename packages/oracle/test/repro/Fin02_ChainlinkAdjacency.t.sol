// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";

import {IChainlinkOracle} from "@predix/oracle/interfaces/IChainlinkOracle.sol";
import {ChainlinkOracle} from "@predix/oracle/adapters/ChainlinkOracle.sol";

import {MockChainlinkAggregator} from "../mocks/MockChainlinkAggregator.sol";
import {MockDiamondMarket} from "../mocks/MockDiamondMarket.sol";

/// @notice Repro for FIN-02: `resolve` requires `prevRoundIdHint + 1 == roundIdHint`.
///         Pre-fix, the preceding-round hint only had to be earlier (and
///         within the same phase). A caller could therefore hand in any
///         stale `prev` whose `updatedAt` happened to sit before
///         `snapshotAt` — skipping intermediate rounds that might have
///         closer bracketing — and the timestamp check would still pass.
///         Adjacency forces the hint to be the literal immediate predecessor.
contract Fin02_ChainlinkAdjacency is Test {
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

    function test_Fin02_NonAdjacentRound_Reverts() public {
        uint80 prev = _phase(5, 10);
        uint80 skipped = _phase(5, 11);
        uint80 target = _phase(5, 12);

        // Seed a real intermediate round — demonstrates adjacency is
        // enforced even when the skipped round exists.
        feed.setRound(prev, 3800e8, SNAPSHOT_AT - 100);
        feed.setRound(skipped, 3900e8, SNAPSHOT_AT - 10);
        feed.setRound(target, 4100e8, SNAPSHOT_AT);

        vm.warp(SNAPSHOT_AT + 1);
        vm.expectRevert(IChainlinkOracle.ChainlinkOracle_NonAdjacentRound.selector);
        oracleContract.resolve(MARKET_ID, target, prev);
    }

    function test_Fin02_AdjacentRound_Success() public {
        uint80 prev = _phase(5, 10);
        uint80 target = _phase(5, 11);

        feed.setRound(prev, 3900e8, SNAPSHOT_AT - 10);
        feed.setRound(target, 4100e8, SNAPSHOT_AT);

        vm.warp(SNAPSHOT_AT + 1);
        oracleContract.resolve(MARKET_ID, target, prev);
        assertTrue(oracleContract.isResolved(MARKET_ID));
        assertTrue(oracleContract.outcome(MARKET_ID));
    }

    function test_Fin02_PhaseBoundary_AlreadyBlocked() public {
        // Cross-phase pair (prev=phase4,round=100 → target=phase5,round=101).
        // Even though aggregator-round-ids differ by 1, the phase-mismatch
        // guard fires first. Adjacency is never evaluated — this test
        // asserts that sequencing so a future refactor that swaps the
        // guard order still surfaces the right error to the caller.
        uint80 prev = _phase(4, 100);
        uint80 target = _phase(5, 101);

        vm.warp(SNAPSHOT_AT + 1);
        vm.expectRevert(IChainlinkOracle.ChainlinkOracle_PhaseMismatch.selector);
        oracleContract.resolve(MARKET_ID, target, prev);
    }

    function test_Fin02_SnapshotBracketed_WithAdjacency() public {
        // Adjacency alone is not sufficient — the timestamp bracket must
        // also hold. Here the adjacent `prev` has `updatedAt >= SNAPSHOT_AT`,
        // so `prevUpdatedAt >= cfg.snapshotAt` is true and
        // `WrongRoundForSnapshot` reverts. Proves adjacency passed, bracket
        // is still load-bearing.
        uint80 prev = _phase(5, 10);
        uint80 target = _phase(5, 11);

        feed.setRound(prev, 3900e8, SNAPSHOT_AT); // prev.updatedAt == snapshotAt (disqualifying)
        feed.setRound(target, 4100e8, SNAPSHOT_AT + 10);

        vm.warp(SNAPSHOT_AT + 1);
        vm.expectRevert(IChainlinkOracle.ChainlinkOracle_WrongRoundForSnapshot.selector);
        oracleContract.resolve(MARKET_ID, target, prev);
    }
}
