// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {IOracle} from "@predix/shared/interfaces/IOracle.sol";

/// @title IChainlinkOracle
/// @notice Chainlink price-feed backed binary oracle. A registrar binds a
///         market to a `(feed, threshold, comparator, snapshotAt)` config, and
///         after `snapshotAt` anyone can call `resolve` to read the latest
///         feed answer and snapshot YES / NO based on the comparator.
/// @dev The resolved price is read via `getRoundData(roundIdHint)`, where
///      the caller-supplied hint must identify the round that contains
///      `snapshotAt` (i.e. `updatedAt >= snapshotAt` and the previous
///      round's `updatedAt < snapshotAt`). The hint binding removes the
///      heartbeat-picking MEV window a latest-answer read would otherwise
///      expose. `answeredInRound` is intentionally not checked because
///      Chainlink deprecates it on new feeds.
///
///      L2 deployments (e.g. Unichain, Arbitrum, Optimism, Base) MUST pass a
///      Chainlink L2 sequencer uptime feed at construction time. When the
///      sequencer feed is set, every `resolve` call also asserts that the
///      sequencer is up and has been up for at least `SEQUENCER_GRACE_PERIOD`,
///      preventing attackers from exploiting stale prices that linger while
///      the sequencer is offline. Pass `address(0)` to skip the check on L1.
interface IChainlinkOracle is IOracle {
    /// @notice Static configuration bound to a market at registration time.
    /// @param feed       Chainlink AggregatorV3 address to read from.
    /// @param threshold  Price threshold expressed in the feed's native decimals.
    /// @param gte        `true` => outcome = (price >= threshold);
    ///                   `false` => outcome = (price <= threshold).
    /// @param snapshotAt Earliest unix timestamp at which `resolve` is callable.
    struct Config {
        address feed;
        int256 threshold;
        bool gte;
        uint64 snapshotAt;
    }

    /// @notice Emitted when a market is bound to a Chainlink feed config.
    event MarketRegistered(
        uint256 indexed marketId, address indexed feed, int256 threshold, bool gte, uint64 snapshotAt
    );

    /// @notice Emitted when a market's outcome is snapshotted from the feed.
    event MarketResolved(uint256 indexed marketId, int256 price, bool outcome);

    /// @notice Emitted when a registered market's config is cleared before
    ///         its snapshot time.
    event MarketUnregistered(uint256 indexed marketId);

    /// @notice Reverts when constructing the oracle with a zero admin address.
    error ChainlinkOracle_ZeroAdmin();

    /// @notice Reverts when constructing the oracle with a zero diamond address.
    error ChainlinkOracle_ZeroDiamond();

    /// @notice Reverts when `register` is called with a marketId the bound
    ///         diamond does not recognize. Prevents cross-diamond marketId
    ///         collisions when an adapter is reused across deployments.
    error ChainlinkOracle_MarketNotFound();

    /// @notice Reverts when `register` is called with `snapshotAt > market.endTime`.
    ///         Defensive: such a config can never resolve — no Chainlink round
    ///         will satisfy the `updatedAt >= snapshotAt` predicate once the
    ///         market has passed its endTime without resolution, leaving the
    ///         market stuck. Catch the config mistake at registration rather
    ///         than let admin silently brick a market.
    error ChainlinkOracle_SnapshotAfterMarketEnd();

    /// @notice Reverts when `register` is called with a zero feed address.
    error ChainlinkOracle_ZeroFeed();

    /// @notice Reverts when `register` is called with `snapshotAt <= block.timestamp`.
    error ChainlinkOracle_PastSnapshot();

    /// @notice Reverts when `register` is called with `snapshotAt` further
    ///         than `MAX_SNAPSHOT_FUTURE` in the future.
    error ChainlinkOracle_SnapshotTooFar();

    /// @notice Reverts when `register` probes the feed via `latestRoundData`
    ///         and receives a non-positive answer or `updatedAt == 0`.
    error ChainlinkOracle_FeedUnhealthy();

    /// @notice Reverts when `unregister` is called after the market's
    ///         snapshot time has passed.
    error ChainlinkOracle_SnapshotPassed();

    /// @notice Reverts when `register` is called for a market that already has a config.
    error ChainlinkOracle_AlreadyRegistered();

    /// @notice Reverts when `resolve` / `outcome` is called for a market that has no config.
    error ChainlinkOracle_NotRegistered();

    /// @notice Reverts when `outcome` is called for a registered but unresolved market.
    error ChainlinkOracle_NotResolvedYet();

    /// @notice Reverts when `resolve` is called twice for the same market.
    error ChainlinkOracle_AlreadyResolved();

    /// @notice Reverts when `resolve` is called before the configured snapshot time.
    error ChainlinkOracle_BeforeSnapshot();

