// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import {Test} from "forge-std/Test.sol";

import {DeployEnvVerifier} from "../../script/lib/DeployEnvVerifier.sol";

/// @dev Harness exposes the library's internal verifiers as external so
///      `vm.expectRevert` can observe individual failure modes.
contract DeployEnvVerifierHarness {
    function checkPermit2(uint256 chainId, address permit2) external view {
        DeployEnvVerifier.verifyPermit2(chainId, permit2);
    }

    function checkSequencerFeed(uint256 chainId, address feed) external view {
        DeployEnvVerifier.verifySequencerFeed(chainId, feed);
    }
}

/// @dev Mock sequencer feed configurable for happy / down / stale paths.
contract MockSequencerFeed {
    int256 public answer;
    uint256 public startedAt;
    uint256 public updatedAt;
    bool public shouldRevert;

    function setRound(int256 answer_, uint256 startedAt_, uint256 updatedAt_) external {
        answer = answer_;
        startedAt = startedAt_;
        updatedAt = updatedAt_;
    }

    function setShouldRevert(bool flag) external {
        shouldRevert = flag;
    }

    function latestRoundData() external view returns (uint80, int256, uint256, uint256, uint80) {
        if (shouldRevert) revert("feed down");
        return (uint80(1), answer, startedAt, updatedAt, uint80(1));
    }
}

