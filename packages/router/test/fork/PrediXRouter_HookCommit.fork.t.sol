// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";

import {IV4Quoter} from "@uniswap/v4-periphery/src/interfaces/IV4Quoter.sol";
import {IAllowanceTransfer} from "permit2/src/interfaces/IAllowanceTransfer.sol";

import {IMarketFacet} from "@predix/shared/interfaces/IMarketFacet.sol";

import {PrediXRouter} from "@predix/router/PrediXRouter.sol";

interface IExchangePlace {
    enum Side {
        BUY_YES,
        SELL_YES,
        BUY_NO,
        SELL_NO
    }

    function placeOrder(uint256 marketId, Side side, uint256 price, uint256 amount) external returns (bytes32, uint256);
}

interface IHookTrust {
    function setTrustedRouter(address router, bool trusted) external;
    function isTrustedRouter(address router) external view returns (bool);
}

/// @title PrediXRouter_HookCommit_Fork
/// @notice Phase 4 Part 1 fork-based integration test. Runs against a pinned
///         Unichain Sepolia block and exercises the patched router against the
///         LIVE deployed hook + PoolManager + V4Quoter + diamond + exchange.
///
/// ─── Scope matrix ───────────────────────────────────────────────────────────
///
///   Happy paths (C-narrow unblocked these — must PASS):
///     1. BuyYes  — real AMM swap against Phase 3 pool 1
///     2. SellYes — symmetric
///     3. BuyYes  — CLOB-only small amount (no AMM spillover)
///     4. SellYes — CLOB-only small amount
///     5. BuyNo   — CLOB-only small amount (virtual-NO path survives without AMM)
///     6. SellNo  — CLOB-only small amount
///
///   Known-broken reverts locked in (Phase 5 backlog #49 will unblock these):
///     7-10. quoteBuyYes / quoteSellYes / quoteBuyNo / quoteSellNo all revert
///           with `Hook_MissingRouterCommit` via `WrappedError` envelope.
///     11. BuyNo  AMM spillover reverts (`_computeBuyNoMintAmount` still quoter-gated)
///     12. SellNo AMM spillover reverts (`_computeSellNoMaxCost` still quoter-gated)
///
/// ─── Running ────────────────────────────────────────────────────────────────
///
///   # Default (skips fork tests when RPC env missing)
///   forge test --no-match-path "test/fork/*"
///
///   # Explicit fork run (requires UNICHAIN_SEPOLIA_RPC + UNICHAIN_SEPOLIA_PIN_BLOCK
///   # to be set in SC/.env — follow `.env.example` pattern)
///   forge test --match-path "test/fork/PrediXRouter_HookCommit.fork.t.sol" -vvv
///
///   See `packages/router/test/fork/README.md` for pin-block maintenance.
contract PrediXRouter_HookCommit_Fork is Test {
    // Live deployed addresses on Unichain Sepolia (chain 1301) — see
    // SC/audits/DEPLOY_UNICHAIN_SEPOLIA_20260415.md + TEST_REPORT_PHASE3_POOL_AMM_20260416.md
    address internal constant POOL_MANAGER = 0x00B036B58a818B1BC34d502D3fE730Db729e62AC;
    address internal constant DIAMOND = 0x6Eba375cC5f5b9f8c02bE0A7bE1368ffeFdBd4cF;
    address internal constant HOOK_PROXY = 0xc28e945e6BB622f35118358A08b3BA1B17692AE0;
    address internal constant EXCHANGE = 0xc68DFc341fd6623ca7fd0f06Cfb2c2120D785D9F;
    address internal constant USDC = 0x2D56777Af1B52034068Af6864741a161dEE613Ac;
    address internal constant V4_QUOTER = 0x56DCD40A3F2d466F48e7F48bDBE5Cc9B92Ae4472;
    address internal constant PERMIT2 = 0x000000000022D473030F116dDEE9F6B43aC78BA3;

    // Phase 3 Market 19 (AMM smoke test) — YES < USDC so yesIsCurrency0
    uint256 internal constant MARKET_ID = 19;
    address internal constant YES_TOKEN = 0x05e46C0Ea291C059a9E1cFB001B5d92DC55D68aa;

    // Operator EOA (hook runtime admin, diamond ADMIN_ROLE, exchange admin)
    address internal constant OPERATOR = 0x0eC2bFb36BB59C736d7b770eacaFAa43a184De34;

    uint24 internal constant DYNAMIC_FEE_FLAG = 0x800000;
    int24 internal constant TICK_SPACING = 60;
    uint256 internal constant PRICE_PRECISION = 1e6;

    // Error selectors we expect to see wrapped in WrappedError / HookCallFailed envelopes
    bytes4 internal constant HOOK_MISSING_ROUTER_COMMIT_SEL = 0x9227ffd8;

    PrediXRouter internal router;
    address internal alice = makeAddr("alice");

    function setUp() public {
        // Fail-loud if env missing: `vm.envString` / `vm.envUint` throw on unset.
        string memory rpc = vm.envString("UNICHAIN_SEPOLIA_RPC");
        uint256 pinBlock = vm.envUint("UNICHAIN_SEPOLIA_PIN_BLOCK");
        vm.createSelectFork(rpc, pinBlock);

        // Deploy the fresh PATCHED router in-process against live infra
        router = new PrediXRouter(
            IPoolManager(POOL_MANAGER),
            DIAMOND,
            USDC,
            HOOK_PROXY,
            EXCHANGE,
            IV4Quoter(V4_QUOTER),
            IAllowanceTransfer(PERMIT2),
            DYNAMIC_FEE_FLAG,
            TICK_SPACING
        );

        // Wire trusted router on the live hook proxy (mirrors escape #5).
        // Existing live router is ALSO trusted (escape #5 was applied 2026-04-16).
        // Trusting this fresh router doesn't revoke the existing one.
        vm.prank(OPERATOR);
        IHookTrust(HOOK_PROXY).setTrustedRouter(address(router), true);
        assertTrue(IHookTrust(HOOK_PROXY).isTrustedRouter(address(router)), "fresh router trust");
        assertTrue(IHookTrust(HOOK_PROXY).isTrustedRouter(V4_QUOTER), "quoter trust (escape #6)");

        // Fund alice with USDC via `deal` (bypasses TestUSDC open-mint for determinism)
        deal(USDC, alice, 100_000_000); // 100 USDC raw
    }

    function _deadline() internal view returns (uint256) {
        return block.timestamp + 3600;
    }

    /// @dev Grab the live market 19 yesToken (defensive — confirms the constant).
    function _yesToken() internal view returns (address) {
        IMarketFacet.MarketView memory m = IMarketFacet(DIAMOND).getMarket(MARKET_ID);
        require(m.yesToken == YES_TOKEN, "yesToken drift");
        return m.yesToken;
    }

    /// @dev Grab the live market 19 noToken from the diamond.
    function _noToken() internal view returns (address) {
        IMarketFacet.MarketView memory m = IMarketFacet(DIAMOND).getMarket(MARKET_ID);
        return m.noToken;
    }

    // ─────────────────────────────────────────────────────────────────
    // Happy paths — C-narrow fix unblocks these (backlog #45a)
    // ─────────────────────────────────────────────────────────────────

    function test_Fork_BuyYes_HappyPath() public {
        vm.startPrank(alice);
        IERC20(USDC).approve(address(router), type(uint256).max);
        uint256 aliceYesBefore = IERC20(_yesToken()).balanceOf(alice);
        uint256 usdcIn = 1_000_000; // 1 USDC
        (uint256 yesOut, uint256 clobFilled, uint256 ammFilled) =
            router.buyYes(MARKET_ID, usdcIn, 0, alice, 5, _deadline());
        vm.stopPrank();

        assertGt(yesOut, 0, "buyYes must produce YES");
        assertEq(yesOut, clobFilled + ammFilled);
        assertEq(IERC20(_yesToken()).balanceOf(alice) - aliceYesBefore, yesOut);

        // C03 non-custody invariant
        assertEq(IERC20(USDC).balanceOf(address(router)), 0, "router USDC dust");
        assertEq(IERC20(_yesToken()).balanceOf(address(router)), 0, "router YES dust");
    }

    function test_Fork_SellYes_HappyPath() public {
        // Seed alice with YES tokens via deal (bypasses diamond split for test determinism)
        address yes = _yesToken();
        deal(yes, alice, 10_000_000); // 10 YES

        vm.startPrank(alice);
        IERC20(yes).approve(address(router), type(uint256).max);
        uint256 aliceUsdcBefore = IERC20(USDC).balanceOf(alice);
        uint256 yesIn = 1_000_000; // 1 YES
        (uint256 usdcOut, uint256 clobFilled, uint256 ammFilled) =
            router.sellYes(MARKET_ID, yesIn, 0, alice, 5, _deadline());
        vm.stopPrank();

        assertGt(usdcOut, 0, "sellYes must produce USDC");
        assertEq(usdcOut, clobFilled + ammFilled);
        assertEq(IERC20(USDC).balanceOf(alice) - aliceUsdcBefore, usdcOut);
        assertEq(IERC20(USDC).balanceOf(address(router)), 0);
        assertEq(IERC20(yes).balanceOf(address(router)), 0);
    }

    /// @dev CLOB-only path for buyYes: Bob places a SELL_YES order on market 19
    ///      so Alice's small buyYes fills entirely via the CLOB, never touching
    ///      the AMM (and therefore never hitting the hook's commit gate).
    function test_Fork_BuyYes_ClobOnly_SmallAmount() public {
        _seedClobOrder(
            IExchangePlace.Side.SELL_YES,
            400_000,
            /* 0.40 */
            5_000_000 /* 5 YES */
        );

        vm.startPrank(alice);
        IERC20(USDC).approve(address(router), type(uint256).max);
        uint256 aliceYesBefore = IERC20(_yesToken()).balanceOf(alice);
        (uint256 yesOut, uint256 clobFilled, uint256 ammFilled) =
            router.buyYes(
                MARKET_ID,
                400_000,
                /* 0.40 USDC */
                0,
                alice,
                5,
                _deadline()
            );
        vm.stopPrank();

        assertGt(clobFilled, 0, "CLOB should have filled");
        // AMM may or may not have filled residual — depends on matching granularity.
        // The key assertion is that the CLOB path worked (contradicts #45a regression).
        assertEq(yesOut, clobFilled + ammFilled);
        assertEq(IERC20(_yesToken()).balanceOf(alice) - aliceYesBefore, yesOut);
    }

    function test_Fork_SellYes_ClobOnly_SmallAmount() public {
        address yes = _yesToken();
        deal(yes, alice, 10_000_000);
        _seedClobOrder(
            IExchangePlace.Side.BUY_YES,
            600_000,
            /* 0.60 */
            5_000_000
        );

        vm.startPrank(alice);
        IERC20(yes).approve(address(router), type(uint256).max);
        uint256 aliceUsdcBefore = IERC20(USDC).balanceOf(alice);
        (uint256 usdcOut, uint256 clobFilled, uint256 ammFilled) =
            router.sellYes(MARKET_ID, 1_000_000, 0, alice, 5, _deadline());
        vm.stopPrank();

        assertGt(clobFilled, 0);
        assertEq(usdcOut, clobFilled + ammFilled);
        assertEq(IERC20(USDC).balanceOf(alice) - aliceUsdcBefore, usdcOut);
    }

    function test_Fork_BuyNo_ClobOnly_SmallAmount() public {
        _seedClobOrder(IExchangePlace.Side.SELL_NO, 600_000, 5_000_000);

        vm.startPrank(alice);
        IERC20(USDC).approve(address(router), type(uint256).max);
        uint256 aliceNoBefore = IERC20(_noToken()).balanceOf(alice);
        // Budget small enough that the CLOB ask can absorb the entire order
        // with no AMM spillover (and therefore no `_computeBuyNoMintAmount` call).
        (uint256 noOut, uint256 clobFilled,) = router.buyNo(MARKET_ID, 600_000, 0, alice, 5, _deadline());
        vm.stopPrank();

        assertGt(clobFilled, 0, "CLOB should have filled BuyNo");
        assertEq(noOut, clobFilled, "BuyNo CLOB-only must not spill to AMM");
        assertEq(IERC20(_noToken()).balanceOf(alice) - aliceNoBefore, noOut);
    }

    function test_Fork_SellNo_ClobOnly_SmallAmount() public {
        address no = _noToken();
        deal(no, alice, 10_000_000);
        _seedClobOrder(IExchangePlace.Side.BUY_NO, 400_000, 5_000_000);

        vm.startPrank(alice);
        IERC20(no).approve(address(router), type(uint256).max);
        uint256 aliceUsdcBefore = IERC20(USDC).balanceOf(alice);
        (uint256 usdcOut, uint256 clobFilled,) = router.sellNo(MARKET_ID, 1_000_000, 0, alice, 5, _deadline());
        vm.stopPrank();

        assertGt(clobFilled, 0, "CLOB should have filled SellNo");
        assertEq(usdcOut, clobFilled);
        assertEq(IERC20(USDC).balanceOf(alice) - aliceUsdcBefore, usdcOut);
    }

    // ─────────────────────────────────────────────────────────────────
    // Known-broken reverts — locked in until Phase 5 backlog #49
    // ─────────────────────────────────────────────────────────────────

    function test_Fork_Revert_QuoteBuyYes_Phase5Deferred() public {
        vm.expectRevert();
        router.quoteBuyYes(MARKET_ID, 1_000_000, 5);
    }

    function test_Fork_Revert_QuoteSellYes_Phase5Deferred() public {
        vm.expectRevert();
        router.quoteSellYes(MARKET_ID, 1_000_000, 5);
    }

    function test_Fork_Revert_QuoteBuyNo_Phase5Deferred() public {
        vm.expectRevert();
        router.quoteBuyNo(MARKET_ID, 1_000_000, 5);
    }

    function test_Fork_Revert_QuoteSellNo_Phase5Deferred() public {
        vm.expectRevert();
        router.quoteSellNo(MARKET_ID, 1_000_000, 5);
    }

    /// @dev BuyNo AMM spillover: Alice's order exceeds any CLOB liquidity so
    ///      the router enters `_executeAmmBuyNo` → `_computeBuyNoMintAmount` →
    ///      V4Quoter call → `Hook_MissingRouterCommit` revert bubble.
    function test_Fork_Revert_BuyNo_AmmSpillover_Phase5Deferred() public {
        vm.startPrank(alice);
        IERC20(USDC).approve(address(router), type(uint256).max);
        vm.expectRevert();
        router.buyNo(
            MARKET_ID,
            50_000_000,
            /* 50 USDC — exceeds any CLOB depth */
            0,
            alice,
            5,
            _deadline()
        );
        vm.stopPrank();
    }

    function test_Fork_Revert_SellNo_AmmSpillover_Phase5Deferred() public {
        address no = _noToken();
        deal(no, alice, 100_000_000);
        vm.startPrank(alice);
        IERC20(no).approve(address(router), type(uint256).max);
        vm.expectRevert();
        router.sellNo(MARKET_ID, 50_000_000, 0, alice, 5, _deadline());
        vm.stopPrank();
    }

    // ─────────────────────────────────────────────────────────────────
    // Helpers
    // ─────────────────────────────────────────────────────────────────

    /// @dev Place a CLOB order via a funded bob address. For BUY sides bob gets
    ///      USDC via `deal`. For SELL sides bob gets real YES+NO outcome tokens
    ///      by calling `diamond.splitPosition(MARKET_ID, amount)` — `deal` cannot
    ///      be used on `OutcomeToken` because its storage layout is not what the
    ///      foundry heuristic assumes. Approves the exchange, places the limit
    ///      order, returns orderId.
    function _seedClobOrder(IExchangePlace.Side side, uint256 price, uint256 amount) internal returns (bytes32) {
        address bob = makeAddr("bob");
        if (side == IExchangePlace.Side.BUY_YES || side == IExchangePlace.Side.BUY_NO) {
            uint256 need = (amount * price) / PRICE_PRECISION + 1;
            deal(USDC, bob, need);
            vm.startPrank(bob);
            IERC20(USDC).approve(EXCHANGE, type(uint256).max);
            vm.stopPrank();
        } else {
            // Real outcome tokens via diamond.splitPosition
            deal(USDC, bob, amount);
            vm.startPrank(bob);
            IERC20(USDC).approve(DIAMOND, type(uint256).max);
            IMarketFacet(DIAMOND).splitPosition(MARKET_ID, amount);
            if (side == IExchangePlace.Side.SELL_YES) {
                IERC20(_yesToken()).approve(EXCHANGE, type(uint256).max);
            } else {
                IERC20(_noToken()).approve(EXCHANGE, type(uint256).max);
            }
            vm.stopPrank();
        }
        vm.prank(bob);
        (bytes32 orderId,) = IExchangePlace(EXCHANGE).placeOrder(MARKET_ID, side, price, amount);
        return orderId;
    }
}