    /// @notice Reverts when `roundIdHint` does not identify the round
    ///         containing `snapshotAt` (either its `updatedAt` is before
    ///         `snapshotAt`, or the previous round is already >= `snapshotAt`).
    error ChainlinkOracle_WrongRoundForSnapshot();

    /// @notice Reverts when the Chainlink feed returns a non-positive answer.
    error ChainlinkOracle_InvalidPrice();

    /// @notice Reverts when the L2 sequencer is reported as down by its uptime feed.
    error ChainlinkOracle_SequencerDown();

    /// @notice Reverts when the L2 sequencer has been back up for less than `SEQUENCER_GRACE_PERIOD`.
    error ChainlinkOracle_SequencerGracePeriodNotOver();

    /// @notice Reverts when the sequencer uptime feed returns `startedAt == 0`
    ///         (feed has never emitted a status round). Prevents the
    ///         `block.timestamp - startedAt` comparison from trivially passing
    ///         on a freshly-deployed L2.
    error ChainlinkOracle_SequencerRoundInvalid();

    /// @notice Reverts when `prevRoundIdHint >= roundIdHint`. The
    ///         predecessor-round hint must be strictly less than the round
    ///         being snapshotted.
    error ChainlinkOracle_InvalidPrevRound();

    /// @notice Reverts when `roundIdHint` and `prevRoundIdHint` are
    ///         in different Chainlink aggregator phases (top 16 bits differ).
    ///         Forces the predecessor to be a real prior round in the same
    ///         phase, closing the edge where `roundIdHint - 1` would cross a
    ///         phase boundary or hit round 0 on the proxy.
    error ChainlinkOracle_PhaseMismatch();

    /// @notice Reverts when `prevRoundIdHint + 1 != roundIdHint`.
    ///         The preceding round must be the literal immediate predecessor
    ///         of `roundIdHint` within the same phase, not just any earlier
    ///         round. Without this, a caller could skip intermediate rounds
    ///         — selecting a conveniently old `prevRoundIdHint` whose
    ///         `updatedAt` happens to sit before `snapshotAt` — and defeat
    ///         the "first round at or after snapshot" invariant that the
    ///         timestamp-bracket check relies on.
    error ChainlinkOracle_NonAdjacentRound();

    /// @notice The configured L2 sequencer uptime feed, or `address(0)` on L1 deployments.
    function sequencerUptimeFeed() external view returns (address);

    /// @notice The diamond this oracle is bound to. `register` enforces that
    ///         marketId must exist on this diamond.
    function diamond() external view returns (address);

    /// @notice Bind `marketId` to a Chainlink feed config.
    /// @dev Callable only by `REGISTRAR_ROLE`. Probes the feed and captures
    ///      its decimals; reverts if the feed is unhealthy or if `snapshotAt`
    ///      sits further than `MAX_SNAPSHOT_FUTURE` in the future.
    function register(uint256 marketId, Config calldata cfg) external;

    /// @notice Clear a market's Chainlink config before its snapshot time.
    /// @dev Callable only by `REGISTRAR_ROLE`. Reverts if the market has no
    ///      config or if `snapshotAt` has already passed.
    function unregister(uint256 marketId) external;

    /// @notice Maximum allowed future offset for `snapshotAt` at register
    ///         time; protects against typo-uint64-max values bricking a
    ///         market forever.
    function MAX_SNAPSHOT_FUTURE() external view returns (uint256);

    /// @notice Snapshot the feed answer and compute the binary outcome for `marketId`.
    /// @dev Permissionless. Reverts if the market is unregistered, already
    ///      resolved, before its snapshot time, if the answer is non-positive,
    ///      if the round / prev-round pair does not bracket `snapshotAt`, or
    ///      if the pair crosses a Chainlink aggregator phase boundary.
    ///      Caller MUST provide both hints — `roundIdHint` is the round whose
    ///      `updatedAt` is the first value >= `snapshotAt`, and `prevRoundIdHint`
    ///      is a prior round in the SAME PHASE whose `updatedAt < snapshotAt`.
    ///      Phase-safe retrieval replaces the pre-fix `roundIdHint - 1` read,
    ///      which could cross phases on proxy feeds.
    /// @param marketId        The market being resolved.
    /// @param roundIdHint     The Chainlink feed round id containing `snapshotAt`.
    /// @param prevRoundIdHint A preceding round id in the same phase whose
    ///                        `updatedAt < snapshotAt`. Typically `roundIdHint - 1`
    ///                        unless the snapshot round is the first round of a
    ///                        new phase.
    function resolve(uint256 marketId, uint80 roundIdHint, uint80 prevRoundIdHint) external;

    /// @notice Read the stored configuration for `marketId`.
    function getConfig(uint256 marketId) external view returns (Config memory);
}
