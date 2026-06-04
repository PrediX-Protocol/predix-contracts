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

/// @notice Sheet batch (STT 70-80): 2 binary markets + 9 multi-outcome events
///         (2-19 outcomes), each market/child seeded with a full-range ~200k
///         USDC + ~400k YES pool at p=0.5. Absolute UTC end times per the sheet.
/// @dev    Same two-signer model as Phase7CreateAndSeedBatch: create with the
///         CREATOR_ROLE signer (idx 6), seed with the funded deployer (idx 0).
///         Seed flow mirrors Phase7BootstrapChildPool (self-deploys the v4
///         modify-liquidity router when absent on this chain; idempotent on
///         register + initialize).
contract Phase7CreateAndSeedSheet is Script {
    uint160 internal constant SQRT_PRICE_MID_YES_CURRENCY0 = 56022770974786139918731938227;
    uint160 internal constant SQRT_PRICE_MID_YES_CURRENCY1 = 112045541949572279837463876454;

    uint24 internal constant DYNAMIC_FEE_FLAG = LPFeeLibrary.DYNAMIC_FEE_FLAG;
    int24 internal constant TICK_SPACING = 60;
    int24 internal constant MIN_TICK_ALIGNED = -887220;
    int24 internal constant MAX_TICK_ALIGNED = 887220;

    uint256 internal constant N = 60; // 2 binary + 58 event children

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
        console2.log("Created markets (count):", ids.length);
        console2.log(_toJson(ids));
        console2.log("=========================================================");

        _seedAll(e, lpPk, ids);

        console2.log("=========================================================");
        console2.log("SHEET BATCH COMPLETE: 11 markets created + full-range 200k LP");
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
        ids = new uint256[](N);
        uint256 p;

        vm.startBroadcast(creatorPk);

        // STT 70 (binary) — endTime 2029-01-20 10:00 UTC
        ids[p++] = IMarketFacet(e.diamond)
            .createMarket("Will President Trump be impeached during his term?", 1863597600, e.oracle);
        // STT 73 (binary) — endTime 2026-12-31 23:59 UTC
        ids[p++] =
            IMarketFacet(e.diamond).createMarket("$250 dollar bill with Trump's face by 2027?", 1798761540, e.oracle);

        // STT 71 (4) — 2026-06-02 10:00 UTC
        {
            string[] memory c = new string[](4);
            c[0] = "Janice STFU (Drake)";
            c[1] = "Choosin' Texas (Ella Langley)";
            c[2] = "Billie Jean (Michael Jackson)";
            c[3] = "Any other song / Other";
            p = _event(e, ids, p, "#1 on the Billboard Hot 100 chart for the Week of Jun 6, 2026?", c, 1780394400);
        }
        // STT 72 (2) — 2027-02-01 10:00 UTC
        {
            string[] memory c = new string[](2);
            c[0] = "Democratic Party";
            c[1] = "Republican Party";
            p = _event(e, ids, p, "Which party will win the U.S. House?", c, 1801476000);
        }
        // STT 74 (5) — 2026-09-30 23:59 UTC
        {
            string[] memory c = new string[](5);
            c[0] = "Before June 1, 2026";
            c[1] = "Before July 1, 2026";
            c[2] = "Before August 1, 2026";
            c[3] = "Before September 1, 2026";
            c[4] = "Before October 1, 2026";
            p = _event(e, ids, p, "Tulsi Gabbard out as Director of National Intelligence?", c, 1790812740);
        }
        // STT 75 (19) — 2026-11-29 23:59 UTC
        {
            string[] memory c = new string[](19);
            c[0] = "Max Verstappen";
            c[1] = "Lewis Hamilton";
            c[2] = "Charles Leclerc";
            c[3] = "Lando Norris";
            c[4] = "Oscar Piastri";
            c[5] = "George Russell";
            c[6] = "Carlos Sainz";
            c[7] = "Fernando Alonso";
            c[8] = "Sergio Perez";
            c[9] = "Kimi Antonelli";
            c[10] = "Oliver Bearman";
            c[11] = "Lance Stroll";
            c[12] = "Pierre Gasly";
            c[13] = "Esteban Ocon";
            c[14] = "Alex Albon";
            c[15] = "Yuki Tsunoda";
            c[16] = "Nico Hulkenberg";
            c[17] = "Valtteri Bottas";
            c[18] = "Any other driver / Other";
            p = _event(e, ids, p, "2026 F1 Drivers' Champion", c, 1795996740);
        }
        // STT 76 (3) — 2026-12-14 10:00 UTC
        {
            string[] memory c = new string[](3);
            c[0] = "Karen Bass";
            c[1] = "Spencer Pratt";
            c[2] = "Nithya Raman";
            p = _event(e, ids, p, "Who will be elected Mayor of Los Angeles in 2026?", c, 1797242400);
        }
        // STT 77 (7) — 2026-08-01 09:59 UTC
        {
            string[] memory c = new string[](7);
            c[0] = "Before July 1, 2026";
            c[1] = "Before August 1, 2026";
            c[2] = "Before September 1, 2026";
            c[3] = "Before October 1, 2026";
            c[4] = "Before January 1, 2027";
            c[5] = "Before April 1, 2027";
            c[6] = "Before July 1, 2027";
            p = _event(e, ids, p, "When will traffic at the Strait of Hormuz return to normal?", c, 1785578340);
        }
        // STT 78 (5) — 2026-06-17 13:59 UTC
        {
            string[] memory c = new string[](5);
            c[0] = "Fed maintains rate";
            c[1] = "Cut 25bps";
            c[2] = "Hike 25bps";
            c[3] = "Cut >25bps";
            c[4] = "Hike >25bps";
            p = _event(e, ids, p, "Fed decision in June?", c, 1781704740);
        }
        // STT 79 (4) — 2026-06-30 10:00 UTC
        {
            string[] memory c = new string[](4);
            c[0] = "Oklahoma City (Oklahoma City Thunder)";
            c[1] = "New York (New York Knicks)";
            c[2] = "San Antonio (San Antonio Spurs)";
            c[3] = "Cleveland (Cleveland Cavaliers)";
            p = _event(e, ids, p, "Pro Basketball Champion", c, 1782813600);
        }
        // STT 80 (9) — 2027-11-03 11:00 UTC
        {
            string[] memory c = new string[](9);
            c[0] = "Xavier Becerra";
            c[1] = "Tom Steyer";
            c[2] = "Steve Hilton";
            c[3] = "Eleni Kounalakis";
            c[4] = "Antonio Villaraigosa";
            c[5] = "Rob Bonta";
            c[6] = "Toni Atkins";
            c[7] = "Katie Porter";
            c[8] = "Matt Mahan";
            p = _event(e, ids, p, "California Governor winner?", c, 1825239600);
        }

        vm.stopBroadcast();
        require(p == N, "id count mismatch");
    }

    function _seedAll(Env memory e, uint256 lpPk, uint256[] memory ids) internal {
        uint256 lpUsdc = vm.envOr("LP_USDC_AMOUNT", uint256(200_000_000_000));
        uint256 lpL = vm.envOr("LP_LIQUIDITY_DELTA", uint256(282_842_712_474));

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
            tickLower: MIN_TICK_ALIGNED, tickUpper: MAX_TICK_ALIGNED, liquidityDelta: int256(c.lpL), salt: bytes32(0)
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
