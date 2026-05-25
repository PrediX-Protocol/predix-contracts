// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import {Script, console2} from "forge-std/Script.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {IMarketFacet} from "@predix/shared/interfaces/IMarketFacet.sol";
import {IPrediXExchange} from "@predix/exchange/IPrediXExchange.sol";

interface ITestUSDC {
    function mint(address to, uint256 amount) external;
}

/// @notice Seed the displayed YES probability of the four launch markets to
///         realistic odds via one pure-CLOB COMPLEMENTARY match per market.
///
/// @dev    Mechanic (no AMM, no fee skew, no TakerFilled override):
///           1. maker (HD-0, deployer / TestUSDC owner) splits USDC -> YES+NO and
///              rests a SELL_YES limit order at the target price P.
///           2. taker (HD-6, creator) places a crossing BUY_YES @ P.
///           3. MakerPath._matchCompAtTick fills COMPLEMENTARY at makerPrice = P,
///              emitting OrderMatched(price = P, makerSide = SELL_YES). The indexer's
///              handleOrderMatched then sets market.latestYesPrice = P exactly
///              (makerIsYes => yesPrice = price). P2 mark-price renders that as the
///              displayed odds.
///
///         Why placeOrder (not fillMarketOrder): the taker path additionally emits
///         TakerFilled, whose indexer-derived price is fee/slippage-skewed and
///         (higher logIndex) would overwrite the clean OrderMatched price. Two
///         crossing placeOrder calls avoid TakerFilled entirely.
///
///         Why two HD keys: the Exchange skips self-matches (maker.owner ==
///         taker.owner), so maker and taker MUST differ. Both HD-0 and HD-6 are
///         pre-funded with ETH + USDC on mainnet, so no in-script funding loop.
///
///         BROADCAST: run with `--slow` so each maker SELL_YES is mined before the
///         taker's BUY_YES tries to cross it (deterministic maker-rests-first).
///
///         Required env: MNEMONIC. Optional (default to live Unichain mainnet):
///         DIAMOND_ADDRESS, EXCHANGE_ADDRESS, USDC_ADDRESS.
contract SeedMarketPrices is Script {
    using SafeERC20 for IERC20;

    // Authoritative Unichain mainnet (chainId 130) addresses — overridable via env.
    address internal constant DEFAULT_DIAMOND = 0xC8F12AF2a396c9C906ac36Bc0AC2279BBb69Ef96;
    address internal constant DEFAULT_EXCHANGE = 0x506367C7c48C95A4843F45d5C2F177B35e69594E;
    address internal constant DEFAULT_USDC = 0xB3FCA863dD0F6b496cCDDf6497Da5Dad67857F56;

    // Outcome tokens per seed match. >= MIN_ORDER_AMOUNT (1e6); small so the match
    // adds only trivial volume / collateral noise.
    uint256 internal constant AMOUNT = 10e6;

    struct Cfg {
        uint256 makerKey;
        uint256 takerKey;
        address maker;
        address taker;
        address diamond;
        address exchange;
        address usdc;
    }

    function run() external {
        Cfg memory c = _load();

        uint256[4] memory ids = [uint256(28), uint256(29), uint256(30), uint256(31)];
        // Target YES probability in 6-dec pip, tick-aligned (multiple of 10_000):
        //   #28 Hormuz 47c, #29 Vance 19c, #30 Newsom 16c, #31 Rubio 13c.
        uint256[4] memory prices = [uint256(470_000), uint256(190_000), uint256(160_000), uint256(130_000)];
        address[4] memory yesTokens;

        // --- Pre-flight: every market live + readable (reads, no tx). ---
        for (uint256 k; k < 4; ++k) {
            (address yes,, uint256 endTime, bool resolved, bool refunding) =
                IMarketFacet(c.diamond).getMarketStatus(ids[k]);
            require(yes != address(0), "market missing");
            require(block.timestamp < endTime, "market expired");
            require(!resolved && !refunding, "market not active");
            yesTokens[k] = yes;
            console2.log("pre  market", ids[k]);
            console2.log("     yesToken", yes);
        }

        uint256 splitTotal = AMOUNT * 4; // maker splits AMOUNT per market
        uint256 takerBudget = _buyBudget(prices); // USDC the taker needs across all 4 buys

        // ===================== Phase 1 — maker (HD-0): rest SELL_YES @ P =====================
        vm.startBroadcast(c.makerKey);

        // HD-0 is the TestUSDC owner — top up itself (for splits) and the taker
        // (for buys) if short, so neither leg can run dry. No-op when funded.
        if (IERC20(c.usdc).balanceOf(c.maker) < splitTotal) {
            ITestUSDC(c.usdc).mint(c.maker, splitTotal - IERC20(c.usdc).balanceOf(c.maker));
        }
        if (IERC20(c.usdc).balanceOf(c.taker) < takerBudget) {
            ITestUSDC(c.usdc).mint(c.taker, takerBudget - IERC20(c.usdc).balanceOf(c.taker));
        }

        IERC20(c.usdc).forceApprove(c.diamond, type(uint256).max); // for splitPosition
        for (uint256 k; k < 4; ++k) {
            IMarketFacet(c.diamond).splitPosition(ids[k], AMOUNT); // -> AMOUNT YES + AMOUNT NO
            IERC20(yesTokens[k]).forceApprove(c.exchange, AMOUNT); // SELL_YES deposit pulls AMOUNT YES
            IPrediXExchange(c.exchange).placeOrder(ids[k], IPrediXExchange.Side.SELL_YES, prices[k], AMOUNT, bytes32(0));
        }
        vm.stopBroadcast();

        // ===================== Phase 2 — taker (HD-6): cross with BUY_YES @ P =====================
        vm.startBroadcast(c.takerKey);
        IERC20(c.usdc).forceApprove(c.exchange, type(uint256).max); // BUY_YES deposit
        for (uint256 k; k < 4; ++k) {
            (, uint256 filled) =
                IPrediXExchange(c.exchange).placeOrder(ids[k], IPrediXExchange.Side.BUY_YES, prices[k], AMOUNT, bytes32(0));
            require(filled == AMOUNT, "seed match incomplete");
        }
        vm.stopBroadcast();

        // --- Post-flight: book empty again (both legs consumed) => bestBid/Ask 0. ---
        for (uint256 k; k < 4; ++k) {
            (uint256 bidY, uint256 askY,,) = IPrediXExchange(c.exchange).getBestPrices(ids[k]);
            console2.log("post market", ids[k]);
            console2.log("     target yesPrice", prices[k]);
            console2.log("     bestBidYes / bestAskYes", bidY, askY);
        }
        console2.log("maker (HD-0)", c.maker);
        console2.log("taker (HD-6)", c.taker);
        console2.log("done: latestYesPrice seeds to 47/19/16/13c after the indexer re-reads OrderMatched");
    }

    function _load() internal view returns (Cfg memory c) {
        string memory mnemonic = vm.envString("MNEMONIC");
        c.makerKey = vm.deriveKey(mnemonic, uint32(0)); // deployer (ETH + USDC, TestUSDC owner)
        c.takerKey = vm.deriveKey(mnemonic, uint32(6)); // creator (ETH + USDC)
        c.maker = vm.addr(c.makerKey);
        c.taker = vm.addr(c.takerKey);
        require(c.maker != c.taker, "maker == taker"); // Exchange forbids self-match
        c.diamond = vm.envOr("DIAMOND_ADDRESS", DEFAULT_DIAMOND);
        c.exchange = vm.envOr("EXCHANGE_ADDRESS", DEFAULT_EXCHANGE);
        c.usdc = vm.envOr("USDC_ADDRESS", DEFAULT_USDC);
    }

    function _buyBudget(uint256[4] memory prices) internal pure returns (uint256 total) {
        for (uint256 k; k < 4; ++k) {
            total += (AMOUNT * prices[k]) / 1e6;
        }
    }
}