contract DeployEnvVerifierTest is Test {
    DeployEnvVerifierHarness internal harness;
    MockSequencerFeed internal feed;

    address internal constant CANONICAL_PERMIT2 = 0x000000000022D473030F116dDEE9F6B43aC78BA3;
    address internal constant ARBITRUM_FEED = 0xFdB631F5EE196F0ed6FAa767959853A9F217697D;

    function setUp() public {
        // Warp into the future so all `block.timestamp - n` reads in this
        // suite stay non-negative (default starting timestamp is 1).
        vm.warp(1 days);
        harness = new DeployEnvVerifierHarness();
        feed = new MockSequencerFeed();
        feed.setRound(0, block.timestamp - 10 minutes, block.timestamp - 5 minutes);
    }

    // ---------------------------------------------------------------- Permit2 ---

    function test_Permit2_HappyPath() public {
        vm.etch(CANONICAL_PERMIT2, hex"60006000");
        harness.checkPermit2(block.chainid, CANONICAL_PERMIT2);
    }

    function test_Revert_Permit2_Mismatch() public {
        address wrong = makeAddr("fakePermit2");
        vm.expectRevert(
            abi.encodeWithSelector(
                DeployEnvVerifier.DeployEnvVerifier_Permit2Mismatch.selector, block.chainid, CANONICAL_PERMIT2, wrong
            )
        );
        harness.checkPermit2(block.chainid, wrong);
    }

    function test_Revert_Permit2_NoBytecode() public {
        vm.etch(CANONICAL_PERMIT2, hex"");
        vm.expectRevert(
            abi.encodeWithSelector(DeployEnvVerifier.DeployEnvVerifier_Permit2NoBytecode.selector, CANONICAL_PERMIT2)
        );
        harness.checkPermit2(block.chainid, CANONICAL_PERMIT2);
    }

    // -------------------------------------------------------------- Sequencer ---

    function test_Sequencer_ZeroOnUnknownChain_NoOp() public view {
        harness.checkSequencerFeed(1337, address(0));
    }

    function test_Sequencer_HappyPath_OnUnknownChain() public view {
        harness.checkSequencerFeed(1337, address(feed));
    }

    function test_Revert_Sequencer_NoBytecode() public {
        address eoa = makeAddr("eoa");
        vm.expectRevert(
            abi.encodeWithSelector(DeployEnvVerifier.DeployEnvVerifier_SequencerFeedNoBytecode.selector, eoa)
        );
        harness.checkSequencerFeed(1337, eoa);
    }

    function test_Revert_Sequencer_Unresponsive() public {
        feed.setShouldRevert(true);
        vm.expectRevert(
            abi.encodeWithSelector(
                DeployEnvVerifier.DeployEnvVerifier_SequencerFeedUnresponsive.selector, address(feed)
            )
        );
        harness.checkSequencerFeed(1337, address(feed));
    }

    function test_Revert_Sequencer_StaleUpdatedAt() public {
        feed.setRound(0, block.timestamp - 3 hours, block.timestamp - 2 hours);
        vm.expectRevert(
            abi.encodeWithSelector(
                DeployEnvVerifier.DeployEnvVerifier_SequencerFeedStale.selector,
                address(feed),
                block.timestamp - 2 hours,
                block.timestamp
            )
        );
        harness.checkSequencerFeed(1337, address(feed));
    }

    function test_Revert_Sequencer_ZeroUpdatedAt() public {
        feed.setRound(0, block.timestamp - 10 minutes, 0);
        vm.expectRevert(
            abi.encodeWithSelector(
                DeployEnvVerifier.DeployEnvVerifier_SequencerFeedStale.selector, address(feed), 0, block.timestamp
            )
        );
        harness.checkSequencerFeed(1337, address(feed));
    }

    function test_Revert_Sequencer_Down() public {
        feed.setRound(1, block.timestamp - 10 minutes, block.timestamp - 5 minutes);
        vm.expectRevert(
            abi.encodeWithSelector(
                DeployEnvVerifier.DeployEnvVerifier_SequencerFeedDown.selector, address(feed), int256(1)
            )
        );
        harness.checkSequencerFeed(1337, address(feed));
    }

    function test_Revert_Sequencer_ExpectedButZero_OnArbitrum() public {
        vm.expectRevert(
            abi.encodeWithSelector(DeployEnvVerifier.DeployEnvVerifier_SequencerFeedExpectedButZero.selector, 42161)
        );
        harness.checkSequencerFeed(42161, address(0));
    }

    function test_Revert_Sequencer_Mismatch_OnArbitrum() public {
        address wrong = address(feed);
        vm.expectRevert(
            abi.encodeWithSelector(
                DeployEnvVerifier.DeployEnvVerifier_SequencerFeedMismatch.selector, 42161, ARBITRUM_FEED, wrong
            )
        );
        harness.checkSequencerFeed(42161, wrong);
    }

    function test_Sequencer_HappyPath_OnArbitrum() public {
        // Etch the mock's runtime code at the canonical Arbitrum feed address
        // and copy storage slots over so latestRoundData returns sane values.
        vm.etch(ARBITRUM_FEED, address(feed).code);
        vm.store(ARBITRUM_FEED, bytes32(uint256(0)), bytes32(uint256(0)));
        vm.store(ARBITRUM_FEED, bytes32(uint256(1)), bytes32(block.timestamp - 10 minutes));
        vm.store(ARBITRUM_FEED, bytes32(uint256(2)), bytes32(block.timestamp - 5 minutes));
        harness.checkSequencerFeed(42161, ARBITRUM_FEED);
    }

    function test_ExpectedSequencerFeed_KnownChains() public pure {
        (address feedAddr, bool required) = DeployEnvVerifier.expectedSequencerFeed(42161);
        assertEq(feedAddr, ARBITRUM_FEED);
        assertTrue(required);

        (feedAddr, required) = DeployEnvVerifier.expectedSequencerFeed(10);
        assertEq(feedAddr, 0x371EAD81c9102C9BF4874A9075FFFf170F2Ee389);
        assertTrue(required);

        (feedAddr, required) = DeployEnvVerifier.expectedSequencerFeed(8453);
        assertEq(feedAddr, 0xBCF85224fc0756B9Fa45aA7892530B47e10b6433);
        assertTrue(required);
    }

    function test_ExpectedSequencerFeed_UnknownChain() public pure {
        (address feedAddr, bool required) = DeployEnvVerifier.expectedSequencerFeed(130);
        assertEq(feedAddr, address(0));
        assertFalse(required);

        (feedAddr, required) = DeployEnvVerifier.expectedSequencerFeed(1);
        assertEq(feedAddr, address(0));
        assertFalse(required);
    }
}
