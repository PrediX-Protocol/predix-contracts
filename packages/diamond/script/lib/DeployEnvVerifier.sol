// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import {AggregatorV3Interface} from "@chainlink/contracts/src/v0.8/shared/interfaces/AggregatorV3Interface.sol";

/// @title DeployEnvVerifier
/// @notice Asserts that env-driven canonical infrastructure addresses
///         (Permit2, Chainlink L2 sequencer uptime feed) match the values
///         expected on the target chain and are live.
///
///         Consumed by both `VerifyDeployEnv.s.sol` (standalone CLI pre-flight)
///         and `DeployAll.s.sol` (mandatory in-broadcast guard) so the two
///         entry points cannot drift.
library DeployEnvVerifier {
    /// @notice Permit2 is deployed via a deterministic CREATE2 factory and has
    ///         the same address on every EVM chain. Any other address is either
    ///         a fake or a stale fork artifact.
    address internal constant CANONICAL_PERMIT2 = 0x000000000022D473030F116dDEE9F6B43aC78BA3;

    /// @notice Maximum age of the sequencer feed's `latestRoundData().updatedAt`
    ///         that the pre-flight will accept. Matches `ChainlinkOracle`'s
    ///         `MAX_SEQUENCER_STALENESS` so a feed that would fail at resolve
    ///         time also fails here.
    uint256 internal constant MAX_SEQUENCER_STALENESS = 1 hours;

    error DeployEnvVerifier_Permit2Mismatch(uint256 chainId, address expected, address actual);
    error DeployEnvVerifier_Permit2NoBytecode(address actual);
    error DeployEnvVerifier_SequencerFeedNoBytecode(address feed);
    error DeployEnvVerifier_SequencerFeedUnresponsive(address feed);
    error DeployEnvVerifier_SequencerFeedStale(address feed, uint256 updatedAt, uint256 nowTs);
    error DeployEnvVerifier_SequencerFeedDown(address feed, int256 answer);
    error DeployEnvVerifier_SequencerFeedExpectedButZero(uint256 chainId);
    error DeployEnvVerifier_SequencerFeedMismatch(uint256 chainId, address expected, address actual);

    /// @dev Known sequencer uptime feed addresses for chains where one is
    ///      expected. Chains not listed here are assumed to be L1 or to lack a
    ///      Chainlink-provided sequencer feed; the env var may be left blank.
    function expectedSequencerFeed(uint256 chainId) internal pure returns (address feed, bool required) {
        if (chainId == 42161) {
            // Arbitrum One
            return (0xFdB631F5EE196F0ed6FAa767959853A9F217697D, true);
        }
        if (chainId == 10) {
            // Optimism mainnet
            return (0x371EAD81c9102C9BF4874A9075FFFf170F2Ee389, true);
        }
        if (chainId == 8453) {
            // Base mainnet
            return (0xBCF85224fc0756B9Fa45aA7892530B47e10b6433, true);
        }
        // L1 (chainId 1) and chains without a Chainlink sequencer feed (e.g.
        // Unichain at the time of writing). Caller must explicitly set
        // CHAINLINK_SEQUENCER_UPTIME_FEED=0x0 to confirm the choice.
        return (address(0), false);
    }

    function verifyPermit2(uint256 chainId, address permit2) internal view {
        if (permit2 != CANONICAL_PERMIT2) {
            revert DeployEnvVerifier_Permit2Mismatch(chainId, CANONICAL_PERMIT2, permit2);
        }
        if (permit2.code.length == 0) {
            revert DeployEnvVerifier_Permit2NoBytecode(permit2);
        }
    }

    function verifySequencerFeed(uint256 chainId, address feed) internal view {
        (address expected, bool required) = expectedSequencerFeed(chainId);

        if (required) {
            if (feed == address(0)) revert DeployEnvVerifier_SequencerFeedExpectedButZero(chainId);
            if (feed != expected) revert DeployEnvVerifier_SequencerFeedMismatch(chainId, expected, feed);
        }
        if (feed == address(0)) return;

        if (feed.code.length == 0) revert DeployEnvVerifier_SequencerFeedNoBytecode(feed);

        try AggregatorV3Interface(feed).latestRoundData() returns (
            uint80, int256 answer, uint256, uint256 updatedAt, uint80
        ) {
            if (updatedAt == 0 || block.timestamp - updatedAt > MAX_SEQUENCER_STALENESS) {
                revert DeployEnvVerifier_SequencerFeedStale(feed, updatedAt, block.timestamp);
            }
            // Chainlink convention: 0 = sequencer up, 1 = down.
            if (answer != 0) revert DeployEnvVerifier_SequencerFeedDown(feed, answer);
        } catch {
            revert DeployEnvVerifier_SequencerFeedUnresponsive(feed);
        }
    }
}
