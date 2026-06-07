// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import {Script, console2} from "forge-std/Script.sol";

import {IDiamondCut} from "@predix/shared/interfaces/IDiamondCut.sol";
import {IDiamondLoupe} from "@predix/shared/interfaces/IDiamondLoupe.sol";
import {IEventFacet} from "@predix/shared/interfaces/IEventFacet.sol";

import {EventFacet} from "@predix/diamond/facets/event/EventFacet.sol";

interface ITimelockMinDelay {
    function getMinDelay() external view returns (uint256);
}

/// @title ConsolidateEventFacet
/// @notice Consolidation diamond cut: multi-outcome = shared-collateral ONLY. One atomic cut —
///         REPLACE the event lifecycle/view selectors (including `eventPoolOf`, which moves off the
///         retired LinkedEventFacet) onto the consolidated `EventFacet` whose `createEvent` now
///         creates shared-pool events, ADD `splitEvent`/`mergeEvent`/`redeemEvent`, and REMOVE the
///         legacy selectors (`createLinkedEvent`, `mintCompleteSet`, `redeemCompleteSet`,
///         `redeemLinked`, `isLinkedEvent`, `addEventOutcome`). Storage is untouched (append-only);
///         pre-consolidation legacy events keep their full lifecycle (`linked == false` branches).
/// @dev DRY-RUN ONLY — deploys the facet and PRINTS the Timelock schedule/execute calldata for the
///      multisig to submit; it never broadcasts the cut itself. The single atomic cut is mandatory:
///      `createEvent`'s behavior flip and the legacy-selector removal must land together, or a
///      window exists where unlinked events can still be created against the new engine.
///      Verified by `test/fork/ConsolidationCutForkSim.t.sol` (no-brick + rollback) before any
///      mainnet schedule. Required env: MNEMONIC (HD-0) or DEPLOYER_PRIVATE_KEY, DIAMOND_ADDRESS,
///      TIMELOCK_ADDRESS.
contract ConsolidateEventFacet is Script {
    function run() external returns (address eventFacet) {
        address diamond = vm.envAddress("DIAMOND_ADDRESS");
        address timelock = vm.envAddress("TIMELOCK_ADDRESS");

        // Pre-flight (skipped on a pure local dry-run where the diamond has no code): every Replace
        // target must be live, every Add target unrouted, every Remove target routed — else the
        // Timelock `execute` reverts mid-cut AFTER the delay (a wasted cycle, not a brick).
        if (diamond.code.length > 0) _assertCutPreconditions(diamond);

        string memory mnemonic = vm.envOr("MNEMONIC", string(""));
        uint256 deployerKey =
            bytes(mnemonic).length > 0 ? vm.deriveKey(mnemonic, 0) : vm.envUint("DEPLOYER_PRIVATE_KEY");

        vm.startBroadcast(deployerKey);
        eventFacet = address(new EventFacet());
        vm.stopBroadcast();

        bytes memory cutCalldata =
            abi.encodeCall(IDiamondCut.diamondCut, (buildCuts(eventFacet), address(0), bytes("")));

        bytes32 predecessor = bytes32(0);
        bytes32 salt = keccak256("predix.upgrade.consolidate.eventFacet.v1");
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

        console2.log("=== Consolidation cut (DRY RUN - nothing scheduled) ===");
        console2.log("EventFacet (consolidated):", eventFacet);
        console2.log("Timelock:", timelock);
        console2.log("Diamond:", diamond);
        console2.log("Timelock min delay (s):", delay);
        console2.log("--- schedule() calldata (target = timelock) ---");
        console2.logBytes(scheduleCalldata);
        console2.log("--- execute() calldata (target = timelock, after delay) ---");
        console2.logBytes(executeCalldata);
    }

    /// @notice The full consolidation cut against `facet`. Public so the fork sim shares the exact
    ///         selector lists (single source of truth).
    function buildCuts(address facet) public pure returns (IDiamondCut.FacetCut[] memory cuts) {
        cuts = new IDiamondCut.FacetCut[](3);
        cuts[0] = IDiamondCut.FacetCut({
            facetAddress: facet, action: IDiamondCut.FacetCutAction.Replace, functionSelectors: replaceSelectors()
        });
        cuts[1] = IDiamondCut.FacetCut({
            facetAddress: facet, action: IDiamondCut.FacetCutAction.Add, functionSelectors: addSelectors()
        });
        cuts[2] = IDiamondCut.FacetCut({
            facetAddress: address(0), action: IDiamondCut.FacetCutAction.Remove, functionSelectors: removeSelectors()
        });
    }

    /// @notice Live selectors that move to the consolidated facet. `eventPoolOf` is live on the
    ///         retired LinkedEventFacet (same signature), so it is a Replace, not an Add.
    function replaceSelectors() public pure returns (bytes4[] memory s) {
        s = new bytes4[](10);
        s[0] = IEventFacet.createEvent.selector;
        s[1] = IEventFacet.resolveEvent.selector;
        s[2] = IEventFacet.emergencyResolveEvent.selector;
        s[3] = IEventFacet.enableEventRefundMode.selector;
        s[4] = IEventFacet.getEvent.selector;
        s[5] = IEventFacet.getEventStatus.selector;
        s[6] = IEventFacet.eventOfMarket.selector;
        s[7] = IEventFacet.eventCount.selector;
        s[8] = IEventFacet.sweepUnclaimedEvent.selector;
        s[9] = IEventFacet.eventPoolOf.selector;
    }

    function addSelectors() public pure returns (bytes4[] memory s) {
        s = new bytes4[](3);
        s[0] = IEventFacet.splitEvent.selector;
        s[1] = IEventFacet.mergeEvent.selector;
        s[2] = IEventFacet.redeemEvent.selector;
    }

    /// @notice Retired legacy selectors (raw 4-byte ids — the functions no longer exist in source):
    ///         createLinkedEvent, mintCompleteSet, redeemCompleteSet, redeemLinked, isLinkedEvent,
    ///         addEventOutcome.
    function removeSelectors() public pure returns (bytes4[] memory s) {
        s = new bytes4[](6);
        s[0] = 0xa4128ef7; // createLinkedEvent(string,string[],uint256,address)
        s[1] = 0x8578313a; // mintCompleteSet(uint256,uint256)
        s[2] = 0x754c7ec3; // redeemCompleteSet(uint256,uint256)
        s[3] = 0xf1f30c1a; // redeemLinked(uint256)
        s[4] = 0xc3bacd82; // isLinkedEvent(uint256)
        s[5] = 0x1a0dcf36; // addEventOutcome(uint256,string)
    }

    function _assertCutPreconditions(address diamond) private view {
        IDiamondLoupe loupe = IDiamondLoupe(diamond);
        bytes4[] memory rep = replaceSelectors();
        for (uint256 i; i < rep.length; ++i) {
            require(loupe.facetAddress(rep[i]) != address(0), "pre-flight: Replace target not live");
        }
        bytes4[] memory add = addSelectors();
        for (uint256 i; i < add.length; ++i) {
            require(loupe.facetAddress(add[i]) == address(0), "pre-flight: Add target already routed");
        }
        bytes4[] memory rem = removeSelectors();
        for (uint256 i; i < rem.length; ++i) {
            require(loupe.facetAddress(rem[i]) != address(0), "pre-flight: Remove target not routed");
        }
    }
}
