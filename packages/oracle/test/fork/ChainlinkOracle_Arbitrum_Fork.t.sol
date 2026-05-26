// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import {Test} from "forge-std/Test.sol";
import {AggregatorV3Interface} from "@chainlink/contracts/src/v0.8/shared/interfaces/AggregatorV3Interface.sol";

import {IChainlinkOracle} from "@predix/oracle/interfaces/IChainlinkOracle.sol";
import {ChainlinkOracle} from "@predix/oracle/adapters/ChainlinkOracle.sol";

import {MockDiamondMarket} from "../mocks/MockDiamondMarket.sol";

/// @title ChainlinkOracle_Arbitrum_Fork
/// @notice Forks Arbitrum One and exercises `ChainlinkOracle.register` /
///         `resolve` against the real canonical ETH/USD price feed and the
///         real Arbitrum sequencer uptime feed.
///
///         Originally written when Unichain had no published Chainlink feeds;
///         Chainlink Data Feeds went live on Unichain mainnet in 2026 and the
///         primary integration coverage is now in `ChainlinkOracle_Unichain_Fork.t.sol`.
///         This Arbitrum fork is retained as a cross-chain regression — the
///         adapter is chain-agnostic, so behavioural drift would surface on
///         BOTH chains identically. If only Arbitrum fails, the issue is in
///         the Arbitrum-specific test setup; if both fail, the adapter
///         regressed.
///
///         The test relies on three real Arbitrum mainnet contracts at the
///         pin block:
///           1. ETH/USD aggregator
///           2. Sequencer uptime feed
///           3. The aggregator's `latestRoundData()` returns a valid round
///
///         A revert here means either Chainlink relocated the feed (extremely
///         unlikely — they treat feed addresses as immutable) or the
///         `ChainlinkOracle` adapter regressed.
///
/// @dev Required env vars:
///        - ARBITRUM_RPC_PRIMARY   RPC endpoint
///        - ARBITRUM_PIN_BLOCK     Pin block (reproducibility)
contract ChainlinkOracle_Arbitrum_Fork is Test {
    // Canonical Arbitrum One Chainlink contracts.
    address internal constant ARB_ETH_USD_FEED = 0x639Fe6ab55C921f74e7fac1ee960C0B6293ba612;
    address internal constant ARB_SEQUENCER_UPTIME_FEED = 0xFdB631F5EE196F0ed6FAa767959853A9F217697D;

    ChainlinkOracle internal oracle;
    MockDiamondMarket internal diamond;

    address internal admin = makeAddr("admin");
    address internal registrar = makeAddr("registrar");

    uint256 internal constant MARKET_ID = 1;

    /// @dev Reused across tests so register's `snapshotAt == market.endTime`
    ///      guard (added in commit 198813f) is satisfied without per-test
    ///      arithmetic. Mirrors the pattern in ChainlinkOracle_Unichain_Fork.
    uint64 internal marketEndTime;

    function setUp() public {
        string memory rpc = _requiredEnvString("ARBITRUM_RPC_PRIMARY");
        uint256 pin = _requiredEnvUint("ARBITRUM_PIN_BLOCK");
        vm.createSelectFork(rpc, pin);

        marketEndTime = uint64(block.timestamp + 1 days);

        diamond = new MockDiamondMarket();
        // Align mock market endTime with snapshotAt so the production
        // `ChainlinkOracle_SnapshotNotMarketEnd` guard accepts our register.
        diamond.setMarketWithEndTime(MARKET_ID, true, marketEndTime);

        oracle = new ChainlinkOracle(admin, ARB_SEQUENCER_UPTIME_FEED, address(diamond));
        bytes32 registrarRole = oracle.REGISTRAR_ROLE();
        vm.prank(admin);
        oracle.grantRole(registrarRole, registrar);
    }

    /// @dev Smoke: the production register path probes
    ///      `feed.latestRoundData()` and reverts on unhealthy answers.
    ///      A successful register here proves the adapter sees a healthy
    ///      real ETH/USD feed at the pin block.
    function test_Register_AgainstRealEthUsdFeed_Succeeds() public {
        vm.expectEmit(true, true, false, true, address(oracle));
        emit IChainlinkOracle.MarketRegistered(
            MARKET_ID, ARB_ETH_USD_FEED, int256(1000e8), true, marketEndTime
        );

        vm.prank(registrar);
        oracle.register(
            MARKET_ID,
            IChainlinkOracle.Config({
                feed: ARB_ETH_USD_FEED,
                threshold: int256(1000e8),
                gte: true,
                snapshotAt: marketEndTime
            })
        );

        IChainlinkOracle.Config memory cfg = oracle.getConfig(MARKET_ID);
        assertEq(cfg.feed, ARB_ETH_USD_FEED);
        assertEq(cfg.threshold, int256(1000e8));
        assertTrue(cfg.gte);
        assertEq(cfg.snapshotAt, marketEndTime);
    }

    /// @dev The real Arbitrum sequencer uptime feed reports the sequencer as
    ///      up at the pin block; calling resolve with deliberately bad round
    ///      hints must fail with a round-validation error, NOT a sequencer
    ///      error. A sequencer-error revert here would indicate either the
    ///      pin block sits inside an Arbitrum outage window or the adapter's
    ///      `_checkSequencer` regressed.
    function test_CheckSequencer_AgainstRealSequencerFeed_PassesAtPinBlock() public {
        vm.prank(registrar);
        oracle.register(
            MARKET_ID,
            IChainlinkOracle.Config({
                feed: ARB_ETH_USD_FEED,
                threshold: int256(1000e8),
                gte: true,
                snapshotAt: marketEndTime
            })
        );

        // Advance past the snapshot so the time gate is satisfied.
        vm.warp(uint256(marketEndTime) + 1);

        // Bogus round hints: prev + 1 != hint will trip the round-adjacency
        // guard. The guard runs AFTER `_checkSequencer`, so this revert
        // proves the sequencer check passed against real Arbitrum state.
        vm.expectRevert(IChainlinkOracle.ChainlinkOracle_NonAdjacentRound.selector);
        oracle.resolve(MARKET_ID, uint80(100), uint80(50));
    }

    /// @dev Sanity: the real ETH/USD feed reports a positive answer at the
    ///      pin block. Doubles as a state-of-Arbitrum sanity check —
    ///      if Chainlink's ETH/USD answer ever goes non-positive on
    ///      Arbitrum, prediction markets in production should refuse to
    ///      resolve against that feed.
    function test_RealFeed_ReturnsPositiveAnswer() public view {
        (, int256 answer,, uint256 updatedAt,) =
            AggregatorV3Interface(ARB_ETH_USD_FEED).latestRoundData();
        assertGt(answer, 0, "ETH/USD answer non-positive at pin block");
        assertGt(updatedAt, 0, "ETH/USD updatedAt zero at pin block");
    }

    // ----------------------------------------------------------------- env ---

    function _requiredEnvString(string memory key) internal view returns (string memory) {
        string memory v = vm.envOr(key, string(""));
        if (bytes(v).length == 0) revert(string.concat("required env var unset: ", key));
        return v;
    }

    function _requiredEnvUint(string memory key) internal view returns (uint256) {
        return vm.envUint(key);
    }
}
