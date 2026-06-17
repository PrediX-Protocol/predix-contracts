// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

// === Uniswap V4 ===
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {LPFeeLibrary} from "@uniswap/v4-core/src/libraries/LPFeeLibrary.sol";
import {ModifyLiquidityParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {PoolModifyLiquidityTest} from "@uniswap/v4-core/src/test/PoolModifyLiquidityTest.sol";

import {IV4Quoter} from "@uniswap/v4-periphery/src/interfaces/IV4Quoter.sol";
import {HookMiner} from "@uniswap/v4-periphery/src/utils/HookMiner.sol";

import {IAllowanceTransfer} from "permit2/src/interfaces/IAllowanceTransfer.sol";

// === PrediX shared ===
import {IDiamondCut} from "@predix/shared/interfaces/IDiamondCut.sol";
import {IMarketFacet} from "@predix/shared/interfaces/IMarketFacet.sol";
import {IEventFacet} from "@predix/shared/interfaces/IEventFacet.sol";
import {Roles} from "@predix/shared/constants/Roles.sol";

// === PrediX diamond ===
import {MarketFacet} from "@predix/diamond/facets/market/MarketFacet.sol";
import {EventFacet} from "@predix/diamond/facets/event/EventFacet.sol";
import {MarketInit} from "@predix/diamond/init/MarketInit.sol";
import {OutcomeTokenClone} from "@predix/shared/tokens/OutcomeTokenClone.sol";

// === PrediX hook ===
import {PrediXHookV2} from "@predix/hook/hooks/PrediXHookV2.sol";
import {PrediXHookProxyV2} from "@predix/hook/proxy/PrediXHookProxyV2.sol";
import {IPrediXHook} from "@predix/hook/interfaces/IPrediXHook.sol";

// === PrediX exchange ===
import {PrediXExchange} from "@predix/exchange/PrediXExchange.sol";
import {PrediXExchangeProxy} from "@predix/exchange/PrediXExchangeProxy.sol";
import {IPrediXExchange} from "@predix/exchange/IPrediXExchange.sol";

// === PrediX router ===
import {PrediXRouter} from "@predix/router/PrediXRouter.sol";
import {IPrediXRouter} from "@predix/router/interfaces/IPrediXRouter.sol";
import {BuilderRegistry} from "@predix/exchange/BuilderRegistry.sol";
import {IBuilderRegistry} from "@predix/shared/interfaces/IBuilderRegistry.sol";

// === Diamond fixture base ===
import {DiamondFixture} from "./DiamondFixture.sol";
import {MockOracle} from "../mocks/MockOracle.sol";

/// @title MainnetForkFixture
/// @notice Self-deploying fork fixture for end-to-end integration tests against
///         Unichain mainnet. Forks the chain at a pinned block, wires canonical
///         external infrastructure (USDC, PoolManager, Quoter, Permit2), and
///         deploys a fresh PrediX stack (Diamond + facets + Hook + Exchange +
///         Router + MockOracle) inside `setUp()`. Initializes the v4 pool at the
///         50¢ midpoint and provides initial AMM liquidity.
///
/// @dev Required env vars:
///      - UNICHAIN_RPC_PRIMARY               RPC endpoint
///      - UNICHAIN_MAINNET_PIN_BLOCK         Pin block (reproducibility)
///      Optional env vars (defaults applied if unset):
///      - UNICHAIN_RPC_SECONDARY             Failover RPC
///      - USDC_ADDRESS                       Canonical Circle USDC on Unichain
///      - POOL_MANAGER_ADDRESS               Canonical v4 PoolManager
///      - V4_QUOTER_ADDRESS                  Canonical V4Quoter
///      - PERMIT2_ADDRESS                    Canonical Permit2
///
/// @dev Missing required env vars cause `setUp()` to revert with an explicit
///      error message identifying which variable is unset.
abstract contract MainnetForkFixture is DiamondFixture {
    using SafeERC20 for IERC20;
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    // =========================================================================
    // Canonical Unichain mainnet defaults
    // =========================================================================

    /// @dev Real USDC by Circle on Unichain mainnet.
    address internal constant DEFAULT_USDC = 0x078D782b760474a361dDA0AF3839290b0EF57AD6;
    /// @dev Uniswap V4 PoolManager on Unichain mainnet.
    address internal constant DEFAULT_POOL_MANAGER = 0x1F98400000000000000000000000000000000004;
    /// @dev Uniswap V4Quoter on Unichain mainnet.
    address internal constant DEFAULT_V4_QUOTER = 0x333E3C607B141b18fF6de9f258db6e77fE7491E0;
    /// @dev Canonical Permit2 deployment (same on every EVM chain).
    address internal constant DEFAULT_PERMIT2 = 0x000000000022D473030F116dDEE9F6B43aC78BA3;

    // =========================================================================
    // Canonical PrediX pool shape
    // =========================================================================

    uint24 internal constant DYNAMIC_FEE = LPFeeLibrary.DYNAMIC_FEE_FLAG;
    int24 internal constant TICK_SPACING = 60;

    /// @dev sqrtPriceX96 for YES = $0.50 when YES IS currency0.
    ///      In v4: sqrtPrice represents sqrt(token1/token0). YES=currency0 means
    ///      currency1 is USDC; price = USDC per YES = 0.5. sqrt(0.5) * 2^96.
    uint160 internal constant SQRT_PRICE_FIFTY_CENT_YES_IS_CURRENCY0 = 56022770974786139918731938227;

    /// @dev sqrtPriceX96 for YES = $0.50 when YES IS currency1.
    ///      USDC=currency0, YES=currency1; price = YES per USDC = 2.0. sqrt(2) * 2^96.
    uint160 internal constant SQRT_PRICE_FIFTY_CENT_YES_IS_CURRENCY1 = 112045541949572279837463876454;

    // =========================================================================
    // External infrastructure (env-wired)
    // =========================================================================

    IERC20 internal usdc;
    IPoolManager internal poolManager;
    IV4Quoter internal quoter;
    IAllowanceTransfer internal permit2;

    // =========================================================================
    // PrediX deployed stack (fresh in setUp)
    // =========================================================================

    MarketFacet internal marketFacet;
    EventFacet internal eventFacetImpl;
    MarketInit internal marketInit;
    IMarketFacet internal market;
    IEventFacet internal eventFacet;

    PrediXHookV2 internal hookImpl;
    PrediXHookProxyV2 internal hook;

    PrediXExchange internal exchangeImpl;
    PrediXExchangeProxy internal exchangeProxy;
    IPrediXExchange internal exchange;

    PrediXRouter internal router;
    MockOracle internal oracle;

    PoolModifyLiquidityTest internal liquidityRouter;

    // =========================================================================
    // Actors
    // =========================================================================

    address internal hookAdmin = makeAddr("hookAdmin");
    address internal hookProxyAdmin = makeAddr("hookProxyAdmin");
    address internal exchangeProxyAdmin = makeAddr("exchangeProxyAdmin");
    address internal feeRecipient = makeAddr("feeRecipient");
    address internal creator = makeAddr("creator");
    address internal lp = makeAddr("lp");
    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");
    address internal charlie = makeAddr("charlie");

    // =========================================================================
    // Default test market
    // =========================================================================

    uint256 internal marketId;
    address internal yesToken;
    address internal noToken;
    PoolKey internal poolKey;
    bool internal yesIsCurrency0;

    // =========================================================================
    // setUp
    // =========================================================================

    function setUp() public virtual override {
        _selectMainnetFork();

        _wireExternalInfra();

        // === Step 1: Deploy Diamond + base facets (cut + loupe + access + pausable) ===
        super.setUp();

        // === Step 2: Cut MarketFacet into diamond with real USDC ===
        _cutMarketFacet();

        // === Step 3: Cut EventFacet into diamond ===
        _cutEventFacet();

        // === Step 4: Deploy MockOracle + grant CREATOR role ===
        _setupOracleAndCreator();

        // === Step 5: Deploy Exchange (impl + proxy with atomic init) ===
        _deployExchange();

        // === Step 6: Deploy Hook impl + proxy with HookMiner salt + bootstrap trust ===
        _deployHook();

        // === Step 7: Deploy Router ===
        _deployRouter();

        // === Step 8: Wire trusted-router into hook (bootstrap window, then close) ===
        _bootstrapHookTrust();

        // === Step 9: Create the default test market (binary, +30 days endTime) ===
        _createDefaultMarket();

        // === Step 10: Initialize v4 pool for the market at 50¢ ===
        _initializeDefaultPool();

        // === Step 11: Deploy v4 LiquidityRouter helper + provide initial liquidity ===
        _provideDefaultLiquidity();

        // === Step 12: Fund test actors ===
        _fundActors();
    }

    // =========================================================================
    // Fork setup
    // =========================================================================

    function _selectMainnetFork() private {
        string memory primaryRpc = _requiredEnvString("UNICHAIN_RPC_PRIMARY");
        uint256 pinBlock = _requiredEnvUint("UNICHAIN_MAINNET_PIN_BLOCK");

        try vm.createSelectFork(primaryRpc, pinBlock) returns (
            uint256
        ) {
        // success
        }
        catch {
            string memory secondaryRpc = vm.envOr("UNICHAIN_RPC_SECONDARY", string(""));
            if (bytes(secondaryRpc).length == 0) {
                revert(
                    "MainnetForkFixture: primary RPC failed and UNICHAIN_RPC_SECONDARY not set. "
                    "Configure failover RPC or check primary endpoint."
                );
            }
            emit log_string("Primary RPC failed, using UNICHAIN_RPC_SECONDARY");
            vm.createSelectFork(secondaryRpc, pinBlock);
        }
    }

    function _wireExternalInfra() private {
        usdc = IERC20(vm.envOr("USDC_ADDRESS", DEFAULT_USDC));
        poolManager = IPoolManager(vm.envOr("POOL_MANAGER_ADDRESS", DEFAULT_POOL_MANAGER));
        quoter = IV4Quoter(vm.envOr("V4_QUOTER_ADDRESS", DEFAULT_V4_QUOTER));
        permit2 = IAllowanceTransfer(vm.envOr("PERMIT2_ADDRESS", DEFAULT_PERMIT2));

        // Every external dep must have code at the pin block. A missing
        // contract typically indicates the pin block predates that contract's
        // deployment; tests cannot proceed in that state.
        require(address(usdc).code.length > 0, "MainnetForkFixture: USDC has no code at pin block");
        require(address(poolManager).code.length > 0, "MainnetForkFixture: PoolManager has no code");
        require(address(quoter).code.length > 0, "MainnetForkFixture: V4Quoter has no code");
        require(address(permit2).code.length > 0, "MainnetForkFixture: Permit2 has no code");
    }

    // =========================================================================
    // Diamond facet cuts
    // =========================================================================

    function _cutMarketFacet() private {
        marketFacet = new MarketFacet();
        marketInit = new MarketInit();

        IDiamondCut.FacetCut[] memory cuts = new IDiamondCut.FacetCut[](1);
        cuts[0] = _add(address(marketFacet), _marketSelectors());

        MarketInit.InitArgs memory args = MarketInit.InitArgs({
            collateralToken: address(usdc), feeRecipient: feeRecipient, marketCreationFee: 0, defaultPerMarketCap: 0
        });
        // v1.3: wire the OutcomeTokenClone master atomically in the cut. Without it `createMarket` reverts
        // `Market_OutcomeTokenImplNotSet`.
        address outcomeImpl = address(new OutcomeTokenClone(address(diamond)));
        bytes memory initData = abi.encodeCall(MarketInit.initWithOutcomeImpl, (args, outcomeImpl));

        vm.prank(timelock);
        diamondCut.diamondCut(cuts, address(marketInit), initData);

        market = IMarketFacet(address(diamond));
    }

    function _cutEventFacet() private {
        eventFacetImpl = new EventFacet();

        IDiamondCut.FacetCut[] memory cuts = new IDiamondCut.FacetCut[](1);
        cuts[0] = _add(address(eventFacetImpl), _eventSelectors());

        vm.prank(timelock);
        diamondCut.diamondCut(cuts, address(0), "");

        eventFacet = IEventFacet(address(diamond));
    }

    function _setupOracleAndCreator() private {
        oracle = new MockOracle();

        vm.startPrank(admin);
        market.approveOracle(address(oracle));
        accessControl.grantRole(Roles.CREATOR_ROLE, creator);
        vm.stopPrank();
    }

    // =========================================================================
    // Exchange deployment (impl + ERC-1967 proxy + atomic init)
    // =========================================================================

    function _deployExchange() private {
        exchangeImpl = new PrediXExchange();
        exchangeProxy = new PrediXExchangeProxy(
            address(exchangeImpl), exchangeProxyAdmin, address(diamond), address(usdc), feeRecipient
        );
        exchange = IPrediXExchange(address(exchangeProxy));
    }

    // =========================================================================
    // Hook deployment (impl + ERC-1967 proxy with HookMiner salt)
    // =========================================================================

    function _deployHook() private {
        // Step 1: Deploy hook implementation (any address — only the PROXY's
        //         address bits matter to PoolManager).
        hookImpl = new PrediXHookV2(poolManager, address(quoter), DYNAMIC_FEE, TICK_SPACING, 48 hours);

        // Step 2: Mine salt for proxy address with required permission bits.
        // PrediXHookProxyV2.getHookPermissions() declares 6 callbacks; the
        // proxy's address low-order bits must encode exactly those flags so
        // BaseHook.validateHookPermissions in the proxy constructor passes.
        uint160 flags = uint160(
            Hooks.BEFORE_INITIALIZE_FLAG | Hooks.BEFORE_ADD_LIQUIDITY_FLAG | Hooks.BEFORE_REMOVE_LIQUIDITY_FLAG
                | Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_SWAP_FLAG | Hooks.BEFORE_DONATE_FLAG
        );

        bytes memory constructorArgs =
            abi.encode(poolManager, address(hookImpl), hookProxyAdmin, hookAdmin, address(diamond), address(usdc));

        (address minedAddr, bytes32 salt) =
            HookMiner.find(address(this), flags, type(PrediXHookProxyV2).creationCode, constructorArgs);

        // Step 3: Deploy proxy at the mined address.
        hook = new PrediXHookProxyV2{salt: salt}(
            poolManager, address(hookImpl), hookProxyAdmin, hookAdmin, address(diamond), address(usdc)
        );
        require(address(hook) == minedAddr, "MainnetForkFixture: HookMiner address mismatch");
    }

    // =========================================================================
    // Router deployment
    // =========================================================================

    function _deployRouter() private {
        // Fee system (Sub-plan 01/04): the router needs a non-zero builder registry. builder=0 on every
        // fork call, so a bare registry suffices for the fork E2E.
        BuilderRegistry builderRegistry = new BuilderRegistry(address(diamond));
        router = new PrediXRouter(
            poolManager,
            address(diamond),
            address(usdc),
            address(hook),
            address(exchange),
            quoter,
            permit2,
            DYNAMIC_FEE,
            TICK_SPACING,
            IBuilderRegistry(address(builderRegistry))
        );
    }

    function _bootstrapHookTrust() private {
        vm.startPrank(hookAdmin);
        IPrediXHook(address(hook)).setTrustedRouter(address(router), true);
        IPrediXHook(address(hook)).setTrustedRouter(address(quoter), true);
        IPrediXHook(address(hook)).completeBootstrap();
        vm.stopPrank();
    }

    // =========================================================================
    // Default market + pool + liquidity
    // =========================================================================

    function _createDefaultMarket() private {
        vm.prank(creator);
        marketId = market.createMarket("Will X happen by Y?", block.timestamp + 30 days, address(oracle));

        IMarketFacet.MarketView memory m = market.getMarket(marketId);
        yesToken = m.yesToken;
        noToken = m.noToken;

        yesIsCurrency0 = address(usdc) > yesToken;
    }

    function _initializeDefaultPool() private {
        // Build canonical PoolKey for this market (matches Router._buildPoolKey).
        (Currency currency0, Currency currency1) = address(usdc) < yesToken
            ? (Currency.wrap(address(usdc)), Currency.wrap(yesToken))
            : (Currency.wrap(yesToken), Currency.wrap(address(usdc)));

        poolKey = PoolKey({
            currency0: currency0,
            currency1: currency1,
            fee: DYNAMIC_FEE,
            tickSpacing: TICK_SPACING,
            hooks: IHooks(address(hook))
        });

        // Register pool with hook BEFORE PoolManager.initialize. The hook's
        // beforeInitialize callback rejects unregistered pools.
        IPrediXHook(address(hook)).registerMarketPool(marketId, poolKey);

        // Initialize at sqrtPrice corresponding to YES = $0.50.
        uint160 sqrtPrice =
            yesIsCurrency0 ? SQRT_PRICE_FIFTY_CENT_YES_IS_CURRENCY0 : SQRT_PRICE_FIFTY_CENT_YES_IS_CURRENCY1;

        poolManager.initialize(poolKey, sqrtPrice);
    }

    function _provideDefaultLiquidity() private {
        // PoolModifyLiquidityTest implements IUnlockCallback and handles the
        // sync → transfer → settle flow for both currency legs.
        liquidityRouter = new PoolModifyLiquidityTest(poolManager);

        uint256 fundAmount = 100_000e6;
        deal(address(usdc), lp, fundAmount * 2);

        // Split USDC into YES + NO. The YES leg pairs with USDC in the AMM
        // pool; the NO leg remains in the LP wallet for unbalanced-holder
        // scenarios.
        vm.startPrank(lp);
        usdc.approve(address(diamond), fundAmount);
        market.splitPosition(marketId, fundAmount);

        usdc.approve(address(liquidityRouter), type(uint256).max);
        IERC20(yesToken).approve(address(liquidityRouter), type(uint256).max);

        // Tick range aligned to the canonical tick spacing. The hook bounds LP to the [0,1] YES-price band
        // (PrediXHookV2._beforeAddLiquidity): YES=currency0 caps tickUpper<=0, YES=currency1 floors
        // tickLower>=0. A full-range position reverts Hook_LiquidityRangeOutOfBounds, so clamp the
        // price-bounded side to tick 0.
        int24 minTick = (TickMath.MIN_TICK / TICK_SPACING) * TICK_SPACING;
        int24 maxTick = (TickMath.MAX_TICK / TICK_SPACING) * TICK_SPACING;
        (int24 tickLower, int24 tickUpper) = yesIsCurrency0 ? (minTick, int24(0)) : (int24(0), maxTick);

        ModifyLiquidityParams memory params = ModifyLiquidityParams({
            tickLower: tickLower, tickUpper: tickUpper, liquidityDelta: 50_000e6, salt: bytes32(0)
        });
        liquidityRouter.modifyLiquidity(poolKey, params, "");
        vm.stopPrank();
    }

    function _fundActors() private {
        deal(address(usdc), alice, 100_000e6);
        deal(address(usdc), bob, 100_000e6);
        deal(address(usdc), charlie, 100_000e6);

        vm.deal(alice, 1 ether);
        vm.deal(bob, 1 ether);
        vm.deal(charlie, 1 ether);
    }

    // =========================================================================
    // Child-test helpers
    // =========================================================================

    /// @notice Create an additional market with the given offset from `block.timestamp`.
    function _createMarket(uint256 secondsUntilEnd) internal returns (uint256 id, address yes, address no) {
        vm.prank(creator);
        id = market.createMarket("Test market", block.timestamp + secondsUntilEnd, address(oracle));
        IMarketFacet.MarketView memory m = market.getMarket(id);
        return (id, m.yesToken, m.noToken);
    }

    /// @notice Approve router for `user`'s USDC (typical pre-trade step).
    function _approveRouterForUsdc(address user) internal {
        vm.prank(user);
        usdc.approve(address(router), type(uint256).max);
    }

    /// @notice Approve router for `user`'s YES tokens.
    function _approveRouterForYes(address user) internal {
        vm.prank(user);
        IERC20(yesToken).approve(address(router), type(uint256).max);
    }

    /// @notice Approve router for `user`'s NO tokens.
    function _approveRouterForNo(address user) internal {
        vm.prank(user);
        IERC20(noToken).approve(address(router), type(uint256).max);
    }

    /// @notice Give `user` YES+NO tokens by splitting from USDC.
    function _splitToUser(address user, uint256 usdcAmount) internal {
        vm.startPrank(user);
        usdc.approve(address(diamond), usdcAmount);
        market.splitPosition(marketId, usdcAmount);
        vm.stopPrank();
    }

    /// @notice Standard exchange approval for a maker.
    function _approveExchangeForAll(address user) internal {
        vm.startPrank(user);
        usdc.approve(address(exchange), type(uint256).max);
        IERC20(yesToken).approve(address(exchange), type(uint256).max);
        IERC20(noToken).approve(address(exchange), type(uint256).max);
        vm.stopPrank();
    }

    // =========================================================================
    // Facet selector lists
    // =========================================================================

    function _marketSelectors() internal pure returns (bytes4[] memory s) {
        s = new bytes4[](35);
        s[0] = IMarketFacet.createMarket.selector;
        s[1] = IMarketFacet.splitPosition.selector;
        s[2] = IMarketFacet.mergePositions.selector;
        s[3] = IMarketFacet.resolveMarket.selector;
        s[4] = IMarketFacet.emergencyResolve.selector;
        s[5] = IMarketFacet.redeem.selector;
        s[6] = IMarketFacet.enableRefundMode.selector;
        s[7] = IMarketFacet.refund.selector;
        s[8] = IMarketFacet.sweepUnclaimed.selector;
        s[9] = IMarketFacet.approveOracle.selector;
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
        // Sub-plan 02 protocol-fee config (F5-2: fork cut must expose the new MarketFacet ABI).
        s[29] = IMarketFacet.setDefaultProtocolFeeRateBps.selector;
        s[30] = IMarketFacet.setPerMarketProtocolFeeRateBps.selector;
        s[31] = IMarketFacet.clearPerMarketProtocolFee.selector;
        s[32] = IMarketFacet.setProtocolMakerRebateBps.selector;
        s[33] = IMarketFacet.effectiveProtocolFee.selector;
        s[34] = IMarketFacet.getFeeConfig.selector;
    }

    function _eventSelectors() internal pure returns (bytes4[] memory s) {
        s = new bytes4[](8);
        s[0] = IEventFacet.createEvent.selector;
        s[1] = IEventFacet.resolveEvent.selector;
        s[2] = IEventFacet.emergencyResolveEvent.selector;
        s[3] = IEventFacet.enableEventRefundMode.selector;
        s[4] = IEventFacet.getEvent.selector;
        s[5] = IEventFacet.getEventStatus.selector;
        s[6] = IEventFacet.eventOfMarket.selector;
        s[7] = IEventFacet.eventCount.selector;
    }

    // =========================================================================
    // Env var helpers
    // =========================================================================

    function _requiredEnvString(string memory key) private view returns (string memory) {
        string memory v = vm.envOr(key, string(""));
        require(bytes(v).length > 0, string.concat("MainnetForkFixture: required env var '", key, "' not set"));
        return v;
    }

    function _requiredEnvUint(string memory key) private view returns (uint256) {
        uint256 v = vm.envOr(key, uint256(0));
        require(v != 0, string.concat("MainnetForkFixture: required env var '", key, "' not set or zero"));
        return v;
    }
}
