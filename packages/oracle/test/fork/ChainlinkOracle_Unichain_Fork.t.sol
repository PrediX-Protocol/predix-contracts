// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import {Test} from "forge-std/Test.sol";
import {AggregatorV3Interface} from "@chainlink/contracts/src/v0.8/shared/interfaces/AggregatorV3Interface.sol";

import {IChainlinkOracle} from "@predix/oracle/interfaces/IChainlinkOracle.sol";
import {ChainlinkOracle} from "@predix/oracle/adapters/ChainlinkOracle.sol";

import {MockDiamondMarket} from "../mocks/MockDiamondMarket.sol";

/// @title ChainlinkOracle_Unichain_Fork
/// @notice Forks Unichain Mainnet (chainId 130) and exercises the
///         `ChainlinkOracle` adapter against the **real production** Chainlink
///         feeds that PrediX itself will consume.
///
///         Chainlink Data Feeds launched on Unichain mainnet in 2026 (see
///         Chainlink Scale program announcement); at the time of this test,
///         12 feeds are live including ETH/USD, BTC/USD, UNI/USD, LINK/USD,
///         several LST exchange rates, and the L2 Sequencer Uptime feed.
///
/// @dev Unichain-specific quirks the test pins:
///         - Price feeds report **18 decimals** on Unichain (vs the canonical
///           8 decimals on Ethereum mainnet / Arbitrum / Base). The threshold
///           passed to `register` must therefore be scaled by 1e18, not 1e8.
///         - Same `L2 Sequencer Uptime Status Feed` interface as Arbitrum,
///           but at a Unichain-native address.
///
///        Required env vars:
///          - UNICHAIN_RPC_PRIMARY   RPC endpoint (mainnet)
///          - UNICHAIN_PIN_BLOCK     Pin block (reproducibility)
///        Optional override:
///          - if `UNICHAIN_PIN_BLOCK` is unset, the test falls back to
///            block 49044330 (verified 2026-05-26 — both feeds healthy and
///            sequencer up).
contract ChainlinkOracle_Unichain_Fork is Test {
    // ---------------- Canonical Unichain Mainnet Chainlink feeds ----------------
    //
    // Sourced 2026-05-26 from
    // https://reference-data-directory.vercel.app/feeds-ethereum-mainnet-unichain-1.json
    // (the live JSON behind the Chainlink docs).
    address internal constant UNICHAIN_ETH_USD_FEED = 0xBcE70e194940a157f3A80566505a7E96f5238CCa;
    address internal constant UNICHAIN_SEQUENCER_UPTIME_FEED = 0x495639D9914e7D270c5dCC641BfB1d807423F813;

    /// @dev Recent stable Unichain mainnet block where both feeds reported
    ///      healthy state. Sequencer answer = 0 (UP), ETH/USD price ≈ $2132.
    uint256 internal constant DEFAULT_PIN_BLOCK = 49044330;

    /// @dev Threshold scaled to Unichain's 18-decimal feed convention.
    int256 internal constant THRESHOLD_1000_USD_18DEC = int256(1_000 * 1e18);

    ChainlinkOracle internal oracle;
    MockDiamondMarket internal diamond;

    address internal admin = makeAddr("admin");
    address internal registrar = makeAddr("registrar");

    uint256 internal constant MARKET_ID = 1;

    /// @dev Reused so register's `snapshotAt == market.endTime` guard is
    ///      satisfied without per-test arithmetic.
    uint64 internal marketEndTime;

    function setUp() public {
        string memory rpc = _requiredEnvString("UNICHAIN_RPC_PRIMARY");
        uint256 pin = vm.envOr("UNICHAIN_PIN_BLOCK", DEFAULT_PIN_BLOCK);
        vm.createSelectFork(rpc, pin);

        marketEndTime = uint64(block.timestamp + 1 days);

        diamond = new MockDiamondMarket();
        // Align mock market endTime with snapshotAt so the production
        // `ChainlinkOracle_SnapshotNotMarketEnd` guard (added in commit
        // 198813f) is satisfied.
        diamond.setMarketWithEndTime(MARKET_ID, true, marketEndTime);

        oracle = new ChainlinkOracle(admin, UNICHAIN_SEQUENCER_UPTIME_FEED, address(diamond));
        bytes32 registrarRole = oracle.REGISTRAR_ROLE();
        vm.prank(admin);
        oracle.grantRole(registrarRole, registrar);
    }

    // ----------------------------------------------------------------- happy ---

    /// @dev `register` against the real Unichain ETH/USD feed. Locks in:
    ///        - feed is reachable + reports a healthy `latestRoundData()` at
    ///          the pin block
    ///        - guard `snapshotAt == market.endTime` accepts our setup
    ///        - `MarketRegistered` event payload matches inputs
    ///        - threshold is stored as the same 18-decimal value the caller
    ///          supplied (no implicit normalisation)
    function test_Register_AgainstRealEthUsdFeed_Succeeds() public {
        vm.expectEmit(true, true, false, true, address(oracle));
        emit IChainlinkOracle.MarketRegistered(
            MARKET_ID, UNICHAIN_ETH_USD_FEED, THRESHOLD_1000_USD_18DEC, true, marketEndTime
        );

        vm.prank(registrar);
        oracle.register(
            MARKET_ID,
            IChainlinkOracle.Config({
                feed: UNICHAIN_ETH_USD_FEED,
                threshold: THRESHOLD_1000_USD_18DEC,
                gte: true,
                snapshotAt: marketEndTime
            })
        );

        IChainlinkOracle.Config memory cfg = oracle.getConfig(MARKET_ID);
        assertEq(cfg.feed, UNICHAIN_ETH_USD_FEED);
        assertEq(cfg.threshold, THRESHOLD_1000_USD_18DEC);
        assertTrue(cfg.gte);
        assertEq(cfg.snapshotAt, marketEndTime);
    }

    // ----------------------------------------------------------------- guard ---

    /// @dev The real Unichain sequencer uptime feed reports the sequencer as
    ///      up at the pin block. Calling `resolve` with deliberately bad round
    ///      hints must fail with the round-adjacency guard, NOT a sequencer
    ///      error — proving `_checkSequencer` passes against the production
    ///      feed.
    function test_CheckSequencer_AgainstRealSequencerFeed_PassesAtPinBlock() public {
        vm.prank(registrar);
        oracle.register(
            MARKET_ID,
            IChainlinkOracle.Config({
                feed: UNICHAIN_ETH_USD_FEED,
                threshold: THRESHOLD_1000_USD_18DEC,
                gte: true,
                snapshotAt: marketEndTime
            })
        );

        // Advance past the snapshot so the time gate is satisfied. Use
        // rollFork=false (default) — we want only block.timestamp to move.
        vm.warp(uint256(marketEndTime) + 1);

        // Bogus round hints: prev + 1 != hint will trip the round-adjacency
        // guard. The guard runs AFTER `_checkSequencer`, so this revert
        // proves the sequencer check passed against the real Unichain state.
        vm.expectRevert(IChainlinkOracle.ChainlinkOracle_NonAdjacentRound.selector);
        oracle.resolve(MARKET_ID, uint80(100), uint80(50));
    }

    // ---------------------------------------------------------------- sanity ---

    /// @dev The real Unichain ETH/USD feed reports a positive answer at the
    ///      pin block. Doubles as a state-of-Unichain check — if Chainlink's
    ///      ETH/USD answer ever goes non-positive, PrediX markets in
    ///      production should refuse to resolve against that feed.
    function test_RealEthUsdFeed_ReturnsPositiveAnswer() public view {
        (, int256 answer,, uint256 updatedAt,) = AggregatorV3Interface(UNICHAIN_ETH_USD_FEED).latestRoundData();
        assertGt(answer, 0, "ETH/USD answer non-positive at pin block");
        assertGt(updatedAt, 0, "ETH/USD updatedAt zero at pin block");
        // Lower bound is loose enough to survive years of price action; only
        // a feed misconfiguration or an outage would trip it.
        assertGt(answer, int256(100 * 1e18), "ETH/USD < $100 (feed regressed?)");
    }

    /// @dev Unichain-specific: the ETH/USD feed reports 18 decimals, NOT 8 as
    ///      on Ethereum L1 / Arbitrum / most other chains. Locks this in so a
    ///      future deploy script that hard-codes `int256(threshold * 1e8)`
    ///      against the Unichain feed will trip this test first.
    function test_UnichainEthUsdFeed_Has18Decimals() public view {
        uint8 decimals = AggregatorV3Interface(UNICHAIN_ETH_USD_FEED).decimals();
        assertEq(decimals, 18, "Unichain ETH/USD must be 18-decimal");
    }

    /// @dev The L2 Sequencer Uptime feed reports answer=0 (sequencer UP) at
    ///      the pin block. Chainlink convention: 0 = up, 1 = down.
    function test_SequencerUptimeFeed_IsUp_AtPinBlock() public view {
        (, int256 answer, uint256 startedAt, uint256 updatedAt,) =
            AggregatorV3Interface(UNICHAIN_SEQUENCER_UPTIME_FEED).latestRoundData();
        assertEq(answer, 0, "sequencer DOWN at pin block (Chainlink: 0=up,1=down)");
        assertGt(startedAt, 0, "sequencer startedAt zero - invalid round");
        assertGt(updatedAt, 0, "sequencer updatedAt zero - invalid round");
    }

    // ----------------------------------------------------------------- env ---

    function _requiredEnvString(string memory key) internal view returns (string memory) {
        string memory v = vm.envOr(key, string(""));
        if (bytes(v).length == 0) revert(string.concat("required env var unset: ", key));
        return v;
    }
}
