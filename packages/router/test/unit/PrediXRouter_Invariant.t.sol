// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {RouterFixture} from "../utils/RouterFixture.sol";
import {IPrediXExchangeView} from "@predix/router/interfaces/IPrediXExchangeView.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {PrediXRouter} from "@predix/router/PrediXRouter.sol";
import {MockDiamond} from "../mocks/MockDiamond.sol";
import {MockExchange} from "../mocks/MockExchange.sol";
import {MockERC20} from "../mocks/MockERC20.sol";

/// @dev Handler exercised by Foundry's invariant runner. Each handler action pre-configures
///      the CLOB mock to fill the full input via a single canned result, so the router's
///      balance invariants are exclusively driven by its own accounting (no AMM price impact
///      variance). Good at catching refund / settlement bugs without drowning in mock setup.
contract RouterInvariantHandler {
    PrediXRouter internal immutable router;
    MockDiamond internal immutable diamond;
    MockExchange internal immutable exchange;
    MockERC20 internal immutable usdc;
    MockERC20 internal immutable yes1;
    MockERC20 internal immutable no1;

    address internal immutable trader;
    uint256 internal immutable marketId;

    uint256 public totalUsdcIn;
    uint256 public totalUsdcOut;

    constructor(
        PrediXRouter _router,
        MockDiamond _diamond,
        MockExchange _exchange,
        MockERC20 _usdc,
        MockERC20 _yes,
        MockERC20 _no,
        address _trader,
        uint256 _marketId
    ) {
        router = _router;
        diamond = _diamond;
        exchange = _exchange;
        usdc = _usdc;
        yes1 = _yes;
        no1 = _no;
        trader = _trader;
        marketId = _marketId;
    }

    function buyYes(uint256 usdcIn, uint256 priceSeed) external {
        usdcIn = bound(usdcIn, 1_000, 100_000e6);
        priceSeed = bound(priceSeed, 100_000, 900_000); // 0.1..0.9 USDC/YES
        uint256 yesOut = (usdcIn * 1e6) / priceSeed;
        if (yesOut == 0) return;

        usdc.mint(trader, usdcIn);
        exchange.setResult(marketId, IPrediXExchangeView.Side.BUY_YES, yesOut, usdcIn);
        vm.prank(trader);
        usdc.approve(address(router), usdcIn);
        vm.prank(trader);
        try router.buyYes(marketId, usdcIn, 0, trader, 5, block.timestamp + 1 hours) returns (
            uint256, uint256, uint256
        ) {
            totalUsdcIn += usdcIn;
        } catch {}
    }

    function sellYes(uint256 yesIn, uint256 priceSeed) external {
        yesIn = bound(yesIn, 1_000, 100_000e6);
        priceSeed = bound(priceSeed, 100_000, 900_000);
        uint256 usdcOut = (yesIn * priceSeed) / 1e6;
        if (usdcOut == 0) return;

        yes1.mint(trader, yesIn);
        exchange.setResult(marketId, IPrediXExchangeView.Side.SELL_YES, usdcOut, yesIn);
        vm.prank(trader);
        yes1.approve(address(router), yesIn);
        vm.prank(trader);
        try router.sellYes(marketId, yesIn, 0, trader, 5, block.timestamp + 1 hours) returns (
            uint256, uint256, uint256
        ) {
            totalUsdcOut += usdcOut;
        } catch {}
    }

    // Foundry VM cheat-code surface reused via the StdCheats-free pattern above
    function bound(uint256 x, uint256 min, uint256 max) internal pure returns (uint256) {
        if (min >= max) return min;
        return min + (x % (max - min + 1));
    }

    // Expose the forge-std cheatcode address for invariant runners.
    address internal constant VM_ADDR = address(uint160(uint256(keccak256("hevm cheat code"))));
    Vm internal constant vm = Vm(VM_ADDR);
}

interface Vm {
    function prank(address) external;
}

contract PrediXRouter_Invariant is RouterFixture {
    RouterInvariantHandler internal handler;

    function setUp() public override {
        super.setUp();
        handler = new RouterInvariantHandler(router, diamond, exchange, usdc, yes1, no1, alice, MARKET_ID);

        // Restrict invariant fuzzer to the handler's public selectors.
        bytes4[] memory selectors = new bytes4[](2);
        selectors[0] = RouterInvariantHandler.buyYes.selector;
        selectors[1] = RouterInvariantHandler.sellYes.selector;
        targetSelector(FuzzSelector({addr: address(handler), selectors: selectors}));
        targetContract(address(handler));
    }

    /// @dev Router must never retain USDC between calls.
    function invariant_RouterUsdcBalanceIsZero() public view {
        assertEq(usdc.balanceOf(address(router)), 0);
    }

    /// @dev Router must never retain YES shares between calls.
    function invariant_RouterYesBalanceIsZero() public view {
        assertEq(yes1.balanceOf(address(router)), 0);
    }

    /// @dev Router must never retain NO shares between calls.
    function invariant_RouterNoBalanceIsZero() public view {
        assertEq(no1.balanceOf(address(router)), 0);
    }
}
