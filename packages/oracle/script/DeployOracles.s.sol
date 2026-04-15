// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Script, console2} from "forge-std/Script.sol";

import {ChainlinkOracle} from "@predix/oracle/adapters/ChainlinkOracle.sol";
import {ManualOracle} from "@predix/oracle/adapters/ManualOracle.sol";

/// @title DeployOracles
/// @notice Deploys `ManualOracle` and — when `CHAINLINK_ENABLED=true` — `ChainlinkOracle`,
///         grants the reporter/registrar role to env-specified addresses, and leaves the
///         post-deploy `IMarketFacet.approveOracle(...)` call to the orchestrator because
///         that call requires `ADMIN_ROLE` on the diamond.
///
///         Unichain Sepolia does not currently expose Chainlink data feeds; set
///         `CHAINLINK_ENABLED=false` there. Set `true` on Unichain mainnet once feeds are
///         registered. `CHAINLINK_SEQUENCER_UPTIME_FEED` may be left blank on L1 — pass
///         `address(0)` to skip the sequencer-up check (legitimate optional per
///         `ChainlinkOracle` NatSpec lines 24-27).
contract DeployOracles is Script {
    struct Deployed {
        address manual;
        address chainlink;
    }

    function run() external returns (Deployed memory out) {
        address multisig = vm.envAddress("MULTISIG_ADDRESS");
        address diamond = vm.envAddress("DIAMOND_ADDRESS");
        address reporter = vm.envAddress("REPORTER_ADDRESS");
        bool chainlinkEnabled = vm.envBool("CHAINLINK_ENABLED");

        vm.startBroadcast(vm.envUint("DEPLOYER_PRIVATE_KEY"));
        out = _deploy(multisig, diamond, reporter, chainlinkEnabled);
        vm.stopBroadcast();

        console2.log("ManualOracle:", out.manual);
        if (chainlinkEnabled) {
            console2.log("ChainlinkOracle:", out.chainlink);
        } else {
            console2.log("ChainlinkOracle: SKIPPED (CHAINLINK_ENABLED=false)");
        }
    }

    /// @dev Shared deploy helper used by `DeployAll`. Assumes a broadcast scope is
    ///      already open.
    function deploy(address multisig, address diamond, address reporter, bool chainlinkEnabled)
        external
        returns (Deployed memory)
    {
        return _deploy(multisig, diamond, reporter, chainlinkEnabled);
    }

    function _deploy(address multisig, address diamond, address reporter, bool chainlinkEnabled)
        internal
        returns (Deployed memory out)
    {
        ManualOracle manualOracle = new ManualOracle(multisig, diamond);
        manualOracle.grantRole(manualOracle.REPORTER_ROLE(), reporter);
        out.manual = address(manualOracle);

        if (chainlinkEnabled) {
            address registrar = vm.envAddress("REGISTRAR_ADDRESS");
            // Legitimate optional (Loại A): sequencerUptimeFeed = address(0) on L1 or on
            // testnets where Chainlink has not deployed the sequencer feed yet. Documented
            // in ChainlinkOracle.sol lines 24-27.
            address sequencerFeed = vm.envOr("CHAINLINK_SEQUENCER_UPTIME_FEED", address(0));
            ChainlinkOracle chainlinkOracle = new ChainlinkOracle(multisig, sequencerFeed);
            chainlinkOracle.grantRole(chainlinkOracle.REGISTRAR_ROLE(), registrar);
            out.chainlink = address(chainlinkOracle);
        }
    }
}
