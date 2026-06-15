// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import {RouterFixture} from "../utils/RouterFixture.sol";
import {PrediXRouterHarness} from "../utils/PrediXRouterHarness.sol";
import {IPrediXRouter} from "@predix/router/interfaces/IPrediXRouter.sol";
import {IPrediXExchangeView} from "@predix/router/interfaces/IPrediXExchangeView.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IV4Quoter} from "@uniswap/v4-periphery/src/interfaces/IV4Quoter.sol";
import {IAllowanceTransfer} from "permit2/src/interfaces/IAllowanceTransfer.sol";
import {IBuilderRegistry} from "@predix/shared/interfaces/IBuilderRegistry.sol";

/// @notice Sub-plan 04 Tasks 1-2: fee-helper math (`_feeOn`/`_curveFee` via the harness), the
///         `builderRegistry` constructor wiring, and the CLOB-leg `builder` pass-through + `Trade.builder`.
///         The AMM-leg fee carve is Tasks 3-6.
contract PrediXRouter_AmmFee is RouterFixture {
    function _approveUsdcAsAlice(uint256 amount) internal {
        usdc.mint(alice, amount);
        vm.prank(alice);
        IERC20(address(usdc)).approve(address(router), amount);
    }

    // ---- helper-math unit checks (curve correctness, §1 worked example) ----
    function test_curveFee_polymarketParity_100sharesAt50c() public view {
        assertEq(router.exposed_curveFee(1e8, 700, 500_000), 1_750_000, "100sh @50c coef700 = $1.75");
    }

    function test_curveFee_tailFalloff_p10() public view {
        assertEq(router.exposed_curveFee(1e8, 700, 100_000), 630_000, "100sh @10c coef700 = $0.63");
    }

    function test_curveFee_zeroCoef_isZero() public view {
        assertEq(router.exposed_curveFee(1e8, 0, 500_000), 0, "coef 0 => 0");
    }

    function test_curveFee_saturatedP_isZero() public view {
        assertEq(router.exposed_curveFee(1e8, 700, 1_000_000), 0, "p>=1e6 => 0");
        assertEq(router.exposed_curveFee(1e8, 700, 0), 0, "p==0 => 0");
    }

    function test_feeOn_flatBps() public view {
        assertEq(router.exposed_feeOn(100e6, 100), 1e6, "1% of 100 = 1");
        assertEq(router.exposed_feeOn(100e6, 0), 0, "0 bps => 0");
    }

    // ---- constructor + CLOB-forward + Trade.builder (Task 2) ----
    function test_constructor_storesBuilderRegistry() public view {
        assertEq(address(router.builderRegistry()), address(builderRegistry), "registry immutable");
    }

    function test_constructor_rejectsZeroBuilderRegistry() public {
        vm.expectRevert(IPrediXRouter.ZeroAddress.selector);
        new PrediXRouterHarness(
            IPoolManager(address(poolManager)),
            address(diamond),
            address(usdc),
            address(hook),
            address(exchange),
            IV4Quoter(address(quoter)),
            IAllowanceTransfer(address(permit2)),
            LP_FEE_FLAG,
            TICK_SPACING,
            IBuilderRegistry(address(0))
        );
    }

    // builder == 0 + coef 0 (launch) on a pure-CLOB fill: Trade.builder == 0, no AMM fee.
    function test_buyYes_noBuilder_emitsTradeBuilderZero() public {
        uint256 usdcIn = 100e6;
        exchange.setResult(MARKET_ID, IPrediXExchangeView.Side.BUY_YES, 200e6, usdcIn);
        _approveUsdcAsAlice(usdcIn);

        vm.expectEmit(true, true, true, true, address(router));
        emit IPrediXRouter.Trade(
            MARKET_ID, alice, alice, IPrediXRouter.TradeType.BUY_YES, usdcIn, 200e6, 200e6, 0, bytes32(0)
        );
        vm.prank(alice);
        router.buyYes(MARKET_ID, usdcIn, 0, alice, 5, _deadline(), bytes32(0));
    }

    // CLOB leg receives the builder code (charged in-exchange; asserted via the mock's recorded arg).
    function test_buyYes_clobLeg_forwardsBuilder() public {
        uint256 usdcIn = 100e6;
        exchange.setResult(MARKET_ID, IPrediXExchangeView.Side.BUY_YES, 200e6, usdcIn);
        _approveUsdcAsAlice(usdcIn);
        vm.prank(alice);
        router.buyYes(MARKET_ID, usdcIn, 0, alice, 5, _deadline(), BUILDER);
        assertEq(exchange.lastTakerBuilder(), BUILDER, "CLOB leg got builder code");
    }

    function test_sellYes_clobLeg_forwardsBuilder() public {
        uint256 yesIn = 100e6;
        exchange.setResult(MARKET_ID, IPrediXExchangeView.Side.SELL_YES, 50e6, yesIn);
        yes1.mint(alice, yesIn);
        vm.prank(alice);
        yes1.approve(address(router), yesIn);
        vm.prank(alice);
        router.sellYes(MARKET_ID, yesIn, 0, alice, 5, _deadline(), BUILDER);
        assertEq(exchange.lastTakerBuilder(), BUILDER, "SELL CLOB leg got builder code");
    }
}
