// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {AggregatorV3Interface} from "@chainlink/contracts/src/v0.8/shared/interfaces/AggregatorV3Interface.sol";

import {IMarketFacet} from "@predix/shared/interfaces/IMarketFacet.sol";
import {IOracle} from "@predix/shared/interfaces/IOracle.sol";

import {IChainlinkOracle} from "../interfaces/IChainlinkOracle.sol";

/// @title ChainlinkOracle
/// @notice Chainlink-backed `IOracle`. A registrar binds each diamond market
///         to a `(feed, threshold, comparator, snapshotAt)` tuple; after the
///         snapshot time anyone can call `resolve(marketId, roundIdHint)`
///         where `roundIdHint` is the Chainlink round containing `snapshotAt`.
/// @dev Uses OZ `AccessControl` as a standalone registry (not a diamond
///      facet). The resolved price is read via `getRoundData(roundIdHint)`,
///      and both the hinted round and its predecessor are checked so the
///      hint is forced to be the unique round whose `updatedAt` is the first
///      value greater than or equal to `snapshotAt`. This removes the
///      heartbeat-picking MEV window a latest-answer read would otherwise
///      expose.
///
///      The constructor accepts an optional Chainlink L2 sequencer uptime
///      feed. When set (non-zero), every `resolve` call also verifies the
///      sequencer is currently up AND has been up for at least
///      `SEQUENCER_GRACE_PERIOD`. Pass `address(0)` to skip the check on L1.
contract ChainlinkOracle is IChainlinkOracle, AccessControl {
    /// @notice Role granted to addresses permitted to call `register`.
    bytes32 public constant REGISTRAR_ROLE = keccak256("predix.oracle.registrar");

    /// @inheritdoc IChainlinkOracle
    uint256 public constant override MAX_SNAPSHOT_FUTURE = 365 days;

    /// @notice Minimum elapsed time (in seconds) since the L2 sequencer was
    ///         last confirmed up before `resolve` is allowed to proceed.
    uint256 public constant SEQUENCER_GRACE_PERIOD = 1 hours;

    /// @inheritdoc IChainlinkOracle
    address public immutable override sequencerUptimeFeed;

    /// @inheritdoc IChainlinkOracle
    address public immutable override diamond;

    struct Resolution {
        bool resolved;
        bool outcome;
        int256 price;
        uint64 resolvedAt;
    }

    mapping(uint256 marketId => Config) internal _configs;
    mapping(uint256 marketId => Resolution) internal _resolutions;
    mapping(uint256 marketId => uint8) internal _decimals;

    /// @notice Deploy the oracle and seat the initial admin.
    /// @param admin                   Address granted `DEFAULT_ADMIN_ROLE`; must be non-zero.
    /// @param sequencerUptimeFeed_    Chainlink L2 sequencer uptime feed; pass
    ///                                `address(0)` for L1 deployments to skip the check.
    /// @param diamond_                Address of the diamond this oracle is bound to;
    ///                                must be non-zero. `register` asserts marketId
    ///                                exists on this diamond so an adapter reused
    ///                                across deployments cannot have cross-diamond
    ///                                marketId collisions. (NEW-02)
    constructor(address admin, address sequencerUptimeFeed_, address diamond_) {
        if (admin == address(0)) revert ChainlinkOracle_ZeroAdmin();
        if (diamond_ == address(0)) revert ChainlinkOracle_ZeroDiamond();
        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        sequencerUptimeFeed = sequencerUptimeFeed_;
        diamond = diamond_;
    }

    /// @inheritdoc IChainlinkOracle
    function register(uint256 marketId, Config calldata cfg) external onlyRole(REGISTRAR_ROLE) {
        if (cfg.feed == address(0)) revert ChainlinkOracle_ZeroFeed();
        if (cfg.snapshotAt <= block.timestamp) revert ChainlinkOracle_PastSnapshot();
        if (cfg.snapshotAt > block.timestamp + MAX_SNAPSHOT_FUTURE) revert ChainlinkOracle_SnapshotTooFar();

        // NEW-02: bind to the diamond's marketId namespace. A diamond that
        // has not minted `marketId` returns yesToken == address(0); reject.
        IMarketFacet.MarketView memory mkt = IMarketFacet(diamond).getMarket(marketId);
        if (mkt.yesToken == address(0)) revert ChainlinkOracle_MarketNotFound();

        // Defensive: a snapshot past the market's endTime would leave the
        // oracle unable to ever resolve the market (no valid round can
        // satisfy `updatedAt >= snapshotAt AND prevUpdatedAt < snapshotAt`
        // after endTime has passed without resolution). Catch config mistake
        // at registration rather than let admin brick a market silently.
        if (cfg.snapshotAt > mkt.endTime) revert ChainlinkOracle_SnapshotAfterMarketEnd();

        AggregatorV3Interface feed = AggregatorV3Interface(cfg.feed);
        (, int256 probe,, uint256 probeUpdatedAt,) = feed.latestRoundData();
        if (probe <= 0 || probeUpdatedAt == 0) revert ChainlinkOracle_FeedUnhealthy();
        uint8 dec = feed.decimals();

        if (_configs[marketId].feed != address(0)) revert ChainlinkOracle_AlreadyRegistered();

        _configs[marketId] = cfg;
        _decimals[marketId] = dec;
        emit MarketRegistered(marketId, cfg.feed, cfg.threshold, cfg.gte, cfg.snapshotAt);
    }

    /// @inheritdoc IChainlinkOracle
    function unregister(uint256 marketId) external onlyRole(REGISTRAR_ROLE) {
        Config memory cfg = _configs[marketId];
        if (cfg.feed == address(0)) revert ChainlinkOracle_NotRegistered();
        if (cfg.snapshotAt <= block.timestamp) revert ChainlinkOracle_SnapshotPassed();

        delete _configs[marketId];
        delete _decimals[marketId];
        emit MarketUnregistered(marketId);
    }

    /// @inheritdoc IChainlinkOracle
    function resolve(uint256 marketId, uint80 roundIdHint, uint80 prevRoundIdHint) external {
        Config memory cfg = _configs[marketId];
        if (cfg.feed == address(0)) revert ChainlinkOracle_NotRegistered();
        if (_resolutions[marketId].resolved) revert ChainlinkOracle_AlreadyResolved();
        if (block.timestamp < cfg.snapshotAt) revert ChainlinkOracle_BeforeSnapshot();

        // F-D-02: caller provides the preceding round explicitly so the
        // predecessor read is a real round in the same Chainlink phase
        // (roundId is `phaseId << 64 | aggregatorRoundId`). Subtracting 1 off
        // `roundIdHint` would cross a phase boundary at `aggregatorRoundId == 1`
        // and read round 0 of a new phase — on proxies that return zeros for
        // unknown rounds the guard silently passes. Explicit same-phase
        // prev hint closes the edge.
        if (prevRoundIdHint >= roundIdHint) revert ChainlinkOracle_InvalidPrevRound();
        if ((prevRoundIdHint >> 64) != (roundIdHint >> 64)) revert ChainlinkOracle_PhaseMismatch();
        if (prevRoundIdHint + 1 != roundIdHint) revert ChainlinkOracle_NonAdjacentRound();

        _checkSequencer();

        AggregatorV3Interface feed = AggregatorV3Interface(cfg.feed);
        (, int256 answer,, uint256 updatedAt,) = feed.getRoundData(roundIdHint);
        (,,, uint256 prevUpdatedAt,) = feed.getRoundData(prevRoundIdHint);
        if (updatedAt < cfg.snapshotAt || prevUpdatedAt >= cfg.snapshotAt) {
            revert ChainlinkOracle_WrongRoundForSnapshot();
        }
        if (answer <= 0) revert ChainlinkOracle_InvalidPrice();

        bool outcome_ = cfg.gte ? answer >= cfg.threshold : answer <= cfg.threshold;

        _resolutions[marketId] =
            Resolution({resolved: true, outcome: outcome_, price: answer, resolvedAt: uint64(block.timestamp)});

        emit MarketResolved(marketId, answer, outcome_);
    }

    /// @inheritdoc IChainlinkOracle
    function getConfig(uint256 marketId) external view returns (Config memory) {
        return _configs[marketId];
    }

    /// @inheritdoc IOracle
    function isResolved(uint256 marketId) external view returns (bool) {
        return _resolutions[marketId].resolved;
    }

    /// @inheritdoc IOracle
    /// @dev Reverts with `ChainlinkOracle_NotRegistered` if the market has no
    ///      config, or `ChainlinkOracle_NotResolvedYet` if the config exists
    ///      but `resolve` has not been called.
    function outcome(uint256 marketId) external view returns (bool) {
        if (_configs[marketId].feed == address(0)) revert ChainlinkOracle_NotRegistered();
        Resolution storage r = _resolutions[marketId];
        if (!r.resolved) revert ChainlinkOracle_NotResolvedYet();
        return r.outcome;
    }

    /// @dev L2 sequencer health check. No-op if `sequencerUptimeFeed == address(0)`.
    ///      Chainlink convention: answer `0` = sequencer up, `1` = down. `startedAt`
    ///      is the timestamp at which the current status round started, so
    ///      `block.timestamp - startedAt` is how long the sequencer has held its
    ///      current state.
    function _checkSequencer() private view {
        address feed = sequencerUptimeFeed;
        if (feed == address(0)) return;
        (, int256 answer, uint256 startedAt,,) = AggregatorV3Interface(feed).latestRoundData();
        // NEW-M8: a freshly-deployed L2 uptime feed that has never emitted
        // a status round returns startedAt == 0. `block.timestamp - 0`
        // trivially clears the grace-period check, so the bare comparison
        // would silently treat an uninitialized sequencer as healthy.
        // Reject explicitly before the subtraction.
        if (startedAt == 0) revert ChainlinkOracle_SequencerRoundInvalid();
        if (answer != 0) revert ChainlinkOracle_SequencerDown();
        if (block.timestamp - startedAt < SEQUENCER_GRACE_PERIOD) {
            revert ChainlinkOracle_SequencerGracePeriodNotOver();
        }
    }
}
