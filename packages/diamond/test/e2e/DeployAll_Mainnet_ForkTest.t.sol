// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import {Test, Vm} from "forge-std/Test.sol";
import {Strings} from "@openzeppelin/contracts/utils/Strings.sol";

import {IPrediXHook} from "@predix/hook/interfaces/IPrediXHook.sol";

import {DeployAll} from "../../script/DeployAll.s.sol";
import {PostDeployVerify} from "../../script/PostDeployVerify.s.sol";

/// @title DeployAll_Mainnet_ForkTest
/// @notice Integration check that the production `DeployAll` script and the
///         `PostDeployVerify` postcheck both succeed on a fresh Unichain
///         mainnet fork bound to the canonical USDC / PoolManager / Quoter /
///         Permit2. Sets every env var the scripts read, invokes them
///         in-process, and asserts a clean handover to multisig + timelock.
///
///         Doubles as a regression for the DeployEnvVerifier pre-flight: the
///         deploy reverts immediately if Permit2 is non-canonical on the target
///         chain, so passing this test on the Unichain pin block is a positive
///         signal that canonical infrastructure remained at the expected
///         addresses.
///
/// @dev Required env vars (test reverts on missing — same as `MainnetForkFixture`):
///        - UNICHAIN_RPC_PRIMARY        Mainnet RPC
///        - UNICHAIN_MAINNET_PIN_BLOCK  Fork pin block
contract DeployAll_Mainnet_ForkTest is Test {
    // Canonical Unichain mainnet infra
    address internal constant UNICHAIN_USDC = 0x078D782b760474a361dDA0AF3839290b0EF57AD6;
    address internal constant UNICHAIN_POOL_MANAGER = 0x1F98400000000000000000000000000000000004;
    address internal constant UNICHAIN_V4_QUOTER = 0x333E3C607B141b18fF6de9f258db6e77fE7491E0;
    address internal constant CANONICAL_PERMIT2 = 0x000000000022D473030F116dDEE9F6B43aC78BA3;

    // Synthetic deployer; production deploy uses a real hardware-wallet signer.
    uint256 internal deployerKey = uint256(keccak256("DeployAll_Mainnet_ForkTest.deployer"));
    address internal deployer;

    // Synthetic admin/operational addresses — adequate for proving the script
    // wiring is correct; production replaces each with a real Safe.
    address internal multisig = makeAddr("multisig");
    address internal pauser = makeAddr("pauser");
    address internal operator = makeAddr("operator");
    address internal reporter = makeAddr("reporter");
    address internal feeRecipient = makeAddr("feeRecipient");
    address internal hookProxyAdmin = makeAddr("hookProxyAdmin");
    address internal hookRuntimeAdmin = makeAddr("hookRuntimeAdmin");
    address internal exchangeProxyAdmin = makeAddr("exchangeProxyAdmin");

    function setUp() public {
        deployer = vm.addr(deployerKey);

        string memory rpc = _requiredEnvString("UNICHAIN_RPC_PRIMARY");
        uint256 pinBlock = _requiredEnvUint("UNICHAIN_MAINNET_PIN_BLOCK");
        vm.createSelectFork(rpc, pinBlock);

        vm.deal(deployer, 10 ether);

        _writeEnv();
    }

    /// @dev DeployAll runs end-to-end against canonical Unichain mainnet
    ///      infrastructure and PostDeployVerify confirms the resulting wiring.
    ///      A revert here is the most important pre-mainnet signal — either the
    ///      script regressed or canonical infra moved.
    function test_DeployAll_RunsClean_AndPostDeployVerifyPasses() public {
        DeployAll script = new DeployAll();
        DeployAll.Addresses memory out = script.run();

        // Sanity: every deployed slot must be populated.
        assertTrue(out.timelock != address(0), "timelock not set");
        assertTrue(out.diamond != address(0), "diamond not set");
        assertTrue(out.manualOracle != address(0), "manualOracle not set");
        assertTrue(out.hookProxy != address(0), "hookProxy not set");
        assertTrue(out.exchangeProxy != address(0), "exchangeProxy not set");
        assertTrue(out.router != address(0), "router not set");

        // The hook admin rotation is two-step: DeployAll calls
        // `setAdmin(hookRuntimeAdmin)` which queues the change behind a 48h
        // `ADMIN_ROTATION_DELAY`. The incoming admin must call `acceptAdmin`
        // after the delay to land the rotation. Simulate the operator's
        // post-deploy step so PostDeployVerify sees the final wiring.
        vm.warp(block.timestamp + 48 hours + 1);
        vm.prank(hookRuntimeAdmin);
        IPrediXHook(out.hookProxy).acceptAdmin();

        // Write the post-deploy env block so PostDeployVerify can find them.
        vm.setEnv("DIAMOND_ADDRESS", Strings.toHexString(out.diamond));
        vm.setEnv("HOOK_PROXY_ADDRESS", Strings.toHexString(out.hookProxy));
        vm.setEnv("EXCHANGE_ADDRESS", Strings.toHexString(out.exchangeProxy));
        vm.setEnv("ROUTER_ADDRESS", Strings.toHexString(out.router));
        vm.setEnv("ORACLE_MANUAL_ADDRESS", Strings.toHexString(out.manualOracle));
        vm.setEnv("TIMELOCK_ADDRESS", Strings.toHexString(out.timelock));
        vm.setEnv("DEPLOYER_ADDRESS", Strings.toHexString(deployer));

        PostDeployVerify verify = new PostDeployVerify();
        verify.run();
    }

    // ---------------------------------------------------------------- env ---

    function _writeEnv() internal {
        vm.setEnv("DEPLOYER_PRIVATE_KEY", Strings.toHexString(deployerKey, 32));
        vm.setEnv("MULTISIG_ADDRESS", Strings.toHexString(multisig));
        vm.setEnv("PAUSER_ADDRESS", Strings.toHexString(pauser));
        vm.setEnv("OPERATOR_ADDRESS", Strings.toHexString(operator));
        vm.setEnv("REPORTER_ADDRESS", Strings.toHexString(reporter));
        vm.setEnv("FEE_RECIPIENT", Strings.toHexString(feeRecipient));
        vm.setEnv("HOOK_PROXY_ADMIN", Strings.toHexString(hookProxyAdmin));
        vm.setEnv("HOOK_RUNTIME_ADMIN", Strings.toHexString(hookRuntimeAdmin));
        vm.setEnv("EXCHANGE_PROXY_ADMIN", Strings.toHexString(exchangeProxyAdmin));
        vm.setEnv("TIMELOCK_DELAY_SECONDS", "172800"); // 48h
        vm.setEnv("USDC_ADDRESS", Strings.toHexString(UNICHAIN_USDC));
        vm.setEnv("POOL_MANAGER_ADDRESS", Strings.toHexString(UNICHAIN_POOL_MANAGER));
        vm.setEnv("PERMIT2_ADDRESS", Strings.toHexString(CANONICAL_PERMIT2));
        vm.setEnv("V4_QUOTER_ADDRESS", Strings.toHexString(UNICHAIN_V4_QUOTER));

        // Beta posture: ManualOracle only — Unichain has no published Chainlink
        // sequencer feed at the time of writing. Production may flip this once
        // Chainlink publishes a feed.
        vm.setEnv("CHAINLINK_ENABLED", "false");

        vm.setEnv("MARKET_CREATION_FEE", "10000000"); // 10 USDC (raw, 6dp)
        vm.setEnv("DEFAULT_PER_MARKET_CAP", "50000000000"); // 50k USDC
        vm.setEnv("DEFAULT_REDEMPTION_FEE_BPS", "100"); // 1.00%
        vm.setEnv("LP_FEE_FLAG", "8388608"); // 0x800000 dynamic fee flag
        vm.setEnv("TICK_SPACING", "60");
        vm.setEnv("DIAMOND_FINALIZE_GOVERNANCE", "true");
    }

    function _requiredEnvString(string memory key) internal view returns (string memory) {
        string memory v = vm.envOr(key, string(""));
        if (bytes(v).length == 0) revert(string.concat("required env var unset: ", key));
        return v;
    }

    function _requiredEnvUint(string memory key) internal view returns (uint256) {
        return vm.envUint(key);
    }
}
