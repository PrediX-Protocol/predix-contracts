// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import {Script, console2} from "forge-std/Script.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {IMarketFacet} from "@predix/shared/interfaces/IMarketFacet.sol";
import {IEventFacet} from "@predix/shared/interfaces/IEventFacet.sol";
import {IPrediXHook} from "@predix/hook/interfaces/IPrediXHook.sol";

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {LPFeeLibrary} from "@uniswap/v4-core/src/libraries/LPFeeLibrary.sol";
import {ModifyLiquidityParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {PoolModifyLiquidityTest} from "@uniswap/v4-core/src/test/PoolModifyLiquidityTest.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";

interface IPoolModifyLiquidityTest {
    function modifyLiquidity(PoolKey memory key, ModifyLiquidityParams memory params, bytes memory hookData)
        external
        payable
        returns (int256 delta);
}

interface ITestUSDC {
    function mint(address to, uint256 amount) external;
}

/// @notice End-to-end batch bootstrap: creates 5 binary markets + 5 multi-outcome
///         events (2-5 outcomes), then seeds every resulting market with a
///         full-range AMM pool of ~100k USDC + ~200k YES at p=0.5.
/// @dev    Two signers, both derived from MNEMONIC so no raw key handling:
///           - CREATE step -> CREATOR_MNEMONIC_INDEX (default 6, CREATOR_ROLE holder)
///           - SEED step   -> LP_MNEMONIC_INDEX (default 0, the funded deployer)
///         The seed flow mirrors Phase7BootstrapChildPool: it resolves the v4
///         modify-liquidity router (self-deploying a PoolModifyLiquidityTest when
///         none has code on this chain, e.g. mainnet 130), and is idempotent on
///         pool register + initialize.
///
///         Required env: DIAMOND_ADDRESS, HOOK_PROXY_ADDRESS, POOL_MANAGER_ADDRESS,
///                       USDC_ADDRESS, ORACLE_MANUAL_ADDRESS, MNEMONIC.
///         Optional env: CREATOR_MNEMONIC_INDEX (6), LP_MNEMONIC_INDEX (0),
///                       LP_USDC_AMOUNT (100_000e6), LP_LIQUIDITY_DELTA (141421356237),
///                       LP_MODIFY_ROUTER (reuse a router instead of deploying).
contract Phase7CreateAndSeedBatch is Script {
    uint160 internal constant SQRT_PRICE_MID_YES_CURRENCY0 = 56022770974786139918731938227;
    uint160 internal constant SQRT_PRICE_MID_YES_CURRENCY1 = 112045541949572279837463876454;

    uint24 internal constant DYNAMIC_FEE_FLAG = LPFeeLibrary.DYNAMIC_FEE_FLAG;
    int24 internal constant TICK_SPACING = 60;
    int24 internal constant MIN_TICK_ALIGNED = -887220;
    int24 internal constant MAX_TICK_ALIGNED = 887220;

    struct Env {
        address diamond;
        address hook;
        address poolManager;
        address usdc;
        address oracle;
    }

    struct Cfg {
        address diamond;
        address hook;
        address poolManager;
        address usdc;
        uint256 lpUsdc;
        uint256 lpL;
        address router;
    }

    function run() external {
        Env memory e = _env();
        string memory mnemonic = vm.envString("MNEMONIC");
        uint256 creatorPk = vm.deriveKey(mnemonic, uint32(vm.envOr("CREATOR_MNEMONIC_INDEX", uint256(6))));
        uint256 lpPk = vm.deriveKey(mnemonic, uint32(vm.envOr("LP_MNEMONIC_INDEX", uint256(0))));

        uint256[] memory ids = _createAll(e, creatorPk);
        console2.log("=========================================================");
        console2.log("Created 22 markets:");
        console2.log(_toJson(ids));
        console2.log("=========================================================");

        _seedAll(e, lpPk, ids);

        console2.log("=========================================================");
        console2.log("BATCH COMPLETE: 22 markets created + seeded full-range LP");
        console2.log("ALL_MARKET_IDS=", _toJson(ids));
        console2.log("=========================================================");
    }

    function _env() internal view returns (Env memory e) {
        e.diamond = vm.envAddress("DIAMOND_ADDRESS");
        e.hook = vm.envAddress("HOOK_PROXY_ADDRESS");
        e.poolManager = vm.envAddress("POOL_MANAGER_ADDRESS");
        e.usdc = vm.envAddress("USDC_ADDRESS");
        e.oracle = vm.envAddress("ORACLE_MANUAL_ADDRESS");
    }

    function _createAll(Env memory e, uint256 creatorPk) internal returns (uint256[] memory ids) {
        uint256 t = block.timestamp;
        ids = new uint256[](22);
        uint256 p;

        vm.startBroadcast(creatorPk);

        ids[p++] = IMarketFacet(e.diamond).createMarket(
            "Will Solana (SOL) trade above $200 before 2026-05-29 17:35 (UTC+7)?", t + 21_600, e.oracle
        );
        ids[p++] = IMarketFacet(e.diamond).createMarket(
            "Will gold (XAU/USD) set a new all-time high before 2026-05-30?", t + 111_600, e.oracle
        );
        ids[p++] = IMarketFacet(e.diamond).createMarket(
            "Will Ethereum (ETH) close above $4,500 before 2026-06-01?", t + 259_200, e.oracle
        );
        ids[p++] = IMarketFacet(e.diamond).createMarket(
            "Will SpaceX launch a Starship test flight before 2026-06-03?", t + 432_000, e.oracle
        );
        ids[p++] = IMarketFacet(e.diamond).createMarket(
            "Will Bitcoin (BTC) trade above $120,000 before 2026-06-04?", t + 540_000, e.oracle
        );

        {
            string[] memory c = new string[](2);
            c[0] = "Sequel";
            c[1] = "Original film";
            p = _event(e, ids, p, "This weekend's #1 box-office film: sequel or original? (by 2026-05-29)", c, t + 25_200);
        }
        {
            string[] memory c = new string[](4);
            c[0] = "Avatar: Fire and Ash";
            c[1] = "A Mission: Impossible release";
            c[2] = "A Pixar or Disney title";
            c[3] = "Other";
            p = _event(e, ids, p, "Top global box-office film this weekend (by 2026-05-31)?", c, t + 172_800);
        }
        {
            string[] memory c = new string[](3);
            c[0] = "Bitcoin (BTC)";
            c[1] = "Ethereum (ETH)";
            c[2] = "Solana (SOL)";
            p = _event(
                e, ids, p, "Which major crypto posts the biggest 7-day return (window ending 2026-06-02)?", c, t + 345_600
            );
        }
        {
            string[] memory c = new string[](3);
            c[0] = "Gavin Newsom";
            c[1] = "Kamala Harris";
            c[2] = "Other";
            p = _event(
                e, ids, p, "Who is the polling frontrunner for the 2028 Democratic nomination by 2026-06-03?", c, t + 475_200
            );
        }
        {
            string[] memory c = new string[](5);
            c[0] = "Technology";
            c[1] = "Energy";
            c[2] = "Financials";
            c[3] = "Healthcare";
            c[4] = "Other";
            p = _event(e, ids, p, "Which sector leads the S&P 500 this week (by 2026-06-05)?", c, t + 590_400);
        }

        vm.stopBroadcast();
        require(p == ids.length, "id count mismatch");
    }

    function _seedAll(Env memory e, uint256 lpPk, uint256[] memory ids) internal {
        uint256 lpUsdc = vm.envOr("LP_USDC_AMOUNT", uint256(100_000_000_000));
        uint256 lpL = vm.envOr("LP_LIQUIDITY_DELTA", uint256(141_421_356_237));

        vm.startBroadcast(lpPk);

        address router = vm.envOr("LP_MODIFY_ROUTER", address(0));
        if (router == address(0) || router.code.length == 0) {
            router = address(new PoolModifyLiquidityTest(IPoolManager(e.poolManager)));
            console2.log("Deployed PoolModifyLiquidityTest at:", router);
        } else {
            console2.log("Using PoolModifyLiquidityTest at:", router);
        }

        address lp = vm.addr(lpPk);
        uint256 needed = (lpUsdc * 3 + lpUsdc / 1000 + 1) * ids.length;
        uint256 bal = IERC20(e.usdc).balanceOf(lp);
        if (bal < needed) {
            ITestUSDC(e.usdc).mint(lp, needed - bal);
            console2.log("Auto-minted USDC shortfall:", needed - bal);
        }

        Cfg memory cfg = Cfg(e.diamond, e.hook, e.poolManager, e.usdc, lpUsdc, lpL, router);
        for (uint256 k; k < ids.length; ++k) {
            _seed(cfg, ids[k]);
        }

        vm.stopBroadcast();
    }

    function _event(
        Env memory e,
        uint256[] memory ids,
        uint256 p,
        string memory name,
        string[] memory candidates,
        uint256 endTime
    ) internal returns (uint256) {
        (uint256 eventId, uint256[] memory childIds) =
            IEventFacet(e.diamond).createEvent(name, candidates, endTime, e.oracle);
        console2.log("Event created:", eventId, name);
        for (uint256 i; i < childIds.length; ++i) {
            ids[p++] = childIds[i];
        }
        return p;
    }

    function _seed(Cfg memory c, uint256 marketId) internal {
        IMarketFacet.MarketView memory mkt = IMarketFacet(c.diamond).getMarket(marketId);
        require(mkt.yesToken != address(0), "market missing");

        bool yesIsCurrency0 = mkt.yesToken < c.usdc;
        (address cur0, address cur1) = yesIsCurrency0 ? (mkt.yesToken, c.usdc) : (c.usdc, mkt.yesToken);
        PoolKey memory key = PoolKey({
            currency0: Currency.wrap(cur0),
            currency1: Currency.wrap(cur1),
            fee: DYNAMIC_FEE_FLAG,
            tickSpacing: TICK_SPACING,
            hooks: IHooks(c.hook)
        });
        PoolId pid = PoolIdLibrary.toId(key);

        if (IPrediXHook(c.hook).poolMarketId(pid) == 0) {
            IPrediXHook(c.hook).registerMarketPool(marketId, key);
        }

        uint160 sqrtPriceX96 = yesIsCurrency0 ? SQRT_PRICE_MID_YES_CURRENCY0 : SQRT_PRICE_MID_YES_CURRENCY1;
        (uint160 existingSqrtPrice,,,) = StateLibrary.getSlot0(IPoolManager(c.poolManager), pid);
        if (existingSqrtPrice == 0) {
            IPoolManager(c.poolManager).initialize(key, sqrtPriceX96);
        }

        uint256 slack = c.lpUsdc / 1000;
        if (slack == 0) slack = 1;
        uint256 splitAmount = c.lpUsdc * 2 + slack;
        IERC20(c.usdc).approve(c.diamond, splitAmount);
        IMarketFacet(c.diamond).splitPosition(marketId, splitAmount);

        IERC20(mkt.yesToken).approve(c.router, type(uint256).max);
        IERC20(c.usdc).approve(c.router, type(uint256).max);

        ModifyLiquidityParams memory params = ModifyLiquidityParams({
            tickLower: MIN_TICK_ALIGNED,
            tickUpper: MAX_TICK_ALIGNED,
            liquidityDelta: int256(c.lpL),
            salt: bytes32(0)
        });
        IPoolModifyLiquidityTest(c.router).modifyLiquidity(key, params, "");
        console2.log("Seeded full-range LP for marketId:", marketId);
    }

    function _toJson(uint256[] memory arr) internal pure returns (string memory out) {
        out = "[";
        for (uint256 i; i < arr.length; ++i) {
            out = string.concat(out, vm.toString(arr[i]));
            if (i + 1 < arr.length) out = string.concat(out, ",");
        }
        out = string.concat(out, "]");
    }
}
