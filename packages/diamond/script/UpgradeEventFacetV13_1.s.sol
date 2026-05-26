// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import {Script, console2} from "forge-std/Script.sol";

import {IDiamondCut} from "@predix/shared/interfaces/IDiamondCut.sol";
import {IEventFacet} from "@predix/shared/interfaces/IEventFacet.sol";

import {EventFacet} from "@predix/diamond/facets/event/EventFacet.sol";

interface ITimelockMinDelay {
    function getMinDelay() external view returns (uint256);
}

/// @title UpgradeEventFacetV13_1
/// @notice v1.3.1 patch — complete the v1.3 OutcomeTokenClone upgrade by
///         REPLACEing EventFacet + addEventOutcome facet too.
/// @dev    v1.3 cut only REPLACEd MarketFacet selectors. Because `LibMarket`
///         is an internal-function library, its `create()` body is INLINED at
///         compile time into every facet that calls it. EventFacet +
///         addEventOutcome facet were deployed BEFORE v1.3 and therefore have
///         the OLD `new OutcomeToken(...)` path baked into their bytecode —
///         calling `createEvent` / `addEventOutcome` against the live diamond
///         still pays the full ~787k gas per token deploy, blowing through
///         the ReentrancySentry OOG limit for events with 3+ candidates.
///
///         Fix: deploy ONE new EventFacet from current source (it inlines the
///         new Clones-based LibMarket) and REPLACE all 10 selectors at once
///         (9 currently on `0xA349…C35D`, 1 on `0x6be6Ba…bc97`) to point at
///         the single new impl. No _init needed — pure selector re-routing,
///         storage unchanged.
///
///         Required env: MNEMONIC (HD-0), DIAMOND_ADDRESS, TIMELOCK_ADDRESS,
///                       UNICHAIN_RPC_PRIMARY
contract UpgradeEventFacetV13_1 is Script {
    function run() external returns (address newEventFacet) {
        address diamond = vm.envAddress("DIAMOND_ADDRESS");
        address timelock = vm.envAddress("TIMELOCK_ADDRESS");

        string memory mnemonic = vm.envOr("MNEMONIC", string(""));
        uint256 deployerKey = bytes(mnemonic).length > 0
            ? vm.deriveKey(mnemonic, 0)
            : vm.envUint("DEPLOYER_PRIVATE_KEY");

        vm.startBroadcast(deployerKey);
        newEventFacet = address(new EventFacet());
        vm.stopBroadcast();

        bytes4[] memory selectors = _allEventSelectors();
        IDiamondCut.FacetCut[] memory cuts = new IDiamondCut.FacetCut[](1);
        cuts[0] = IDiamondCut.FacetCut({
            facetAddress: newEventFacet,
            action: IDiamondCut.FacetCutAction.Replace,
            functionSelectors: selectors
        });

        bytes memory cutCalldata = abi.encodeCall(IDiamondCut.diamondCut, (cuts, address(0), bytes("")));

        bytes32 predecessor = bytes32(0);
        bytes32 salt = keccak256("predix.upgrade.eventFacet.v1_3_1");
        uint256 delay = ITimelockMinDelay(timelock).getMinDelay();

        bytes memory scheduleCalldata = abi.encodeWithSignature(
            "schedule(address,uint256,bytes,bytes32,bytes32,uint256)",
            diamond, uint256(0), cutCalldata, predecessor, salt, delay
        );
        bytes memory executeCalldata = abi.encodeWithSignature(
            "execute(address,uint256,bytes,bytes32,bytes32)", diamond, uint256(0), cutCalldata, predecessor, salt
        );

        console2.log("============================================================");
        console2.log("UpgradeEventFacetV13_1 (REPLACE 10 selectors)");
        console2.log("============================================================");
        console2.log("new EventFacet impl:", newEventFacet);
        console2.log("diamond:            ", diamond);
        console2.log("timelock:           ", timelock);
        console2.log("salt:");
        console2.logBytes32(salt);
        console2.log("minDelay (s):", delay);
        console2.log("");
        console2.log(">> STEP A - multisig submits to Timelock (schedule). to =", timelock);
        console2.logBytes(scheduleCalldata);
        console2.log("");
        console2.log(">> STEP B - after minDelay, multisig submits to Timelock (execute). to =", timelock);
        console2.logBytes(executeCalldata);
        console2.log("");
        console2.log("RESULT_JSON:");
        console2.log(
            string.concat(
                "{\"newEventFacet\":\"", vm.toString(newEventFacet),
                "\",\"salt\":\"", vm.toString(salt),
                "\",\"minDelay\":", vm.toString(delay), "}"
            )
        );
    }

    /// @dev The 10 EventFacet selectors live on the diamond pre-cut:
    ///        - 9 routed to `0xA349…C35D` (createEvent / resolveEvent / etc.)
    ///        - 1 routed to `0x6be6Ba…bc97` (addEventOutcome) — added in a
    ///          later cut. Both impls have the SAME source, just compiled at
    ///          different points; both now get REPLACEd to the single new impl.
    function _allEventSelectors() internal pure returns (bytes4[] memory s) {
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
}
