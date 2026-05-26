// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import {Script, console2} from "forge-std/Script.sol";

import {IDiamondCut} from "@predix/shared/interfaces/IDiamondCut.sol";
import {IMarketFacet} from "@predix/shared/interfaces/IMarketFacet.sol";

import {MarketFacet} from "@predix/diamond/facets/market/MarketFacet.sol";
import {OutcomeTokenImplInit} from "@predix/diamond/init/OutcomeTokenImplInit.sol";
import {OutcomeTokenClone} from "@predix/shared/tokens/OutcomeTokenClone.sol";

interface ITimelockMinDelay {
    function getMinDelay() external view returns (uint256);
}

/// @title UpgradeOutcomeTokenClone
/// @notice v1.3 upgrade: switch `LibMarket.create` from `new OutcomeToken(...)` to
///         EIP-1167 `Clones.clone(impl)` + `initialize(...)`. Cuts ~76% off the
///         per-market token-deploy gas (≈1.25M gas saved per market).
/// @dev    Cut shape:
///           - REPLACE all 29 existing MarketFacet selectors → new MarketFacet
///             (logic re-routes createMarket through the new LibMarket which
///              clones instead of CREATE2-deploying a fresh contract)
///           - ADD 2 new selectors: setOutcomeTokenImpl, outcomeTokenImpl
///           - _init = OutcomeTokenImplInit.init(masterImpl) — atomic, so
///             createMarket has a valid impl pointer the moment the cut returns
///
///         Required env: MNEMONIC (HD-0), DIAMOND_ADDRESS, TIMELOCK_ADDRESS,
///                       UNICHAIN_RPC_PRIMARY
///
///         Flow:
///           1. forge script ... --broadcast        (deploys: MarketFacet impl,
///              OutcomeTokenClone master, OutcomeTokenImplInit. Prints schedule
///              & execute calldata.)
///           2. multisig → Timelock.schedule(...)    [printed scheduleCalldata]
///           3. wait `minDelay` (dev-beta: 1h)
///           4. multisig → Timelock.execute(...)     [printed executeCalldata]
///           5. (already atomic — no follow-up admin call needed)
contract UpgradeOutcomeTokenClone is Script {
    function run() external returns (address newFacet, address master, address initContract) {
        address diamond = vm.envAddress("DIAMOND_ADDRESS");
        address timelock = vm.envAddress("TIMELOCK_ADDRESS");

        string memory mnemonic = vm.envOr("MNEMONIC", string(""));
        uint256 deployerKey = bytes(mnemonic).length > 0
            ? vm.deriveKey(mnemonic, 0)
            : vm.envUint("DEPLOYER_PRIVATE_KEY");

        vm.startBroadcast(deployerKey);
        newFacet = address(new MarketFacet());
        master = address(new OutcomeTokenClone(diamond));
        initContract = address(new OutcomeTokenImplInit());
        vm.stopBroadcast();

        // REPLACE selectors (the 29 already on the diamond)
        bytes4[] memory replaceSels = _existingMarketSelectors();

        // ADD selectors (the 2 new ones from v1.3)
        bytes4[] memory addSels = new bytes4[](2);
        addSels[0] = IMarketFacet.setOutcomeTokenImpl.selector;
        addSels[1] = IMarketFacet.outcomeTokenImpl.selector;

        IDiamondCut.FacetCut[] memory cuts = new IDiamondCut.FacetCut[](2);
        cuts[0] = IDiamondCut.FacetCut({
            facetAddress: newFacet,
            action: IDiamondCut.FacetCutAction.Replace,
            functionSelectors: replaceSels
        });
        cuts[1] = IDiamondCut.FacetCut({
            facetAddress: newFacet,
            action: IDiamondCut.FacetCutAction.Add,
            functionSelectors: addSels
        });

        bytes memory initData = abi.encodeCall(OutcomeTokenImplInit.init, (master));
        bytes memory cutCalldata = abi.encodeCall(IDiamondCut.diamondCut, (cuts, initContract, initData));

        bytes32 predecessor = bytes32(0);
        bytes32 salt = keccak256("predix.upgrade.outcomeTokenClone.v1");
        uint256 delay = ITimelockMinDelay(timelock).getMinDelay();

        bytes memory scheduleCalldata = abi.encodeWithSignature(
            "schedule(address,uint256,bytes,bytes32,bytes32,uint256)",
            diamond, uint256(0), cutCalldata, predecessor, salt, delay
        );
        bytes memory executeCalldata = abi.encodeWithSignature(
            "execute(address,uint256,bytes,bytes32,bytes32)", diamond, uint256(0), cutCalldata, predecessor, salt
        );

        console2.log("============================================================");
        console2.log("UpgradeOutcomeTokenClone (REPLACE 29 + ADD 2 + atomic init)");
        console2.log("============================================================");
        console2.log("new MarketFacet impl:    ", newFacet);
        console2.log("OutcomeTokenClone master:", master);
        console2.log("OutcomeTokenImplInit:    ", initContract);
        console2.log("diamond:                 ", diamond);
        console2.log("timelock:                ", timelock);
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
                "{\"newMarketFacet\":\"", vm.toString(newFacet),
                "\",\"outcomeTokenImpl\":\"", vm.toString(master),
                "\",\"init\":\"", vm.toString(initContract),
                "\",\"salt\":\"", vm.toString(salt),
                "\",\"minDelay\":", vm.toString(delay), "}"
            )
        );
    }

    function _existingMarketSelectors() internal pure returns (bytes4[] memory s) {
        // The 29 selectors registered at the original mainnet diamond cut.
        // MUST match exactly what is currently routed to the old MarketFacet —
        // any mismatch → `diamondCut` reverts (REPLACE requires the selector
        // already exist on the diamond).
        s = new bytes4[](29);
        s[0]  = IMarketFacet.createMarket.selector;
        s[1]  = IMarketFacet.splitPosition.selector;
        s[2]  = IMarketFacet.mergePositions.selector;
        s[3]  = IMarketFacet.resolveMarket.selector;
        s[4]  = IMarketFacet.emergencyResolve.selector;
        s[5]  = IMarketFacet.redeem.selector;
        s[6]  = IMarketFacet.enableRefundMode.selector;
        s[7]  = IMarketFacet.refund.selector;
        s[8]  = IMarketFacet.sweepUnclaimed.selector;
        s[9]  = IMarketFacet.approveOracle.selector;
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
    }
}
