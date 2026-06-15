// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import {Test} from "forge-std/Test.sol";

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IV4Quoter} from "@uniswap/v4-periphery/src/interfaces/IV4Quoter.sol";
import {IAllowanceTransfer} from "permit2/src/interfaces/IAllowanceTransfer.sol";
import {LPFeeLibrary} from "@uniswap/v4-core/src/libraries/LPFeeLibrary.sol";
import {IBuilderRegistry} from "@predix/shared/interfaces/IBuilderRegistry.sol";

import {PrediXRouter} from "../../src/PrediXRouter.sol";
import {IPrediXRouter} from "../../src/interfaces/IPrediXRouter.sol";

import {MockERC20} from "../mocks/MockERC20.sol";
import {MockDiamond} from "../mocks/MockDiamond.sol";
import {MockExchange} from "../mocks/MockExchange.sol";
import {MockHook} from "../mocks/MockHook.sol";
import {MockPoolManager} from "../mocks/MockPoolManager.sol";
import {MockV4Quoter} from "../mocks/MockV4Quoter.sol";
import {MockPermit2} from "../mocks/MockPermit2.sol";
import {MockBuilderRegistry} from "../mocks/MockBuilderRegistry.sol";

/// @title PrediXRouterConstructorTest
/// @notice Constructor-input validation for the Router. Targets the deployer-typo
///         failure mode where `_permit2` is passed as an EOA or otherwise points
///         at an address with no contract code. The router CANNOT validate that
///         `_permit2` is the audited canonical deployment without breaking test
///         fixtures and pre-canonical-deployment chains, so the lightest viable
///         guard is `code.length > 0`. Production deploys SHOULD additionally
///         assert `address(permit2) == CANONICAL_PERMIT2` in their verifier.
contract PrediXRouterConstructorTest is Test {
    uint24 internal constant LP_FEE_FLAG = LPFeeLibrary.DYNAMIC_FEE_FLAG;
    int24 internal constant TICK_SPACING = 60;

    MockERC20 internal usdc;
    MockDiamond internal diamond;
    MockExchange internal exchange;
    MockHook internal hook;
    MockPoolManager internal poolManager;
    MockV4Quoter internal quoter;
    MockPermit2 internal permit2;
    MockBuilderRegistry internal builderRegistry;

    function setUp() public {
        usdc = new MockERC20("USD Coin", "USDC", 6);
        diamond = new MockDiamond(address(usdc));
        exchange = new MockExchange(address(usdc));
        hook = new MockHook();
        poolManager = new MockPoolManager();
        quoter = new MockV4Quoter();
        permit2 = new MockPermit2();
        builderRegistry = new MockBuilderRegistry();
    }

    function _newRouter(address permit2Addr) internal returns (PrediXRouter) {
        return new PrediXRouter(
            IPoolManager(address(poolManager)),
            address(diamond),
            address(usdc),
            address(hook),
            address(exchange),
            IV4Quoter(address(quoter)),
            IAllowanceTransfer(permit2Addr),
            LP_FEE_FLAG,
            TICK_SPACING,
            IBuilderRegistry(address(builderRegistry))
        );
    }

    function test_Constructor_AcceptsContractPermit2() public {
        PrediXRouter r = _newRouter(address(permit2));
        assertEq(address(r.permit2()), address(permit2));
    }

    function test_Revert_Constructor_Permit2IsEOA() public {
        address eoa = makeAddr("fakePermit2");
        // Sanity check: makeAddr returns an EOA with empty code.
        assertEq(eoa.code.length, 0);

        vm.expectRevert(IPrediXRouter.Permit2NotAContract.selector);
        _newRouter(eoa);
    }

    function test_Revert_Constructor_Permit2IsZero() public {
        // Zero address fails the existing ZeroAddress check before the code-length
        // probe — confirm we still get the ZeroAddress selector for back-compat.
        vm.expectRevert(IPrediXRouter.ZeroAddress.selector);
        _newRouter(address(0));
    }

    function test_CanonicalPermit2_Constant() public {
        // Off-chain tooling and `verifyPostDeploy` rely on this exact value.
        assertEq(
            PrediXRouter(_newRouter(address(permit2))).CANONICAL_PERMIT2(), 0x000000000022D473030F116dDEE9F6B43aC78BA3
        );
    }

    function test_Revert_Constructor_ZeroLpFeeFlag() public {
        vm.expectRevert(IPrediXRouter.InvalidLpFeeFlag.selector);
        new PrediXRouter(
            IPoolManager(address(poolManager)),
            address(diamond),
            address(usdc),
            address(hook),
            address(exchange),
            IV4Quoter(address(quoter)),
            IAllowanceTransfer(address(permit2)),
            0, // canonical pool shape requires the v4 dynamic-fee flag
            TICK_SPACING,
            IBuilderRegistry(address(builderRegistry))
        );
    }

    function test_Revert_Constructor_ZeroTickSpacing() public {
        vm.expectRevert(IPrediXRouter.InvalidTickSpacing.selector);
        new PrediXRouter(
            IPoolManager(address(poolManager)),
            address(diamond),
            address(usdc),
            address(hook),
            address(exchange),
            IV4Quoter(address(quoter)),
            IAllowanceTransfer(address(permit2)),
            LP_FEE_FLAG,
            0,
            IBuilderRegistry(address(builderRegistry))
        );
    }
}
