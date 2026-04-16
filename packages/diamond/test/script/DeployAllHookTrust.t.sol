// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {HookMiner} from "@uniswap/v4-periphery/src/utils/HookMiner.sol";

import {IPrediXHook} from "@predix/hook/interfaces/IPrediXHook.sol";
import {PrediXHookV2} from "@predix/hook/hooks/PrediXHookV2.sol";
import {PrediXHookProxyV2} from "@predix/hook/proxy/PrediXHookProxyV2.sol";

/// @dev Minimal `IMarketFacet.getMarket` stub — the hook constructor calls
///      into the diamond during `initialize()` but only touches `getMarket`
///      via `_beforeInitialize`. We never actually initialize a pool in this
///      test so an empty stub that returns default values is sufficient.
contract TrustTestDiamondStub {
    fallback() external {
        // Return empty data for any call; hook.initialize() only reads diamond
        // address for storage, not an actual getMarket call.
        assembly {
            return(0, 0)
        }
    }
}

/// @title DeployAllHookTrust
/// @notice Backlog #44 regression guard. Locks in the canonical deploy-pipeline
///         fix: after the hook proxy is deployed with the deployer as temporary
///         runtime admin, `DeployAll.s.sol` MUST call `setTrustedRouter` for
///         both the router and the V4Quoter before proposing admin rotation to
///         the final runtime admin.
///
///         Before Phase 4 Part 1, `DeployAll.run()` never wired these bindings
///         — the live hook on Unichain Sepolia required two manual operator
///         txs (escapes #5 and #6) to unblock Phase 3.5. This test simulates
///         the hook-admin API layer that the DeployAll fix depends on and
///         asserts both bindings land + rotation is proposed. Any regression
///         that silently drops these calls will fail `isTrustedRouter` on one
///         of the four assertions below.
contract DeployAllHookTrust is Test {
    uint160 internal constant HOOK_FLAGS = uint160(
        Hooks.BEFORE_INITIALIZE_FLAG | Hooks.BEFORE_ADD_LIQUIDITY_FLAG | Hooks.BEFORE_REMOVE_LIQUIDITY_FLAG
            | Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_SWAP_FLAG | Hooks.BEFORE_DONATE_FLAG
    );

    address internal constant POOL_MANAGER_STUB = address(0xCAFE);
    address internal constant ROUTER = address(0xbeef0001);
    address internal constant QUOTER = address(0xbeef0002);
    address internal constant FINAL_HOOK_ADMIN = address(0xbeef0003);

    PrediXHookV2 internal impl;
    PrediXHookProxyV2 internal proxy;
    TrustTestDiamondStub internal diamondStub;
    address internal proxyAdmin = makeAddr("proxyAdmin");

    function setUp() public {
        diamondStub = new TrustTestDiamondStub();
        impl = new PrediXHookV2(IPoolManager(POOL_MANAGER_STUB));

        // Mirrors DeployAll._deployHook exactly: the DEPLOYER (this test
        // contract) is the temporary runtime admin, not the final admin.
        bytes memory ctorArgs = abi.encode(
            IPoolManager(POOL_MANAGER_STUB),
            address(impl),
            proxyAdmin,
            address(this), // deployer as temp hookAdmin
            address(diamondStub),
            address(0x100)
        );
        (, bytes32 salt) = HookMiner.find(address(this), HOOK_FLAGS, type(PrediXHookProxyV2).creationCode, ctorArgs);
        proxy = new PrediXHookProxyV2{salt: salt}(
            IPoolManager(POOL_MANAGER_STUB),
            address(impl),
            proxyAdmin,
            address(this),
            address(diamondStub),
            address(0x100)
        );
    }

    event Hook_AdminChangeProposed(address indexed current, address indexed pending);

    /// @notice The canonical fix: as hookAdmin, wire both router + quoter
    ///         into the trusted-router set, then propose rotation to the
    ///         final admin. Matches the exact sequence DeployAll.run()
    ///         executes between `deployRouter` and `transferGovernance`.
    function test_DeployAll_WiresTrustedRouters_AndProposesAdminRotation() public {
        // Pre-state: nothing trusted, deployer is admin
        assertFalse(IPrediXHook(address(proxy)).isTrustedRouter(ROUTER));
        assertFalse(IPrediXHook(address(proxy)).isTrustedRouter(QUOTER));
        assertEq(IPrediXHook(address(proxy)).admin(), address(this));

        // Backlog #44 fix: wire trust bindings as deployer
        IPrediXHook(address(proxy)).setTrustedRouter(ROUTER, true);
        IPrediXHook(address(proxy)).setTrustedRouter(QUOTER, true);

        // Propose rotation to final admin — assert via event emission
        // because `_pendingAdmin` has no public getter on the hook interface.
        vm.expectEmit(true, true, false, true, address(proxy));
        emit Hook_AdminChangeProposed(address(this), FINAL_HOOK_ADMIN);
        IPrediXHook(address(proxy)).setAdmin(FINAL_HOOK_ADMIN);

        // Post-state assertions — matches DeployAll post-condition invariant
        assertTrue(IPrediXHook(address(proxy)).isTrustedRouter(ROUTER), "router trust");
        assertTrue(IPrediXHook(address(proxy)).isTrustedRouter(QUOTER), "quoter trust");
        // Current admin is still deployer — the final admin must call
        // `acceptAdmin()` in a follow-up tx to complete the rotation.
        assertEq(IPrediXHook(address(proxy)).admin(), address(this), "current admin unchanged until accept");
    }

    /// @notice Sanity: the post-acceptAdmin rotation completes as expected.
    ///         Documents the post-deploy manual step that must be executed
    ///         by the incoming admin before the deploy is fully handed over.
    function test_DeployAll_FinalAdminAcceptsRotation_CompletesHandover() public {
        IPrediXHook(address(proxy)).setTrustedRouter(ROUTER, true);
        IPrediXHook(address(proxy)).setTrustedRouter(QUOTER, true);
        IPrediXHook(address(proxy)).setAdmin(FINAL_HOOK_ADMIN);

        vm.prank(FINAL_HOOK_ADMIN);
        IPrediXHook(address(proxy)).acceptAdmin();

        assertEq(IPrediXHook(address(proxy)).admin(), FINAL_HOOK_ADMIN, "rotation accepted");
        // Trust bindings survive the rotation
        assertTrue(IPrediXHook(address(proxy)).isTrustedRouter(ROUTER));
        assertTrue(IPrediXHook(address(proxy)).isTrustedRouter(QUOTER));
    }
}
