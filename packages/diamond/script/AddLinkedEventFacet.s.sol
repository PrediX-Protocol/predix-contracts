// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import {Script, console2} from "forge-std/Script.sol";

import {IDiamondCut} from "@predix/shared/interfaces/IDiamondCut.sol";
import {IDiamondLoupe} from "@predix/shared/interfaces/IDiamondLoupe.sol";
import {IEventFacet} from "@predix/shared/interfaces/IEventFacet.sol";
import {ILinkedEventFacet} from "@predix/shared/interfaces/ILinkedEventFacet.sol";
import {IMarketFacet} from "@predix/shared/interfaces/IMarketFacet.sol";

import {EventFacet} from "@predix/diamond/facets/event/EventFacet.sol";
import {LinkedEventFacet} from "@predix/diamond/facets/event/LinkedEventFacet.sol";
import {MarketFacet} from "@predix/diamond/facets/market/MarketFacet.sol";

interface ITimelockMinDelay {
    function getMinDelay() external view returns (uint256);
}

/// @title AddLinkedEventFacet
/// @notice Gap#1 diamond cut: ADD `LinkedEventFacet` and REPLACE the (now linked-aware) `MarketFacet` +
///         `EventFacet` so the shared-collateral engine goes live in ONE atomic cut.
/// @dev DRY-RUN ONLY — this script deploys the three facets locally and PRINTS the Timelock
///      schedule/execute calldata for a multisig to submit. It never broadcasts. The single cut is
///      mandatory (audit A-5): the EventFacet linked guards (`addEventOutcome` / `enableEventRefundMode`)
///      must go live in the SAME transaction as the LinkedEventFacet ADD, so a linked event can never
///      exist without its guards. All 10 EventFacet selectors are REPLACEd (audit C-3) — the live diamond
///      may serve them across two impls, and a partial replace would leave an old, unguarded impl routed.
///
///      Required env: MNEMONIC (HD-0) or DEPLOYER_PRIVATE_KEY, DIAMOND_ADDRESS, TIMELOCK_ADDRESS.
contract AddLinkedEventFacet is Script {
    function run() external returns (address marketFacet, address eventFacet, address linkedFacet) {
        address diamond = vm.envAddress("DIAMOND_ADDRESS");
        address timelock = vm.envAddress("TIMELOCK_ADDRESS");

        // F2 pre-flight (audit Gap#1): every Market/Event selector this script REPLACEs must already
        // be live on the diamond, else the Timelock `execute` reverts mid-cut AFTER the multi-day
        // delay (a wasted cycle, not a brick — funds untouched). Asserted only when the diamond has
        // deployed code (fork / live run); skipped on a pure local dry-run where DIAMOND_ADDRESS
        // points at an empty account.
        if (diamond.code.length > 0) _assertReplaceTargetsLive(diamond);

        string memory mnemonic = vm.envOr("MNEMONIC", string(""));
        uint256 deployerKey =
            bytes(mnemonic).length > 0 ? vm.deriveKey(mnemonic, 0) : vm.envUint("DEPLOYER_PRIVATE_KEY");

        vm.startBroadcast(deployerKey);
        marketFacet = address(new MarketFacet());
        eventFacet = address(new EventFacet());
        linkedFacet = address(new LinkedEventFacet());
        vm.stopBroadcast();

        IDiamondCut.FacetCut[] memory cuts = new IDiamondCut.FacetCut[](3);
        cuts[0] = IDiamondCut.FacetCut({
            facetAddress: marketFacet, action: IDiamondCut.FacetCutAction.Replace, functionSelectors: _marketSelectors()
        });
        cuts[1] = IDiamondCut.FacetCut({
            facetAddress: eventFacet, action: IDiamondCut.FacetCutAction.Replace, functionSelectors: _eventSelectors()
        });
        cuts[2] = IDiamondCut.FacetCut({
            facetAddress: linkedFacet, action: IDiamondCut.FacetCutAction.Add, functionSelectors: _linkedSelectors()
        });

        bytes memory cutCalldata = abi.encodeCall(IDiamondCut.diamondCut, (cuts, address(0), bytes("")));

        bytes32 predecessor = bytes32(0);
        bytes32 salt = keccak256("predix.upgrade.gap1.linkedEventFacet.v1");
        uint256 delay = ITimelockMinDelay(timelock).getMinDelay();

        bytes memory scheduleCalldata = abi.encodeWithSignature(
            "schedule(address,uint256,bytes,bytes32,bytes32,uint256)",
            diamond,
            uint256(0),
            cutCalldata,
            predecessor,
            salt,
            delay
        );
        bytes memory executeCalldata = abi.encodeWithSignature(
            "execute(address,uint256,bytes,bytes32,bytes32)", diamond, uint256(0), cutCalldata, predecessor, salt
        );

        console2.log("============================================================");
        console2.log("AddLinkedEventFacet (Gap#1) - REPLACE Market+Event, ADD Linked (ONE atomic cut)");
        console2.log("============================================================");
        console2.log("new MarketFacet impl:", marketFacet);
        console2.log("new EventFacet impl: ", eventFacet);
        console2.log("new LinkedEventFacet:", linkedFacet);
        console2.log("diamond:             ", diamond);
        console2.log("timelock:            ", timelock);
        console2.log("salt:");
        console2.logBytes32(salt);
        console2.log("minDelay (s):", delay);
        console2.log("");
        console2.log(">> STEP A - multisig submits to Timelock (schedule). to =", timelock);
        console2.logBytes(scheduleCalldata);
        console2.log("");
        console2.log(">> STEP B - after minDelay, multisig submits to Timelock (execute). to =", timelock);
        console2.logBytes(executeCalldata);
    }

    /// @dev Asserts every Replace-target selector resolves to a live facet on the diamond (EIP-2535
    ///      loupe). A `Replace` of a selector the diamond does not currently serve reverts inside
    ///      `diamondCut`; catching it here (pre-schedule) avoids burning the Timelock delay on a cut
    ///      that would only revert on execute.
    function _assertReplaceTargetsLive(address diamond_) internal view {
        bytes4[] memory marketSels = _marketSelectors();
        for (uint256 i; i < marketSels.length; ++i) {
            require(
                IDiamondLoupe(diamond_).facetAddress(marketSels[i]) != address(0),
                "preflight: a MarketFacet Replace-target selector is not live on the diamond"
            );
        }
        bytes4[] memory eventSels = _eventSelectors();
        for (uint256 i; i < eventSels.length; ++i) {
            require(
                IDiamondLoupe(diamond_).facetAddress(eventSels[i]) != address(0),
                "preflight: an EventFacet Replace-target selector is not live on the diamond"
            );
        }
    }

    /// @dev Full MarketFacet selector set (bytecode changed: linked-aware split/merge + linked guards), so
    ///      REPLACE the whole set to a single new impl rather than leave a split deployment.
    function _marketSelectors() internal pure returns (bytes4[] memory s) {
        s = new bytes4[](31);
        s[0] = IMarketFacet.createMarket.selector;
        s[1] = IMarketFacet.splitPosition.selector;
        s[2] = IMarketFacet.mergePositions.selector;
        s[3] = IMarketFacet.resolveMarket.selector;
        s[4] = IMarketFacet.emergencyResolve.selector;
        s[5] = IMarketFacet.redeem.selector;
        s[6] = IMarketFacet.enableRefundMode.selector;
        s[7] = IMarketFacet.refund.selector;
        s[8] = IMarketFacet.sweepUnclaimed.selector;
        s[9] = IMarketFacet.approveOracle.selector;
        s[10] = IMarketFacet.revokeOracle.selector;
        s[11] = IMarketFacet.setFeeRecipient.selector;
        s[12] = IMarketFacet.setMarketCreationFee.selector;
        s[13] = IMarketFacet.setDefaultPerMarketCap.selector;
        s[14] = IMarketFacet.setPerMarketCap.selector;
        s[15] = IMarketFacet.getMarket.selector;
        s[16] = IMarketFacet.getMarketStatus.selector;
        s[17] = IMarketFacet.isOracleApproved.selector;
        s[18] = IMarketFacet.feeRecipient.selector;
        s[19] = IMarketFacet.marketCreationFee.selector;
        s[20] = IMarketFacet.defaultPerMarketCap.selector;
        s[21] = IMarketFacet.marketCount.selector;
        s[22] = IMarketFacet.setDefaultRedemptionFeeBps.selector;
        s[23] = IMarketFacet.setPerMarketRedemptionFeeBps.selector;
        s[24] = IMarketFacet.clearPerMarketRedemptionFee.selector;
        s[25] = IMarketFacet.defaultRedemptionFeeBps.selector;
        s[26] = IMarketFacet.effectiveRedemptionFeeBps.selector;
        s[27] = IMarketFacet.rescueSurplus.selector;
        s[28] = IMarketFacet.totalCollateralLocked.selector;
        s[29] = IMarketFacet.setOutcomeTokenImpl.selector;
        s[30] = IMarketFacet.outcomeTokenImpl.selector;
    }

    /// @dev All 10 EventFacet selectors (audit C-3): REPLACE the complete set so no old, unguarded impl
    ///      remains routed for `addEventOutcome` / `enableEventRefundMode`.
    function _eventSelectors() internal pure returns (bytes4[] memory s) {
        s = new bytes4[](10);
        s[0] = IEventFacet.createEvent.selector;
        s[1] = IEventFacet.addEventOutcome.selector;
        s[2] = IEventFacet.resolveEvent.selector;
        s[3] = IEventFacet.emergencyResolveEvent.selector;
        s[4] = IEventFacet.enableEventRefundMode.selector;
        s[5] = IEventFacet.sweepUnclaimedEvent.selector;
        s[6] = IEventFacet.getEvent.selector;
        s[7] = IEventFacet.getEventStatus.selector;
        s[8] = IEventFacet.eventOfMarket.selector;
        s[9] = IEventFacet.eventCount.selector;
    }

    function _linkedSelectors() internal pure returns (bytes4[] memory s) {
        s = new bytes4[](6);
        s[0] = ILinkedEventFacet.createLinkedEvent.selector;
        s[1] = ILinkedEventFacet.mintCompleteSet.selector;
        s[2] = ILinkedEventFacet.redeemCompleteSet.selector;
        s[3] = ILinkedEventFacet.redeemLinked.selector;
        s[4] = ILinkedEventFacet.eventPoolOf.selector;
        s[5] = ILinkedEventFacet.isLinkedEvent.selector;
    }
}
