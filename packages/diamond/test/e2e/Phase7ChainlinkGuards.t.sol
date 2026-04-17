// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {IMarketFacet} from "@predix/shared/interfaces/IMarketFacet.sol";
import {ChainlinkOracle} from "@predix/oracle/adapters/ChainlinkOracle.sol";
import {IChainlinkOracle} from "@predix/oracle/interfaces/IChainlinkOracle.sol";

import {Phase7ForkBase} from "./Phase7ForkBase.t.sol";
import {MockE2EAggregator} from "./mocks/MockE2EAggregator.sol";

/// @notice Regression guards for the four Chainlink-specific fixes (B3 NEW-02
///         diamond binding, B3 defensive snapshotAfterEndTime, C1 F-D-02
///         phase + prev-round hints, B5 NEW-M8 sequencer startedAt). Phase 7
///         testnet shipped with `CHAINLINK_ENABLED=false` so no production
///         ChainlinkOracle exists on chain — we deploy fresh in each test
///         bound to the live diamond so the NEW-02 diamond read is exercised
///         against real on-chain market state.
contract Phase7ChainlinkGuards is Phase7ForkBase {
    IMarketFacet internal market;

    address internal registrar = makeAddr("chainlink_registrar");

    function setUp() public virtual override {
        super.setUp();
        market = IMarketFacet(DIAMOND);
    }

    // -----------------------------------------------------------------
    // Helpers
    // -----------------------------------------------------------------

    function _deployOracle(address sequencerFeed) internal returns (ChainlinkOracle) {
        ChainlinkOracle oracle = new ChainlinkOracle(address(this), sequencerFeed, DIAMOND);
        oracle.grantRole(oracle.REGISTRAR_ROLE(), registrar);
        return oracle;
    }

    function _createLiveMarket(uint256 endOffset) internal returns (uint256) {
        vm.prank(MULTISIG);
        return market.createMarket("chainlink guard market", block.timestamp + endOffset, MANUAL_ORACLE);
    }

    function _baseConfig(address feed, uint64 snapshotAt) internal pure returns (IChainlinkOracle.Config memory) {
        return IChainlinkOracle.Config({feed: feed, threshold: 1000e8, gte: true, snapshotAt: snapshotAt});
    }

    // =================================================================
    // NEW-02 defensive — snapshotAt > market.endTime rejected at register
    // =================================================================

    function test_NEW_02_Register_SnapshotAfterMarketEnd_Reverts() public {
        ChainlinkOracle oracle = _deployOracle(address(0));
        uint256 marketId = _createLiveMarket(1 hours);

        // snapshotAt = endTime + 1 — brickable config the defensive check rejects.
        IMarketFacet.MarketView memory mkt = market.getMarket(marketId);
        MockE2EAggregator feed = new MockE2EAggregator(8, 1000e8, block.timestamp);

        IChainlinkOracle.Config memory cfg = _baseConfig(address(feed), uint64(mkt.endTime) + 1);

        vm.prank(registrar);
        vm.expectRevert(IChainlinkOracle.ChainlinkOracle_SnapshotAfterMarketEnd.selector);
        oracle.register(marketId, cfg);
    }

    // =================================================================
    // F-D-02 — resolve rejects prevRoundIdHint >= roundIdHint
    // =================================================================

    function test_F_D_02_Resolve_InvalidPrevRound_Reverts() public {
        ChainlinkOracle oracle = _deployOracle(address(0));
        uint256 marketId = _createLiveMarket(1 hours);

        MockE2EAggregator feed = new MockE2EAggregator(8, 1000e8, block.timestamp);
        uint64 snapshotAt = uint64(block.timestamp + 10 minutes);

        vm.prank(registrar);
        oracle.register(marketId, _baseConfig(address(feed), snapshotAt));

        vm.warp(snapshotAt + 1);

        // prev == hint triggers the strict inequality guard.
        uint80 roundHint = 42;
        uint80 prevHint = 42;
        vm.expectRevert(IChainlinkOracle.ChainlinkOracle_InvalidPrevRound.selector);
        oracle.resolve(marketId, roundHint, prevHint);
    }

    // =================================================================
    // F-D-02 — resolve rejects cross-phase round pair
    // =================================================================

    function test_F_D_02_Resolve_PhaseMismatch_Reverts() public {
        ChainlinkOracle oracle = _deployOracle(address(0));
        uint256 marketId = _createLiveMarket(1 hours);

        MockE2EAggregator feed = new MockE2EAggregator(8, 1000e8, block.timestamp);
        uint64 snapshotAt = uint64(block.timestamp + 10 minutes);

        vm.prank(registrar);
        oracle.register(marketId, _baseConfig(address(feed), snapshotAt));

        vm.warp(snapshotAt + 1);

        // Encode phase in top 16 bits; make hint and prev come from different phases.
        uint80 roundHint = uint80((uint256(2) << 64) | uint256(10));
        uint80 prevHint = uint80((uint256(1) << 64) | uint256(5));

        vm.expectRevert(IChainlinkOracle.ChainlinkOracle_PhaseMismatch.selector);
        oracle.resolve(marketId, roundHint, prevHint);
    }

    // =================================================================
    // NEW-M8 — sequencer feed with startedAt == 0 rejected
    // =================================================================

    function test_NEW_M8_Resolve_SequencerStartedAtZero_Reverts() public {
        // Sequencer feed with startedAt == 0 models a freshly-deployed L2
        // uptime feed that has never emitted a round.
        MockE2EAggregator sequencer = new MockE2EAggregator(0, 0, 0);
        sequencer.setStartedAt(0);

        ChainlinkOracle oracle = _deployOracle(address(sequencer));
        uint256 marketId = _createLiveMarket(1 hours);

        MockE2EAggregator feed = new MockE2EAggregator(8, 1000e8, block.timestamp);
        uint64 snapshotAt = uint64(block.timestamp + 10 minutes);

        vm.prank(registrar);
        oracle.register(marketId, _baseConfig(address(feed), snapshotAt));

        vm.warp(snapshotAt + 1);

        // Cross the phase + prev hints so we bypass earlier guards and reach
        // the sequencer check; both hints in phase 1.
        uint80 roundHint = uint80((uint256(1) << 64) | uint256(10));
        uint80 prevHint = uint80((uint256(1) << 64) | uint256(5));

        vm.expectRevert(IChainlinkOracle.ChainlinkOracle_SequencerRoundInvalid.selector);
        oracle.resolve(marketId, roundHint, prevHint);
    }
}
