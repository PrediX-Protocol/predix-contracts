// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import {Test} from "forge-std/Test.sol";

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {IV4Quoter} from "@uniswap/v4-periphery/src/interfaces/IV4Quoter.sol";
import {IAllowanceTransfer} from "permit2/src/interfaces/IAllowanceTransfer.sol";
import {LPFeeLibrary} from "@uniswap/v4-core/src/libraries/LPFeeLibrary.sol";

import {PrediXRouter} from "@predix/router/PrediXRouter.sol";
import {IBuilderRegistry} from "@predix/shared/interfaces/IBuilderRegistry.sol";

import {MockERC20} from "../mocks/MockERC20.sol";
import {MockDiamond} from "../mocks/MockDiamond.sol";
import {MockExchange} from "../mocks/MockExchange.sol";
import {MockHook} from "../mocks/MockHook.sol";
import {MockPoolManager} from "../mocks/MockPoolManager.sol";
import {MockV4Quoter} from "../mocks/MockV4Quoter.sol";
import {MockPermit2} from "../mocks/MockPermit2.sol";
import {MockBuilderRegistry} from "../mocks/MockBuilderRegistry.sol";
import {PrediXRouterHarness} from "./PrediXRouterHarness.sol";

/// @dev Deploys the 8 mocks + a `PrediXRouter` wired against them. Children inherit via
///      `setUp()` and use `router` / `usdc` / `yes1` / `no1` / `MARKET_ID` + mocks directly.
abstract contract RouterFixture is Test {
    // ---- Canonical pool shape for every market in tests ----
    uint24 internal constant LP_FEE_FLAG = LPFeeLibrary.DYNAMIC_FEE_FLAG;
    int24 internal constant TICK_SPACING = 60;

    uint256 internal constant MARKET_ID = 1;
    uint256 internal constant DEFAULT_DEADLINE_OFFSET = 1 hours;

    MockERC20 internal usdc;
    MockERC20 internal yes1;
    MockERC20 internal no1;

    MockDiamond internal diamond;
    MockExchange internal exchange;
    MockHook internal hook;
    MockPoolManager internal poolManager;
    MockV4Quoter internal quoter;
    MockPermit2 internal permit2;
    MockBuilderRegistry internal builderRegistry;

    PrediXRouterHarness internal router;

    bytes32 internal constant BUILDER = keccak256("acme");

    address internal alice = address(0xA11CE);
    address internal bob = address(0xB0B);

    function setUp() public virtual {
        usdc = new MockERC20("USD Coin", "USDC", 6);
        yes1 = new MockERC20("YES Market 1", "YES1", 6);
        no1 = new MockERC20("NO Market 1", "NO1", 6);

        diamond = new MockDiamond(address(usdc));
        exchange = new MockExchange(address(usdc));
        hook = new MockHook();
        poolManager = new MockPoolManager();
        quoter = new MockV4Quoter();
        permit2 = new MockPermit2();
        builderRegistry = new MockBuilderRegistry();
        builderRegistry.setBuilder(BUILDER, 0, 0, address(0xB111D)); // default 0 bps; tests bump per-case

        router = new PrediXRouterHarness(
            IPoolManager(address(poolManager)),
            address(diamond),
            address(usdc),
            address(hook),
            address(exchange),
            IV4Quoter(address(quoter)),
            IAllowanceTransfer(address(permit2)),
            LP_FEE_FLAG,
            TICK_SPACING,
            IBuilderRegistry(address(builderRegistry))
        );

        diamond.setMarket(MARKET_ID, address(yes1), address(no1), block.timestamp + 30 days, false, false);
        exchange.setMarketTokens(MARKET_ID, address(yes1), address(no1));

        // Seed the diamond with USDC + virtual collateral so `mergePositions` in sellNo tests
        // can pay out without running a real `splitPosition` first.
        usdc.mint(address(diamond), 10_000_000e6);
        diamond.seedCollateral(MARKET_ID, 10_000_000e6);

        // Give alice + bob USDC and outcome token balances for tests.
        usdc.mint(alice, 1_000_000e6);
        usdc.mint(bob, 1_000_000e6);
        yes1.mint(alice, 1_000_000e6);
        no1.mint(alice, 1_000_000e6);
        yes1.mint(bob, 1_000_000e6);
        no1.mint(bob, 1_000_000e6);

        // Pre-stock the mock pool manager with outcome + USDC for `take` calls.
        usdc.mint(address(poolManager), 10_000_000e6);
        yes1.mint(address(poolManager), 10_000_000e6);
        no1.mint(address(poolManager), 10_000_000e6);
        // Mock exchange also needs USDC to pay sellers.
        usdc.mint(address(exchange), 10_000_000e6);

        // Mark YES1/USDC pool as initialized so _hasPool returns true.
        _markPoolInitialized(address(yes1));
    }

    function _deadline() internal view returns (uint256) {
        return block.timestamp + DEFAULT_DEADLINE_OFFSET;
    }

    function _markPoolInitialized(address yesToken) internal {
        bytes32 stateSlot = _poolStateSlot(yesToken);
        poolManager.setPoolSlot0(stateSlot, 79228162514264337593543950336);
        // Active liquidity so `_hasPool` (which now gates on liquidity, not just initialization) returns true.
        poolManager.setPoolLiquidity(stateSlot, 1e18);
    }

    /// @dev Override a pool's mock liquidity — set to 0 to model an initialized-but-no-liquidity pool.
    function _setPoolLiquidity(address yesToken, uint128 liquidity) internal {
        poolManager.setPoolLiquidity(_poolStateSlot(yesToken), liquidity);
    }

    function _poolStateSlot(address yesToken) internal view returns (bytes32) {
        address quote = address(usdc);
        (Currency c0, Currency c1) = quote < yesToken
            ? (Currency.wrap(quote), Currency.wrap(yesToken))
            : (Currency.wrap(yesToken), Currency.wrap(quote));
        PoolKey memory key = PoolKey({
            currency0: c0, currency1: c1, fee: LP_FEE_FLAG, tickSpacing: TICK_SPACING, hooks: IHooks(address(hook))
        });
        bytes32 poolId = keccak256(abi.encode(key));
        return keccak256(abi.encodePacked(poolId, bytes32(uint256(6))));
    }
}
