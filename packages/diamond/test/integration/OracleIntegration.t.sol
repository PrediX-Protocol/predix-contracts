// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {IMarketFacet} from "@predix/shared/interfaces/IMarketFacet.sol";

import {IChainlinkOracle} from "@predix/oracle/interfaces/IChainlinkOracle.sol";
import {IManualOracle} from "@predix/oracle/interfaces/IManualOracle.sol";
import {ChainlinkOracle} from "@predix/oracle/adapters/ChainlinkOracle.sol";
import {ManualOracle} from "@predix/oracle/adapters/ManualOracle.sol";

import {MarketFixture} from "../utils/MarketFixture.sol";
import {MockChainlinkAggregator} from "./mocks/MockChainlinkAggregator.sol";

/// @notice End-to-end integration between the diamond and the standalone
///         oracle adapters. Covers the ground-truth paths the protocol uses
///         at resolution time: reporter-driven `ManualOracle` and
///         Chainlink round-pinned `ChainlinkOracle`.
contract OracleIntegrationTest is MarketFixture {
    ManualOracle internal manualOracle;
    ChainlinkOracle internal chainlinkOracle;
    MockChainlinkAggregator internal feed;

    address internal oracleAdmin = makeAddr("oracleAdmin");
    address internal reporter = makeAddr("reporter");
    address internal registrar = makeAddr("registrar");

    uint256 internal constant SPLIT_AMOUNT = 1_000e6;

    function setUp() public override {
        super.setUp();

        manualOracle = new ManualOracle(oracleAdmin, address(diamond));
        chainlinkOracle = new ChainlinkOracle(oracleAdmin, address(0), address(diamond));
        feed = new MockChainlinkAggregator(8, "ETH / USD");

        bytes32 reporterRole = manualOracle.REPORTER_ROLE();
        bytes32 registrarRole = chainlinkOracle.REGISTRAR_ROLE();
        vm.startPrank(oracleAdmin);
        manualOracle.grantRole(reporterRole, reporter);
        chainlinkOracle.grantRole(registrarRole, registrar);
        vm.stopPrank();

        vm.startPrank(admin);
        market.approveOracle(address(manualOracle));
        market.approveOracle(address(chainlinkOracle));
        vm.stopPrank();
    }

    function test_ManualOracle_FullFlow_YesWins() public {
        uint256 endTime = block.timestamp + 1 days;
        vm.prank(alice);
        uint256 marketId = market.createMarket("Will X happen?", endTime, address(manualOracle));

        _split(alice, marketId, SPLIT_AMOUNT);

        vm.warp(endTime + 1);

        vm.prank(reporter);
        manualOracle.report(marketId, true);

        market.resolveMarket(marketId);

        uint256 balBefore = IERC20(address(usdc)).balanceOf(alice);
        vm.prank(alice);
        uint256 payout = market.redeem(marketId);
        uint256 balAfter = IERC20(address(usdc)).balanceOf(alice);

        assertEq(payout, SPLIT_AMOUNT);
        assertEq(balAfter - balBefore, SPLIT_AMOUNT);
        assertTrue(market.getMarket(marketId).outcome);
    }

    function test_ChainlinkOracle_FullFlow_NoWins() public {
        uint256 endTime = block.timestamp + 1 days;
        uint64 snapshotAt = uint64(endTime);
        int256 threshold = 4_000e8;

        // Pre-snapshot round (stale quote at register time). Must exist so the
        // feed probe in `register` sees healthy data.
        feed.setAnswer(3_000e8, block.timestamp);

        vm.prank(alice);
        uint256 marketId = market.createMarket("ETH >= 4000?", endTime, address(chainlinkOracle));

        vm.prank(registrar);
        chainlinkOracle.register(
            marketId,
            IChainlinkOracle.Config({feed: address(feed), threshold: threshold, gte: true, snapshotAt: snapshotAt})
        );

        _split(alice, marketId, SPLIT_AMOUNT);

        vm.warp(endTime + 1);

        // Post-snapshot round. Round id 2 is the first round whose `updatedAt`
        // is >= `snapshotAt`; round id 1 (prev) was recorded pre-snapshot.
        feed.setAnswer(3_500e8, block.timestamp);

        uint80 roundIdHint = 2;
        chainlinkOracle.resolve(marketId, roundIdHint);
        market.resolveMarket(marketId);

        assertFalse(market.getMarket(marketId).outcome);

        uint256 balBefore = IERC20(address(usdc)).balanceOf(alice);
        vm.prank(alice);
        uint256 payout = market.redeem(marketId);
        uint256 balAfter = IERC20(address(usdc)).balanceOf(alice);

        assertEq(payout, SPLIT_AMOUNT);
        assertEq(balAfter - balBefore, SPLIT_AMOUNT);
    }

    function test_Revert_ResolveMarket_ManualOracle_NotReported() public {
        uint256 endTime = block.timestamp + 1 days;
        vm.prank(alice);
        uint256 marketId = market.createMarket("Will X happen?", endTime, address(manualOracle));

        vm.warp(endTime + 1);
        vm.expectRevert(IMarketFacet.Market_OracleNotResolved.selector);
        market.resolveMarket(marketId);
    }

    function test_Revert_ResolveMarket_ChainlinkOracle_NotResolvedYet() public {
        uint256 endTime = block.timestamp + 1 days;
        uint64 snapshotAt = uint64(endTime);

        // Seed the feed so `register`'s health probe succeeds.
        feed.setAnswer(3_000e8, block.timestamp);

        vm.prank(alice);
        uint256 marketId = market.createMarket("ETH >= 4000?", endTime, address(chainlinkOracle));

        vm.prank(registrar);
        chainlinkOracle.register(
            marketId,
            IChainlinkOracle.Config({feed: address(feed), threshold: 4_000e8, gte: true, snapshotAt: snapshotAt})
        );

        vm.warp(endTime + 1);
        // ChainlinkOracle.resolve not called yet → diamond must revert.
        vm.expectRevert(IMarketFacet.Market_OracleNotResolved.selector);
        market.resolveMarket(marketId);
    }

    function test_Revert_ManualOracle_ReportBeforeMarketEnd() public {
        uint256 endTime = block.timestamp + 1 days;
        vm.prank(alice);
        uint256 marketId = market.createMarket("Will X happen?", endTime, address(manualOracle));

        // Reporter attempts to publish before the market ends → H10 endTime gate rejects.
        vm.prank(reporter);
        vm.expectRevert(IManualOracle.ManualOracle_BeforeMarketEnd.selector);
        manualOracle.report(marketId, true);
    }

    function test_Revert_ChainlinkOracle_Resolve_WrongRoundHint() public {
        uint256 endTime = block.timestamp + 1 days;
        uint64 snapshotAt = uint64(endTime);

        feed.setAnswer(3_000e8, block.timestamp);

        vm.prank(alice);
        uint256 marketId = market.createMarket("ETH >= 4000?", endTime, address(chainlinkOracle));

        vm.prank(registrar);
        chainlinkOracle.register(
            marketId,
            IChainlinkOracle.Config({feed: address(feed), threshold: 4_000e8, gte: true, snapshotAt: snapshotAt})
        );

        vm.warp(endTime + 1);
        feed.setAnswer(3_500e8, block.timestamp);

        // Round 1 is pre-snapshot — its `updatedAt` is strictly less than
        // `snapshotAt`, so pinning to round 1 must revert with
        // `ChainlinkOracle_WrongRoundForSnapshot`.
        uint80 wrongHint = 1;
        vm.expectRevert(IChainlinkOracle.ChainlinkOracle_WrongRoundForSnapshot.selector);
        chainlinkOracle.resolve(marketId, wrongHint);
    }
}
