// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {Roles} from "@predix/shared/constants/Roles.sol";

import {PrediXExchange} from "@predix/exchange/PrediXExchange.sol";
import {IPrediXHook} from "@predix/hook/interfaces/IPrediXHook.sol";

import {MainnetForkFixture} from "../utils/MainnetForkFixture.sol";

/// @title MainnetForkFixture_Smoke
/// @notice Verifies every wiring step in the `MainnetForkFixture.setUp()` flow
///         against forked mainnet state. Each test asserts a single invariant
///         of the deployed stack so a failure points directly at the broken
///         section of the fixture.
contract MainnetForkFixture_Smoke is MainnetForkFixture {
    using StateLibrary for IPoolManager;

    function test_Smoke_External_USDCDeployed() public view {
        assertGt(address(usdc).code.length, 0, "USDC has no code");
        // A standard ERC-20 read must succeed. Balance is not asserted to a
        // specific value because mainnet state is observed unmodified.
        IERC20(address(usdc)).balanceOf(address(0xdead));
    }

    function test_Smoke_External_PoolManagerDeployed() public view {
        assertGt(address(poolManager).code.length, 0, "PoolManager has no code");
    }

    function test_Smoke_External_QuoterDeployed() public view {
        assertGt(address(quoter).code.length, 0, "V4Quoter has no code");
    }

    function test_Smoke_External_Permit2Deployed() public view {
        assertGt(address(permit2).code.length, 0, "Permit2 has no code");
    }

    function test_Smoke_Diamond_Initialized() public view {
        assertGt(address(diamond).code.length, 0, "Diamond not deployed");
        assertTrue(accessControl.hasRole(0x00, admin), "admin not granted DEFAULT_ADMIN");
        assertTrue(accessControl.hasRole(Roles.CUT_EXECUTOR_ROLE, timelock), "timelock not granted CUT_EXECUTOR");
    }

    function test_Smoke_Diamond_MarketFacetCut() public view {
        assertEq(market.marketCount(), 1, "Default market should exist");
    }

    function test_Smoke_Diamond_EventFacetCut() public view {
        assertEq(eventFacet.eventCount(), 0, "Event count starts at 0");
    }

    function test_Smoke_Exchange_Deployed() public view {
        assertGt(address(exchange).code.length, 0, "Exchange proxy not deployed");
        // Access PrediXExchange storage getters via the proxy. The interface
        // type IPrediXExchange doesn't expose `diamond()` / `usdc()` so we
        // cast to the impl type — the proxy delegates the call.
        assertEq(PrediXExchange(address(exchangeProxy)).diamond(), address(diamond), "Exchange wired to diamond");
        assertEq(PrediXExchange(address(exchangeProxy)).usdc(), address(usdc), "Exchange wired to real USDC");
    }

    function test_Smoke_Hook_DeployedAndWired() public view {
        assertGt(address(hook).code.length, 0, "Hook proxy not deployed");
        // Proxy delegates getters to impl via fallback; cast through IPrediXHook.
        IPrediXHook hookView = IPrediXHook(address(hook));
        assertEq(hookView.diamond(), address(diamond), "Hook wired to diamond");
        assertEq(hookView.quoteToken(), address(usdc), "Hook wired to real USDC");
        assertTrue(hookView.bootstrapped(), "Hook bootstrap should be complete");
    }

    function test_Smoke_Hook_TrustsRouterAndQuoter() public view {
        IPrediXHook hookView = IPrediXHook(address(hook));
        assertTrue(hookView.isTrustedRouter(address(router)), "Hook should trust router");
        assertTrue(hookView.isTrustedRouter(address(quoter)), "Hook should trust quoter");
    }

    function test_Smoke_Router_Deployed() public view {
        assertGt(address(router).code.length, 0, "Router not deployed");
        assertEq(router.diamond(), address(diamond), "Router wired to diamond");
        assertEq(router.usdc(), address(usdc), "Router wired to USDC");
        assertEq(router.hook(), address(hook), "Router wired to hook");
        assertEq(router.exchange(), address(exchange), "Router wired to exchange");
    }

    function test_Smoke_Router_ZeroBalance() public view {
        // Router-stateless invariant: the contract holds no funds at rest.
        assertEq(usdc.balanceOf(address(router)), 0, "Router USDC balance must be 0");
        assertEq(IERC20(yesToken).balanceOf(address(router)), 0, "Router YES balance must be 0");
        assertEq(IERC20(noToken).balanceOf(address(router)), 0, "Router NO balance must be 0");
    }

    function test_Smoke_Market_Created() public view {
        assertGt(marketId, 0, "marketId not set");
        assertTrue(yesToken != address(0), "yesToken not set");
        assertTrue(noToken != address(0), "noToken not set");
        // Default market endTime is 30 days from setUp's block.timestamp. The
        // ±1 day tolerance accommodates block-time drift between fork
        // selection and the createMarket transaction.
        uint256 endTime = market.getMarket(marketId).endTime;
        assertGt(endTime, block.timestamp + 29 days, "endTime should be ~30 days out");
        assertLt(endTime, block.timestamp + 31 days, "endTime should be ~30 days out");
    }

    function test_Smoke_Pool_Initialized() public view {
        (uint160 sqrtPriceX96,,,) = poolManager.getSlot0(poolKey.toId());
        assertGt(sqrtPriceX96, 0, "Pool not initialized");
    }

    function test_Smoke_Liquidity_Provided() public view {
        // PoolManager should have non-zero USDC and YES balances from the LP's deposit
        assertGt(usdc.balanceOf(address(poolManager)), 0, "PoolManager should hold USDC");
        assertGt(IERC20(yesToken).balanceOf(address(poolManager)), 0, "PoolManager should hold YES");
    }

    function test_Smoke_LP_HasRemainingNoTokens() public view {
        // The fixture splits 100K USDC into 100K YES + 100K NO. The YES leg
        // funds AMM liquidity; the NO leg remains with the LP.
        assertEq(IERC20(noToken).balanceOf(lp), 100_000e6, "LP should hold 100K NO");
    }

    function test_Smoke_Actors_Funded() public view {
        assertEq(usdc.balanceOf(alice), 100_000e6, "alice not funded");
        assertEq(usdc.balanceOf(bob), 100_000e6, "bob not funded");
        assertEq(usdc.balanceOf(charlie), 100_000e6, "charlie not funded");
    }

    function test_Smoke_Oracle_Approved() public view {
        assertTrue(market.isOracleApproved(address(oracle)), "Oracle not approved");
    }

    function test_Smoke_Creator_Role_Granted() public view {
        assertTrue(accessControl.hasRole(Roles.CREATOR_ROLE, creator), "creator role not granted");
    }

    function test_Smoke_USDC_StandardBehavior() public {
        deal(address(usdc), address(0xc0ffee), 1_000e6);
        assertEq(usdc.balanceOf(address(0xc0ffee)), 1_000e6, "deal failed on USDC");

        vm.prank(address(0xc0ffee));
        usdc.transfer(address(0xbeef), 500e6);
        assertEq(usdc.balanceOf(address(0xbeef)), 500e6, "real USDC transfer failed");
    }
}
