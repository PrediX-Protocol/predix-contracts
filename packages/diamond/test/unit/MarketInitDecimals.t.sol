// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import {Test} from "forge-std/Test.sol";

import {MarketInit} from "@predix/diamond/init/MarketInit.sol";

import {MockUSDC} from "../mocks/MockUSDC.sol";

/// @dev Collateral with a non-6 decimal count. The whole stack (outcome tokens,
///      AMM/router price math) assumes 1e6 = $1, so `MarketInit` must reject it.
contract Mock18Decimals {
    function decimals() external pure returns (uint8) {
        return 18;
    }
}

/// @notice Pins the 6-decimal collateral guard added to `MarketInit.init`.
contract MarketInitDecimalsTest is Test {
    MarketInit internal init;
    address internal feeRecipient = makeAddr("feeRecipient");

    function setUp() public {
        init = new MarketInit();
    }

    function test_Init_RevertsWhenCollateralNotSixDecimals() public {
        Mock18Decimals bad = new Mock18Decimals();
        vm.expectRevert(MarketInit.MarketInit_CollateralNotSixDecimals.selector);
        init.init(
            MarketInit.InitArgs({
                collateralToken: address(bad),
                feeRecipient: feeRecipient,
                marketCreationFee: 0,
                defaultPerMarketCap: 0
            })
        );
    }

    function test_Init_AcceptsSixDecimalCollateral() public {
        MockUSDC good = new MockUSDC();
        // Must not revert at the decimals guard.
        init.init(
            MarketInit.InitArgs({
                collateralToken: address(good),
                feeRecipient: feeRecipient,
                marketCreationFee: 0,
                defaultPerMarketCap: 0
            })
        );
    }

    /// @dev v1.3 — `initWithOutcomeImpl` must reject a zero-address master so the
    ///      misconfiguration surfaces at cut time, not at first `createMarket`.
    function test_InitWithOutcomeImpl_RevertsOnZeroImpl() public {
        MockUSDC good = new MockUSDC();
        vm.expectRevert(MarketInit.MarketInit_ZeroOutcomeImpl.selector);
        init.initWithOutcomeImpl(
            MarketInit.InitArgs({
                collateralToken: address(good),
                feeRecipient: feeRecipient,
                marketCreationFee: 0,
                defaultPerMarketCap: 0
            }),
            address(0)
        );
    }

    /// @dev Happy-path: setting a non-zero impl must not revert at the guard.
    ///      (Storage write isn't observable here because we're not delegatecalling
    ///      from a diamond; the integration coverage lives in DiamondDeployLibTest.)
    function test_InitWithOutcomeImpl_AcceptsNonZeroImpl() public {
        MockUSDC good = new MockUSDC();
        address mockImpl = makeAddr("outcomeTokenImpl");
        init.initWithOutcomeImpl(
            MarketInit.InitArgs({
                collateralToken: address(good),
                feeRecipient: feeRecipient,
                marketCreationFee: 0,
                defaultPerMarketCap: 0
            }),
            mockImpl
        );
    }
}
