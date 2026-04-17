// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";

import {IChainlinkOracle} from "@predix/oracle/interfaces/IChainlinkOracle.sol";
import {ChainlinkOracle} from "@predix/oracle/adapters/ChainlinkOracle.sol";

import {MockChainlinkAggregator} from "../mocks/MockChainlinkAggregator.sol";
import {MockDiamondMarket} from "../mocks/MockDiamondMarket.sol";

/// @notice Repro for NEW-M8: when the sequencer uptime feed has not emitted
///         any round yet (fresh L2 bootstrap), `latestRoundData().startedAt`
///         is zero. Pre-fix, the oracle computed `block.timestamp - 0` which
///         trivially exceeded SEQUENCER_GRACE_PERIOD, so the guard passed
///         and `resolve` proceeded under a sequencer with no verified uptime.
contract NEW_M8_SequencerRoundInvalid is Test {
    address internal admin = makeAddr("admin");
    address internal registrar = makeAddr("registrar");

    uint256 internal constant MARKET_ID = 7;
    uint64 internal constant SNAPSHOT_AT = 2_000_000_000;
    int256 internal constant THRESHOLD = 4000e8;
    uint80 internal constant ROUND_ID = 1;

    function test_Revert_NEW_M8_uninitializedSequencerRejected() public {
        vm.warp(SNAPSHOT_AT - 1 days);

        // Sequencer feed freshly deployed — NO setAnswer call, so latestRoundData
        // returns startedAt = 0.
        MockChainlinkAggregator sequencer = new MockChainlinkAggregator(0, "L2 Sequencer");

        MockDiamondMarket diamondMock = new MockDiamondMarket();
        diamondMock.setMarket(MARKET_ID, true);
        ChainlinkOracle l2Oracle = new ChainlinkOracle(admin, address(sequencer), address(diamondMock));
        bytes32 registrarRole = l2Oracle.REGISTRAR_ROLE();
        vm.prank(admin);
        l2Oracle.grantRole(registrarRole, registrar);

        MockChainlinkAggregator priceFeed = new MockChainlinkAggregator(8, "ETH / USD");
        priceFeed.setAnswer(1, block.timestamp);

        vm.prank(registrar);
        l2Oracle.register(
            MARKET_ID,
            IChainlinkOracle.Config({
                feed: address(priceFeed), threshold: THRESHOLD, gte: true, snapshotAt: SNAPSHOT_AT
            })
        );

        vm.warp(SNAPSHOT_AT + 1);
        priceFeed.setRound(ROUND_ID, 5000e8, SNAPSHOT_AT);

        vm.expectRevert(IChainlinkOracle.ChainlinkOracle_SequencerRoundInvalid.selector);
        l2Oracle.resolve(MARKET_ID, ROUND_ID);
    }

    function test_NEW_M8_initializedSequencerStillWorks() public {
        // Sanity: sequencer that has emitted at least one round still passes.
        vm.warp(SNAPSHOT_AT - 1 days);

        MockChainlinkAggregator sequencer = new MockChainlinkAggregator(0, "L2 Sequencer");
        sequencer.setAnswer(0, block.timestamp - 2 hours); // up for 2h, past 1h grace

        MockDiamondMarket diamondMock = new MockDiamondMarket();
        diamondMock.setMarket(MARKET_ID, true);
        ChainlinkOracle l2Oracle = new ChainlinkOracle(admin, address(sequencer), address(diamondMock));
        bytes32 registrarRole = l2Oracle.REGISTRAR_ROLE();
        vm.prank(admin);
        l2Oracle.grantRole(registrarRole, registrar);

        MockChainlinkAggregator priceFeed = new MockChainlinkAggregator(8, "ETH / USD");
        priceFeed.setAnswer(1, block.timestamp);

        vm.prank(registrar);
        l2Oracle.register(
            MARKET_ID,
            IChainlinkOracle.Config({
                feed: address(priceFeed), threshold: THRESHOLD, gte: true, snapshotAt: SNAPSHOT_AT
            })
        );

        vm.warp(SNAPSHOT_AT + 1);
        priceFeed.setRound(ROUND_ID, 5000e8, SNAPSHOT_AT);
        priceFeed.setAnswer(5000e8, SNAPSHOT_AT);

        l2Oracle.resolve(MARKET_ID, ROUND_ID);
        assertTrue(l2Oracle.isResolved(MARKET_ID));
    }
}
