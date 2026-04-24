// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {IAccessControlFacet} from "@predix/shared/interfaces/IAccessControlFacet.sol";
import {Roles} from "@predix/shared/constants/Roles.sol";

/// @notice Shared base for Phase 7 end-to-end fork tests.
/// @dev    Pins to Unichain Sepolia (chainId 1301) at a block taken after the
///         Phase 7 deploy + admin rotation. Derived contracts assert behaviour
///         of the live contracts using real on-chain state; state mutations
///         are simulated via cheatcodes (`vm.prank`, `deal`, `vm.warp`) and
///         never broadcast to the chain.
abstract contract Phase7ForkBase is Test {
    // -----------------------------------------------------------------
    // Phase 7 deployed addresses (Unichain Sepolia, chainId 1301)
    // -----------------------------------------------------------------

    address internal constant DIAMOND = 0xC069159180dC0b507c7eDBF297c5Ad8af49F1CA1;
    address internal constant TIMELOCK = 0xA35eCa70c8272ffd5ebE713Bac8Fef7Cb1fB7B73;
    address internal constant MANUAL_ORACLE = 0x3AE53c6D38486aF41444963F8cdf7BbC320EDFf1;
    address internal constant HOOK_PROXY = 0x5eF25d02ABC9C89b311B7585794581E0e0956AE0;
    address internal constant HOOK_IMPL = 0x130a93CC42F723893F48646639cE6d4d06544257;
    address internal constant EXCHANGE = 0xdEE07224A80D6b19213b33F942258233FDa07071;
    address internal constant ROUTER = 0xf93B62CcdCcC62F29800Be38A182886dF9049933;

    // -----------------------------------------------------------------
    // Governance principals (testnet deploy: collapsed onto a single EOA
    // per CLAUDE.md note; mainnet must use a real Gnosis Safe).
    // -----------------------------------------------------------------

    address internal constant MULTISIG = 0x0eC2bFb36BB59C736d7b770eacaFAa43a184De34;
    address internal constant OPERATOR_ADDR = 0x0eC2bFb36BB59C736d7b770eacaFAa43a184De34;
    address internal constant PAUSER_ADDR = 0x0eC2bFb36BB59C736d7b770eacaFAa43a184De34;
    address internal constant REPORTER_ADDR = 0x0eC2bFb36BB59C736d7b770eacaFAa43a184De34;
    address internal constant FEE_RECIPIENT = 0x0eC2bFb36BB59C736d7b770eacaFAa43a184De34;
    address internal constant HOOK_RUNTIME_ADMIN = 0x0eC2bFb36BB59C736d7b770eacaFAa43a184De34;
    address internal constant DEPLOYER = 0x57a3341dde470558cf56301B655d7D02933f724f;

    // -----------------------------------------------------------------
    // Canonical infra (Unichain Sepolia)
    // -----------------------------------------------------------------

    address internal constant USDC = 0x2D56777Af1B52034068Af6864741a161dEE613Ac;
    address internal constant POOL_MANAGER = 0x00B036B58a818B1BC34d502D3fE730Db729e62AC;
    address internal constant PERMIT2 = 0x000000000022D473030F116dDEE9F6B43aC78BA3;
    address internal constant V4_QUOTER = 0x56DCD40A3F2d466F48e7F48bDBE5Cc9B92Ae4472;

    // -----------------------------------------------------------------
    // Role hashes (kept here to avoid importing shared constants into
    // every test file).
    // -----------------------------------------------------------------

    bytes32 internal constant DEFAULT_ADMIN_ROLE = 0x00;
    bytes32 internal constant ROLE_CUT_EXECUTOR = keccak256("predix.role.cut_executor");
    bytes32 internal constant ROLE_OPERATOR = keccak256("predix.role.operator");
    bytes32 internal constant ROLE_PAUSER = keccak256("predix.role.pauser");
    bytes32 internal constant ROLE_REPORTER = keccak256("predix.oracle.reporter");

    // -----------------------------------------------------------------
    // Fork block — 1 block after `hook.acceptAdmin()` so `_admin == HOOK_RUNTIME_ADMIN`.
    // -----------------------------------------------------------------

    uint256 internal constant FORK_BLOCK = 49569636;

    // ================================================================
    // Setup
    // ================================================================

    function setUp() public virtual {
        // Skip when the fork URL is not configured so that `make test` (which
        // does not export environment variables) does not register these as
        // failures. Running `forge test --match-path 'test/e2e/**'` with the
        // env loaded is the supported invocation — see SC/FORK_TESTS.md.
        string memory rpc = vm.envOr("UNICHAIN_RPC_PRIMARY", string(""));
        if (bytes(rpc).length == 0) {
            vm.skip(true, "UNICHAIN_RPC_PRIMARY not set");
            return;
        }
        vm.createSelectFork(rpc, FORK_BLOCK);
        _label();

        // SPEC-03: CREATOR_ROLE is introduced by Bundle A; the pinned fork
        // block predates the diamondCut that seats MULTISIG as CREATOR_ROLE.
        // Grant via cheatcode so derived tests' `_createMarket` helpers work.
        // Remove this block once FORK_BLOCK is advanced past the Bundle A cut
        // on Unichain Sepolia.
        vm.prank(MULTISIG);
        IAccessControlFacet(DIAMOND).grantRole(Roles.CREATOR_ROLE, MULTISIG);
    }

    function _label() internal {
        vm.label(DIAMOND, "Diamond");
        vm.label(TIMELOCK, "Timelock");
        vm.label(MANUAL_ORACLE, "ManualOracle");
        vm.label(HOOK_PROXY, "HookProxy");
        vm.label(HOOK_IMPL, "HookImpl");
        vm.label(EXCHANGE, "Exchange");
        vm.label(ROUTER, "Router");
        vm.label(MULTISIG, "Multisig");
        vm.label(USDC, "USDC");
        vm.label(POOL_MANAGER, "PoolManager");
        vm.label(PERMIT2, "Permit2");
        vm.label(V4_QUOTER, "V4Quoter");
    }

    // ================================================================
    // Shared helpers
    // ================================================================

    /// @notice Fund `user` with USDC and max-approve Permit2 (ERC20 allowance).
    /// @dev    The Permit2 signature step (per-call authorisation) is left to
    ///         the individual test — it needs a signer private key plus the
    ///         EIP-712 digest specific to the Router's action.
    function _fundUser(address user, uint256 usdcAmount) internal {
        deal(USDC, user, usdcAmount);
        vm.prank(user);
        IERC20(USDC).approve(PERMIT2, type(uint256).max);
    }
}
