// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";

import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";

import {IChainlinkOracle} from "@predix/oracle/interfaces/IChainlinkOracle.sol";
import {ChainlinkOracle} from "@predix/oracle/adapters/ChainlinkOracle.sol";

import {MockChainlinkAggregator} from "../mocks/MockChainlinkAggregator.sol";

contract ChainlinkOracleTest is Test {
    ChainlinkOracle internal oracleContract;
    MockChainlinkAggregator internal feed;

    address internal admin = makeAddr("admin");
    address internal registrar = makeAddr("registrar");
    address internal stranger = makeAddr("stranger");

    uint256 internal constant MARKET_ID = 7;
    uint64 internal constant SNAPSHOT_AT = 2_000_000_000;
    int256 internal constant THRESHOLD = 4000e8;
    uint80 internal constant ROUND_ID = 1;

    function setUp() public {
        vm.warp(SNAPSHOT_AT - 1 days);

        oracleContract = new ChainlinkOracle(admin, address(0));
        bytes32 registrarRole = oracleContract.REGISTRAR_ROLE();
        vm.prank(admin);
        oracleContract.grantRole(registrarRole, registrar);

        feed = new MockChainlinkAggregator(8, "ETH / USD");
        // Healthy probe so `register` passes the feed health check.
        feed.setAnswer(1, block.timestamp);
    }

    function _register(bool gte) internal {
        vm.prank(registrar);
        oracleContract.register(
            MARKET_ID,
            IChainlinkOracle.Config({feed: address(feed), threshold: THRESHOLD, gte: gte, snapshotAt: SNAPSHOT_AT})
        );
    }

    function _warpAndSetAnswer(int256 answer) internal {
        vm.warp(SNAPSHOT_AT + 1);
        // Round ROUND_ID is the snapshot round: updatedAt == snapshotAt,
        // predecessor round 0 defaults to updatedAt = 0 (< snapshotAt).
        feed.setRound(ROUND_ID, answer, SNAPSHOT_AT);
        feed.setAnswer(answer, SNAPSHOT_AT);
    }

    // -------------------------------------------------------------------
    // Constructor
    // -------------------------------------------------------------------

    function test_Revert_Constructor_ZeroAdmin() public {
        vm.expectRevert(IChainlinkOracle.ChainlinkOracle_ZeroAdmin.selector);
        new ChainlinkOracle(address(0), address(0));
    }

    function test_Constructor_StoresSequencerFeed() public {
        address seq = makeAddr("sequencer");
        ChainlinkOracle l2Oracle = new ChainlinkOracle(admin, seq);
        assertEq(l2Oracle.sequencerUptimeFeed(), seq);
    }

    function test_Constructor_NoSequencerFeed_OnL1() public view {
        assertEq(oracleContract.sequencerUptimeFeed(), address(0));
    }

    // -------------------------------------------------------------------
    // L2 sequencer uptime
    // -------------------------------------------------------------------

    function _deployL2Oracle(MockChainlinkAggregator sequencer)
        internal
        returns (ChainlinkOracle l2Oracle, MockChainlinkAggregator priceFeed)
    {
        l2Oracle = new ChainlinkOracle(admin, address(sequencer));
        bytes32 registrarRole = l2Oracle.REGISTRAR_ROLE();
        vm.prank(admin);
        l2Oracle.grantRole(registrarRole, registrar);
        priceFeed = new MockChainlinkAggregator(8, "ETH / USD L2");
        priceFeed.setAnswer(1, block.timestamp);
    }

    function _registerOn(ChainlinkOracle target, MockChainlinkAggregator priceFeed) internal {
        vm.prank(registrar);
        target.register(
            MARKET_ID,
            IChainlinkOracle.Config({
                feed: address(priceFeed), threshold: THRESHOLD, gte: true, snapshotAt: SNAPSHOT_AT
            })
        );
    }

    function test_Resolve_L2_HappyPath_SequencerUpLongEnough() public {
        MockChainlinkAggregator sequencer = new MockChainlinkAggregator(0, "L2 Sequencer");
        sequencer.setAnswer(0, block.timestamp - 2 hours);

        (ChainlinkOracle l2Oracle, MockChainlinkAggregator priceFeed) = _deployL2Oracle(sequencer);
        _registerOn(l2Oracle, priceFeed);

        vm.warp(SNAPSHOT_AT + 1);
        priceFeed.setRound(ROUND_ID, 5000e8, SNAPSHOT_AT);
        priceFeed.setAnswer(5000e8, SNAPSHOT_AT);

        l2Oracle.resolve(MARKET_ID, ROUND_ID);
        assertTrue(l2Oracle.isResolved(MARKET_ID));
        assertTrue(l2Oracle.outcome(MARKET_ID));
    }

    function test_Revert_Resolve_L2_SequencerDown() public {
        MockChainlinkAggregator sequencer = new MockChainlinkAggregator(0, "L2 Sequencer");
        sequencer.setAnswer(1, block.timestamp - 2 hours);

        (ChainlinkOracle l2Oracle, MockChainlinkAggregator priceFeed) = _deployL2Oracle(sequencer);
        _registerOn(l2Oracle, priceFeed);

        vm.warp(SNAPSHOT_AT + 1);
        priceFeed.setRound(ROUND_ID, 5000e8, SNAPSHOT_AT);
        priceFeed.setAnswer(5000e8, SNAPSHOT_AT);

        vm.expectRevert(IChainlinkOracle.ChainlinkOracle_SequencerDown.selector);
        l2Oracle.resolve(MARKET_ID, ROUND_ID);
    }

    function test_Revert_Resolve_L2_SequencerGracePeriodNotOver() public {
        MockChainlinkAggregator sequencer = new MockChainlinkAggregator(0, "L2 Sequencer");
        // sequencer just came back up 30 minutes ago — under the 1h grace period.
        sequencer.setAnswer(0, SNAPSHOT_AT - 30 minutes);

        (ChainlinkOracle l2Oracle, MockChainlinkAggregator priceFeed) = _deployL2Oracle(sequencer);
        _registerOn(l2Oracle, priceFeed);

        vm.warp(SNAPSHOT_AT + 1);
        priceFeed.setRound(ROUND_ID, 5000e8, SNAPSHOT_AT);
        priceFeed.setAnswer(5000e8, SNAPSHOT_AT);

        vm.expectRevert(IChainlinkOracle.ChainlinkOracle_SequencerGracePeriodNotOver.selector);
        l2Oracle.resolve(MARKET_ID, ROUND_ID);
    }

    // -------------------------------------------------------------------
    // register
    // -------------------------------------------------------------------

    function test_Register_HappyPath_StoresConfig() public {
        _register(true);

        IChainlinkOracle.Config memory cfg = oracleContract.getConfig(MARKET_ID);
        assertEq(cfg.feed, address(feed));
        assertEq(cfg.threshold, THRESHOLD);
        assertTrue(cfg.gte);
        assertEq(cfg.snapshotAt, SNAPSHOT_AT);
    }

    function test_Register_EmitsEvent() public {
        vm.expectEmit(true, true, true, true);
        emit IChainlinkOracle.MarketRegistered(MARKET_ID, address(feed), THRESHOLD, true, SNAPSHOT_AT);
        _register(true);
    }

    function test_Revert_Register_NotRegistrar() public {
        bytes32 role = oracleContract.REGISTRAR_ROLE();
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, stranger, role)
        );
        vm.prank(stranger);
        oracleContract.register(
            MARKET_ID,
            IChainlinkOracle.Config({feed: address(feed), threshold: THRESHOLD, gte: true, snapshotAt: SNAPSHOT_AT})
        );
    }

    function test_Revert_Register_AlreadyRegistered() public {
        _register(true);
        vm.expectRevert(IChainlinkOracle.ChainlinkOracle_AlreadyRegistered.selector);
        _register(false);
    }

    function test_Revert_Register_ZeroFeed() public {
        vm.expectRevert(IChainlinkOracle.ChainlinkOracle_ZeroFeed.selector);
        vm.prank(registrar);
        oracleContract.register(
            MARKET_ID,
            IChainlinkOracle.Config({feed: address(0), threshold: THRESHOLD, gte: true, snapshotAt: SNAPSHOT_AT})
        );
    }

    function test_Revert_Register_PastSnapshot() public {
        uint64 past = uint64(block.timestamp);
        vm.expectRevert(IChainlinkOracle.ChainlinkOracle_PastSnapshot.selector);
        vm.prank(registrar);
        oracleContract.register(
            MARKET_ID, IChainlinkOracle.Config({feed: address(feed), threshold: THRESHOLD, gte: true, snapshotAt: past})
        );
    }

    // -------------------------------------------------------------------
    // resolve — happy paths
    // -------------------------------------------------------------------

    function test_Resolve_GtePath_YesWins() public {
        _register(true);
        _warpAndSetAnswer(4001e8);

        vm.expectEmit(true, true, true, true);
        emit IChainlinkOracle.MarketResolved(MARKET_ID, 4001e8, true);
        oracleContract.resolve(MARKET_ID, ROUND_ID);

        assertTrue(oracleContract.isResolved(MARKET_ID));
        assertTrue(oracleContract.outcome(MARKET_ID));
    }

    function test_Resolve_GtePath_NoWins() public {
        _register(true);
        _warpAndSetAnswer(3999e8);
        oracleContract.resolve(MARKET_ID, ROUND_ID);
        assertFalse(oracleContract.outcome(MARKET_ID));
    }

    function test_Resolve_LtePath_YesWins() public {
        _register(false);
        _warpAndSetAnswer(3999e8);
        oracleContract.resolve(MARKET_ID, ROUND_ID);
        assertTrue(oracleContract.outcome(MARKET_ID));
    }

    function test_Resolve_LtePath_NoWins() public {
        _register(false);
        _warpAndSetAnswer(4001e8);
        oracleContract.resolve(MARKET_ID, ROUND_ID);
        assertFalse(oracleContract.outcome(MARKET_ID));
    }

    function test_Resolve_ExactThreshold_GteYes() public {
        _register(true);
        _warpAndSetAnswer(THRESHOLD);
        oracleContract.resolve(MARKET_ID, ROUND_ID);
        assertTrue(oracleContract.outcome(MARKET_ID));
    }

    function test_Resolve_PermissionlessFromAnyCaller() public {
        _register(true);
        _warpAndSetAnswer(4500e8);
        vm.prank(stranger);
        oracleContract.resolve(MARKET_ID, ROUND_ID);
        assertTrue(oracleContract.isResolved(MARKET_ID));
    }

    function test_IsResolved_TrueAfterResolve() public {
        _register(true);
        _warpAndSetAnswer(4500e8);
        assertFalse(oracleContract.isResolved(MARKET_ID));
        oracleContract.resolve(MARKET_ID, ROUND_ID);
        assertTrue(oracleContract.isResolved(MARKET_ID));
    }

    function test_Outcome_ReturnsStored() public {
        _register(true);
        _warpAndSetAnswer(4500e8);
        oracleContract.resolve(MARKET_ID, ROUND_ID);
        assertTrue(oracleContract.outcome(MARKET_ID));
    }

    // -------------------------------------------------------------------
    // resolve — reverts
    // -------------------------------------------------------------------

    function test_Revert_Resolve_NotRegistered() public {
        vm.expectRevert(IChainlinkOracle.ChainlinkOracle_NotRegistered.selector);
        oracleContract.resolve(MARKET_ID, ROUND_ID);
    }

    function test_Revert_Resolve_AlreadyResolved() public {
        _register(true);
        _warpAndSetAnswer(4500e8);
        oracleContract.resolve(MARKET_ID, ROUND_ID);

        vm.expectRevert(IChainlinkOracle.ChainlinkOracle_AlreadyResolved.selector);
        oracleContract.resolve(MARKET_ID, ROUND_ID);
    }

    function test_Revert_Resolve_BeforeSnapshot() public {
        _register(true);
        feed.setAnswer(4500e8, block.timestamp);
        vm.expectRevert(IChainlinkOracle.ChainlinkOracle_BeforeSnapshot.selector);
        oracleContract.resolve(MARKET_ID, ROUND_ID);
    }

    function test_Revert_Resolve_WrongRoundForSnapshot_HintTooEarly() public {
        _register(true);
        // Hinted round updatedAt is strictly before snapshotAt — wrong round.
        feed.setRound(ROUND_ID, 4500e8, SNAPSHOT_AT - 1);
        vm.warp(SNAPSHOT_AT + 1);
        vm.expectRevert(IChainlinkOracle.ChainlinkOracle_WrongRoundForSnapshot.selector);
        oracleContract.resolve(MARKET_ID, ROUND_ID);
    }

    function test_Revert_Resolve_WrongRoundForSnapshot_HintTooLate() public {
        _register(true);
        // Previous round is already >= snapshotAt, so the hinted round is not
        // the snapshot round.
        feed.setRound(ROUND_ID, 4500e8, SNAPSHOT_AT);
        feed.setRound(ROUND_ID + 1, 4600e8, SNAPSHOT_AT + 10);
        vm.warp(SNAPSHOT_AT + 1);
        vm.expectRevert(IChainlinkOracle.ChainlinkOracle_WrongRoundForSnapshot.selector);
        oracleContract.resolve(MARKET_ID, ROUND_ID + 1);
    }

    function test_Revert_Resolve_InvalidPrice_Zero() public {
        _register(true);
        _warpAndSetAnswer(0);
        vm.expectRevert(IChainlinkOracle.ChainlinkOracle_InvalidPrice.selector);
        oracleContract.resolve(MARKET_ID, ROUND_ID);
    }

    function test_Revert_Resolve_InvalidPrice_Negative() public {
        _register(true);
        _warpAndSetAnswer(-1);
        vm.expectRevert(IChainlinkOracle.ChainlinkOracle_InvalidPrice.selector);
        oracleContract.resolve(MARKET_ID, ROUND_ID);
    }

    // -------------------------------------------------------------------
    // outcome() before resolve
    // -------------------------------------------------------------------

    function test_Revert_Outcome_NotRegistered() public {
        vm.expectRevert(IChainlinkOracle.ChainlinkOracle_NotRegistered.selector);
        oracleContract.outcome(MARKET_ID);
    }

    function test_Revert_Outcome_NotResolvedYet() public {
        _register(true);
        vm.expectRevert(IChainlinkOracle.ChainlinkOracle_NotResolvedYet.selector);
        oracleContract.outcome(MARKET_ID);
    }

    // -------------------------------------------------------------------
    // Fuzz
    // -------------------------------------------------------------------

    function testFuzz_Resolve_ThresholdComparison(int256 threshold, int256 price, bool gte) public {
        price = bound(price, 1, type(int128).max);
        threshold = bound(threshold, 1, type(int128).max);

        vm.prank(registrar);
        oracleContract.register(
            MARKET_ID,
            IChainlinkOracle.Config({feed: address(feed), threshold: threshold, gte: gte, snapshotAt: SNAPSHOT_AT})
        );

        vm.warp(SNAPSHOT_AT + 1);
        feed.setRound(ROUND_ID, price, SNAPSHOT_AT);

        oracleContract.resolve(MARKET_ID, ROUND_ID);

        bool expected = gte ? price >= threshold : price <= threshold;
        assertEq(oracleContract.outcome(MARKET_ID), expected);
    }
}
