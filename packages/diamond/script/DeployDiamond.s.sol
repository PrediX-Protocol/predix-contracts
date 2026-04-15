// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Script, console2} from "forge-std/Script.sol";

import {DiamondDeployLib} from "./lib/DiamondDeployLib.sol";

/// @title DeployDiamond
/// @notice Standalone script that deploys the PrediX diamond + all facets, runs both inits
///         (DiamondInit + MarketInit), approves oracles if provided, and optionally hands
///         governance over to the multisig + Timelock in a single broadcast.
///
///         Deployer temporarily holds every admin role (incl. CUT_EXECUTOR_ROLE) so that
///         the second diamondCut + oracle approvals can happen inside the same transaction
///         batch. Final handover is mandatory — if `DIAMOND_FINALIZE_GOVERNANCE=true` the
///         script asserts the post-deploy role layout before returning.
///
///         Chaining for `DeployAll` is done via the `DiamondDeployLib` library — this script
///         is only used to deploy the diamond in isolation for testnet experiments.
contract DeployDiamond is Script {
    using DiamondDeployLib for DiamondDeployLib.FacetAddresses;

    function run() external returns (address diamond, DiamondDeployLib.FacetAddresses memory facets) {
        address deployer = vm.addr(vm.envUint("DEPLOYER_PRIVATE_KEY"));
        address multisig = vm.envAddress("MULTISIG_ADDRESS");
        address timelock = vm.envAddress("TIMELOCK_ADDRESS");
        address usdc = vm.envAddress("USDC_ADDRESS");
        address feeRecipient = vm.envAddress("FEE_RECIPIENT");
        uint256 marketCreationFee = vm.envUint("MARKET_CREATION_FEE");
        uint256 defaultPerMarketCap = vm.envUint("DEFAULT_PER_MARKET_CAP");
        bool finalize = vm.envBool("DIAMOND_FINALIZE_GOVERNANCE");

        vm.startBroadcast(vm.envUint("DEPLOYER_PRIVATE_KEY"));

        facets = DiamondDeployLib.deployFacets();
        diamond = DiamondDeployLib.deployDiamondWithDeployerAdmin(facets, deployer);
        DiamondDeployLib.wireMarketAndEvent(diamond, facets, usdc, feeRecipient, marketCreationFee, defaultPerMarketCap);

        if (finalize) {
            DiamondDeployLib.transferGovernance(diamond, deployer, multisig, timelock);
        }

        vm.stopBroadcast();

        if (finalize) DiamondDeployLib.verifyPostDeploy(diamond, facets, multisig, timelock);

        console2.log("Diamond:", diamond);
        console2.log("  cut facet:", facets.cut);
        console2.log("  loupe facet:", facets.loupe);
        console2.log("  access facet:", facets.access);
        console2.log("  pausable facet:", facets.pausable);
        console2.log("  market facet:", facets.market);
        console2.log("  event facet:", facets.eventF);
        console2.log("  diamond init:", facets.diamondInit);
        console2.log("  market init:", facets.marketInit);
        console2.log("  finalized governance:", finalize);
    }
}
