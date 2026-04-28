// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {IMarketFacet} from "@predix/shared/interfaces/IMarketFacet.sol";
import {IEventFacet} from "@predix/shared/interfaces/IEventFacet.sol";
import {IAccessControlFacet} from "@predix/shared/interfaces/IAccessControlFacet.sol";
import {IPausableFacet} from "@predix/shared/interfaces/IPausableFacet.sol";
import {IOracle} from "@predix/shared/interfaces/IOracle.sol";
import {Roles} from "@predix/shared/constants/Roles.sol";
import {Modules} from "@predix/shared/constants/Modules.sol";

import {IPrediXExchange} from "@predix/exchange/IPrediXExchange.sol";
import {IPrediXHook} from "@predix/hook/interfaces/IPrediXHook.sol";
import {IPrediXHookProxy} from "@predix/hook/interfaces/IPrediXHookProxy.sol";
import {IPrediXRouter} from "@predix/router/interfaces/IPrediXRouter.sol";
import {ManualOracle} from "@predix/oracle/adapters/ManualOracle.sol";
import {PrediXExchangeProxy} from "@predix/exchange/PrediXExchangeProxy.sol";

/// @title E2EForkBase
/// @notice Base fixture for comprehensive E2E fork tests against the 2026-04-28 deploy
///         on Unichain Sepolia. Forks at a block after DeployAll + role grants.
abstract contract E2EForkBase is Test {
    using SafeERC20 for IERC20;

    // ---- Deployed addresses (2026-04-28) ----
    address internal constant DIAMOND = 0x91fA446F376e713636A29b95a02d63aE5f057dDC;
    address internal constant EXCHANGE = 0x9Ecef729f80739C2451Dc56354c986041dD8070D;
    address internal constant EXCHANGE_IMPL = 0x5676905Abe9A3A89F4fD9D97E943E72ff9fB3084;
    address internal constant HOOK_PROXY = 0x82fe732c651B9cc5c98Cee165B12FEb8a3006Ae0;
    address internal constant HOOK_IMPL = 0xF76ce60902F6128C297dA00a43f2B990645F4144;
    address internal constant ROUTER = 0xdB13bD901950F1CBa9478B9900A3B2B77C57412A;
    address internal constant TIMELOCK = 0x759143eC46131631259e8Ecc5DedeE0Fb66818A1;
    address internal constant MANUAL_ORACLE = 0x733502f3524D6610d93965d3E5D6C675DEE0b9c4;

    // ---- Principals ----
    address internal constant DEPLOYER = 0x57a3341dde470558cf56301B655d7D02933f724f;
    address internal constant OPERATOR = 0x0eC2bFb36BB59C736d7b770eacaFAa43a184De34;

    // ---- External ----
    address internal constant USDC = 0x2D56777Af1B52034068Af6864741a161dEE613Ac;
    address internal constant POOL_MANAGER = 0x00B036B58a818B1BC34d502D3fE730Db729e62AC;
    address internal constant PERMIT2 = 0x000000000022D473030F116dDEE9F6B43aC78BA3;
    address internal constant V4_QUOTER = 0x56DCD40A3F2d466F48e7F48bDBE5Cc9B92Ae4472;
    address internal constant POS_MANAGER = 0xf969Aee60879C54bAAed9F3eD26147Db216Fd664;

    // ---- Roles (precomputed) ----
    bytes32 internal constant ROLE_ADMIN = keccak256("predix.role.admin");
    bytes32 internal constant ROLE_OPERATOR = keccak256("predix.role.operator");
    bytes32 internal constant ROLE_PAUSER = keccak256("predix.role.pauser");
    bytes32 internal constant ROLE_CREATOR = keccak256("predix.role.creator");
    bytes32 internal constant ROLE_CUT_EXECUTOR = keccak256("predix.role.cut_executor");
    bytes32 internal constant MODULE_MARKET = keccak256("predix.module.market");
    bytes32 internal constant MODULE_DIAMOND = keccak256("predix.module.diamond");

    // ---- Test actors ----
    address internal alice;
    address internal bob;
    address internal charlie;
    address internal eve;

    // ---- Interfaces ----
    IMarketFacet internal diamond = IMarketFacet(DIAMOND);
    IEventFacet internal eventFacet = IEventFacet(DIAMOND);
    IAccessControlFacet internal accessControl = IAccessControlFacet(DIAMOND);
    IPausableFacet internal pausable = IPausableFacet(DIAMOND);
    IPrediXExchange internal exchange = IPrediXExchange(EXCHANGE);
    IPrediXHook internal hook = IPrediXHook(HOOK_PROXY);
    ManualOracle internal oracle = ManualOracle(MANUAL_ORACLE);

    // ---- Fork block ----
    uint256 internal constant FORK_BLOCK = 50515000;

    function setUp() public virtual {
        string memory rpc = vm.envOr("UNICHAIN_RPC_PRIMARY", string(""));
        if (bytes(rpc).length == 0) {
            vm.skip(true, "UNICHAIN_RPC_PRIMARY not set");
            return;
        }
        vm.createSelectFork(rpc, FORK_BLOCK);

        alice = makeAddr("alice");
        bob = makeAddr("bob");
        charlie = makeAddr("charlie");
        eve = makeAddr("eve");

        _fundActor(alice, 100_000e6);
        _fundActor(bob, 100_000e6);
        _fundActor(charlie, 100_000e6);
        _fundActor(eve, 100_000e6);
    }

    // ---- Helpers ----

    function _fundActor(address actor, uint256 usdcAmt) internal {
        vm.deal(actor, 1 ether);
        vm.prank(DEPLOYER);
        IERC20(USDC).transfer(actor, usdcAmt);
    }

    function _createMarket(address creator, uint256 endTime) internal returns (uint256 marketId) {
        vm.prank(creator);
        marketId = diamond.createMarket("Test market", endTime, MANUAL_ORACLE);
    }

    function _createMarketAs(address creator, string memory question, uint256 endTime, address oracleAddr)
        internal
        returns (uint256 marketId)
    {
        vm.prank(creator);
        marketId = diamond.createMarket(question, endTime, oracleAddr);
    }

    function _splitPosition(address user, uint256 marketId, uint256 amount) internal {
        vm.startPrank(user);
        IERC20(USDC).approve(DIAMOND, amount);
        diamond.splitPosition(marketId, amount);
        vm.stopPrank();
    }

    function _getTokens(uint256 marketId) internal view returns (address yesToken, address noToken) {
        IMarketFacet.MarketView memory m = diamond.getMarket(marketId);
        yesToken = m.yesToken;
        noToken = m.noToken;
    }

    function _grantCreatorRole(address user) internal {
        vm.prank(DEPLOYER);
        accessControl.grantRole(ROLE_CREATOR, user);
    }

    function _reportOutcome(uint256 marketId, bool outcome) internal {
        vm.prank(OPERATOR);
        oracle.report(marketId, outcome);
    }

    function _resolveMarket(uint256 marketId) internal {
        diamond.resolveMarket(marketId);
    }
}
