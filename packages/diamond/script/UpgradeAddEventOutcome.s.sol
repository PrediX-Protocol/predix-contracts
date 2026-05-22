// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import {Script, console2} from "forge-std/Script.sol";

import {IDiamondCut} from "@predix/shared/interfaces/IDiamondCut.sol";
import {IEventFacet} from "@predix/shared/interfaces/IEventFacet.sol";

import {EventFacet} from "@predix/diamond/facets/event/EventFacet.sol";

interface ITimelockMinDelay {
    function getMinDelay() external view returns (uint256);
}

/// @title UpgradeAddEventOutcome
/// @notice Phase-1 upgrade: route the new `addEventOutcome` selector to a freshly
///         deployed `EventFacet` implementation. Minimal, ADD-only diamondCut — the
///         9 existing event selectors keep pointing at the live facet (identical
///         logic), so no working route is touched. The new impl shares the diamond's
///         event/market storage, so `addEventOutcome` operates on existing events.
/// @dev    The diamond's `diamondCut` is gated by CUT_EXECUTOR = Timelock; the
///         deployer no longer holds any role. This script therefore ONLY deploys the
///         new facet (broadcast) and PRINTS the exact `Timelock.schedule` /
///         `Timelock.execute` calldata for the team multisig to submit. Flow:
///           1. run this (deploys EventFacet impl)
///           2. multisig -> Timelock.schedule(...)   [the printed schedule calldata]
///           3. wait `minDelay` (dev-beta: 1h)
///           4. multisig -> Timelock.execute(...)     [the printed execute calldata]
contract UpgradeAddEventOutcome is Script {
    function run() external returns (address newEventFacet) {
        address diamond = vm.envAddress("DIAMOND_ADDRESS");
        address timelock = vm.envAddress("TIMELOCK_ADDRESS");

        // MNEMONIC (index 0) takes precedence over DEPLOYER_PRIVATE_KEY.
        uint256 deployerKey;
        string memory mnemonic = vm.envOr("MNEMONIC", string(""));
        if (bytes(mnemonic).length > 0) {
            deployerKey = vm.deriveKey(mnemonic, 0);
        } else {
            deployerKey = vm.envUint("DEPLOYER_PRIVATE_KEY");
        }

        vm.startBroadcast(deployerKey);
        EventFacet impl = new EventFacet();
        vm.stopBroadcast();
        newEventFacet = address(impl);

        // ADD-only cut: addEventOutcome -> new impl.
        bytes4[] memory addSels = new bytes4[](1);
        addSels[0] = IEventFacet.addEventOutcome.selector;
        IDiamondCut.FacetCut[] memory cuts = new IDiamondCut.FacetCut[](1);
        cuts[0] = IDiamondCut.FacetCut({
            facetAddress: newEventFacet,
            action: IDiamondCut.FacetCutAction.Add,
            functionSelectors: addSels
        });
        bytes memory cutCalldata = abi.encodeCall(IDiamondCut.diamondCut, (cuts, address(0), ""));

        bytes32 predecessor = bytes32(0);
        bytes32 salt = keccak256("predix.upgrade.addEventOutcome.v1");
        uint256 delay = ITimelockMinDelay(timelock).getMinDelay();

        bytes memory scheduleCalldata = abi.encodeWithSignature(
            "schedule(address,uint256,bytes,bytes32,bytes32,uint256)", diamond, 0, cutCalldata, predecessor, salt, delay
        );
        bytes memory executeCalldata = abi.encodeWithSignature(
            "execute(address,uint256,bytes,bytes32,bytes32)", diamond, 0, cutCalldata, predecessor, salt
        );

        console2.log("============================================================");
        console2.log("UpgradeAddEventOutcome (ADD-only diamondCut via Timelock)");
        console2.log("============================================================");
        console2.log("new EventFacet impl:", newEventFacet);
        console2.log("diamond:            ", diamond);
        console2.log("timelock:           ", timelock);
        console2.log("addEventOutcome selector:");
        console2.logBytes4(IEventFacet.addEventOutcome.selector);
        console2.log("salt:");
        console2.logBytes32(salt);
        console2.log("minDelay (seconds):", delay);
        console2.log("");
        console2.log(">> STEP A - multisig submits to Timelock (schedule). to =", timelock);
        console2.logBytes(scheduleCalldata);
        console2.log("");
        console2.log(">> STEP B - after minDelay, multisig submits to Timelock (execute). to =", timelock);
        console2.logBytes(executeCalldata);
    }
}
