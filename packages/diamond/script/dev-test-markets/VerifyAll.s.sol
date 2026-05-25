// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import {DevBase} from "./_DevBase.sol";
import {console2} from "forge-std/Script.sol";
import {IMarketFacet} from "@predix/shared/interfaces/IMarketFacet.sol";
import {IPrediXExchange} from "@predix/exchange/IPrediXExchange.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";

/// @notice Verify each of the 10 dev-test markets matches its expected liquidity
///         profile end-to-end. Read-only — no broadcast.
contract VerifyAll is DevBase {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    struct Spec {
        uint256 marketId;
        string label;
        bool expectsPool;
        bool expectsLp;
        bool expectsClob;
        uint256 expectedTotalCollateral;
    }

    function run() external {
        Ctx memory c = _load();

        Spec[10] memory specs = [
            Spec(18, "Binary M1 Hybrid",     true,  true,  true,  200e6),
            Spec(19, "Binary M2 AMM-only",   true,  true,  false, 100e6),
            Spec(20, "Binary M3 CLOB-only",  false, false, true,  50e6),
            Spec(21, "Binary M4 Empty",      false, false, false, 0),
            Spec(22, "E1-child0 Hybrid",     true,  true,  true,  60e6),
            Spec(23, "E1-child1 Hybrid",     true,  true,  true,  60e6),
            Spec(24, "E1-child2 Hybrid",     true,  true,  true,  60e6),
            Spec(25, "E2-child0 CLOB",       false, false, true,  30e6),
            Spec(26, "E2-child1 CLOB",       false, false, true,  30e6),
            Spec(27, "E2-child2 CLOB",       false, false, true,  30e6)
        ];

        uint256 passed;
        uint256 failed;

        for (uint256 i = 0; i < 10; i++) {
            Spec memory s = specs[i];
            console2.log("");
            console2.log("---", s.marketId, s.label);
            IMarketFacet.MarketView memory mkt = IMarketFacet(c.diamond).getMarket(s.marketId);

            bool ok = true;

            // 1. Market exists + not resolved + not refund
            if (mkt.yesToken == address(0)) { console2.log("  FAIL: market does not exist"); ok = false; }
            if (mkt.isResolved) { console2.log("  FAIL: unexpected isResolved=true"); ok = false; }
            if (mkt.refundModeActive) { console2.log("  FAIL: unexpected refundModeActive=true"); ok = false; }

            // 2. totalCollateral matches expectation
            if (mkt.totalCollateral != s.expectedTotalCollateral) {
                console2.log("  FAIL: totalCollateral expected", s.expectedTotalCollateral, "got", mkt.totalCollateral);
                ok = false;
            } else {
                console2.log("  OK   totalCollateral =", mkt.totalCollateral);
            }

            // 3. AMM pool initialized?
            PoolKey memory key = _buildPoolKey(c, mkt.yesToken);
            PoolId pid = key.toId();
            (uint160 sqrtPriceX96,,,) = IPoolManager(c.poolManager).getSlot0(pid);
            if (s.expectsPool) {
                if (sqrtPriceX96 == 0) { console2.log("  FAIL: expected pool initialized but slot0=0"); ok = false; }
                else { console2.log("  OK   pool initialized, sqrtPriceX96 =", uint256(sqrtPriceX96)); }
            } else {
                if (sqrtPriceX96 != 0) { console2.log("  WARN: pool unexpectedly initialized"); }
                else { console2.log("  OK   no pool (expected)"); }
            }

            // 4. AMM liquidity
            uint128 liquidity = IPoolManager(c.poolManager).getLiquidity(pid);
            if (s.expectsLp) {
                if (liquidity == 0) { console2.log("  FAIL: expected AMM liquidity but got 0"); ok = false; }
                else { console2.log("  OK   AMM liquidity =", uint256(liquidity)); }
            } else {
                if (liquidity != 0) { console2.log("  WARN: unexpected liquidity =", uint256(liquidity)); }
                else { console2.log("  OK   no AMM liquidity (expected)"); }
            }

            // 5. CLOB depth at $0.50
            uint256 sy = IPrediXExchange(c.exchange).getDepthAtPrice(s.marketId, IPrediXExchange.Side.SELL_YES, 500000);
            uint256 sn = IPrediXExchange(c.exchange).getDepthAtPrice(s.marketId, IPrediXExchange.Side.SELL_NO, 500000);
            uint256 by = IPrediXExchange(c.exchange).getDepthAtPrice(s.marketId, IPrediXExchange.Side.BUY_YES, 500000);
            uint256 bn = IPrediXExchange(c.exchange).getDepthAtPrice(s.marketId, IPrediXExchange.Side.BUY_NO, 500000);
            uint256 totalClob = sy + sn + by + bn;
            if (s.expectsClob) {
                if (totalClob == 0) { console2.log("  FAIL: expected CLOB depth but all 4 sides empty"); ok = false; }
                else { console2.log("  OK   CLOB depth (SY/SN/BY/BN)", sy); console2.log("        ", sn, by, bn); }
            } else {
                if (totalClob != 0) { console2.log("  WARN: unexpected CLOB depth", totalClob); }
                else { console2.log("  OK   no CLOB orders (expected)"); }
            }

            if (ok) passed++; else failed++;
        }

        console2.log("");
        console2.log("============================");
        console2.log("VERIFY SUMMARY: passed =", passed);
        console2.log("                failed =", failed);
        console2.log("============================");
        if (failed > 0) revert("verify failed for some markets");
    }
}
