// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import {Script, console2} from "forge-std/Script.sol";
import {IDiamondCut} from "@predix/shared/interfaces/IDiamondCut.sol";
import {IMarketFacet} from "@predix/shared/interfaces/IMarketFacet.sol";
import {OutcomeTokenImplInit} from "@predix/diamond/init/OutcomeTokenImplInit.sol";

/// @notice No-deploy: rebuilds Timelock schedule/execute calldata from already-deployed addresses.
contract PrintUpgradeCalldata is Script {
    function run() external view {
        address diamond = vm.envAddress("DIAMOND_ADDRESS");
        address newFacet = vm.envAddress("NEW_MARKET_FACET");
        address master = vm.envAddress("OUTCOME_TOKEN_IMPL");
        address initContract = vm.envAddress("INIT_CONTRACT");
        bytes32 salt = vm.envBytes32("UPGRADE_SALT");
        uint256 delay = vm.envOr("MIN_DELAY", uint256(3600));

        bytes4[] memory replaceSels = _existingMarketSelectors();
        bytes4[] memory addSels = new bytes4[](2);
        addSels[0] = IMarketFacet.setOutcomeTokenImpl.selector;
        addSels[1] = IMarketFacet.outcomeTokenImpl.selector;

        IDiamondCut.FacetCut[] memory cuts = new IDiamondCut.FacetCut[](2);
        cuts[0] = IDiamondCut.FacetCut({
            facetAddress: newFacet, action: IDiamondCut.FacetCutAction.Replace, functionSelectors: replaceSels
        });
        cuts[1] = IDiamondCut.FacetCut({
            facetAddress: newFacet, action: IDiamondCut.FacetCutAction.Add, functionSelectors: addSels
        });

        bytes memory initData = abi.encodeCall(OutcomeTokenImplInit.init, (master));
        bytes memory cutCalldata = abi.encodeCall(IDiamondCut.diamondCut, (cuts, initContract, initData));

        bytes32 predecessor = bytes32(0);
        bytes memory scheduleCalldata = abi.encodeWithSignature(
            "schedule(address,uint256,bytes,bytes32,bytes32,uint256)",
            diamond, uint256(0), cutCalldata, predecessor, salt, delay
        );
        bytes memory executeCalldata = abi.encodeWithSignature(
            "execute(address,uint256,bytes,bytes32,bytes32)", diamond, uint256(0), cutCalldata, predecessor, salt
        );

        console2.log("salt:");
        console2.logBytes32(salt);
        console2.log("minDelay:", delay);
        console2.log("");
        console2.log("SCHEDULE_CALLDATA:");
        console2.logBytes(scheduleCalldata);
        console2.log("");
        console2.log("EXECUTE_CALLDATA:");
        console2.logBytes(executeCalldata);
    }

    function _existingMarketSelectors() internal pure returns (bytes4[] memory s) {
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
