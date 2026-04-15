// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/// @notice Verifies the real canonical USDC on the configured chain honours
///         the assumptions baked into the protocol: 6 decimals, standard
///         transfer/transferFrom semantics, no fee-on-transfer.
/// @dev Reads RPC URL and token address from environment — fails loud if
///      either is unset, which is the intended behavior: fork tests are
///      off-path and must refuse to run with bad config rather than silently
///      fall back to mocks.
contract USDCBehaviorForkTest is Test {
    using SafeERC20 for IERC20;

    IERC20 internal usdc;
    address internal user = makeAddr("usdc_user");

    function setUp() public {
        vm.createSelectFork(vm.envString("UNICHAIN_RPC_PRIMARY"));
        usdc = IERC20(vm.envAddress("USDC_ADDRESS"));
    }

    function test_Decimals_Is6() public view {
        assertEq(IERC20Metadata(address(usdc)).decimals(), 6);
    }

    function test_Symbol_IsUSDC() public view {
        assertEq(IERC20Metadata(address(usdc)).symbol(), "USDC");
    }

    function test_Transfer_StandardSemantics() public {
        deal(address(usdc), user, 1_000_000);
        address dst = makeAddr("usdc_dst");
        vm.prank(user);
        usdc.transfer(dst, 500_000);
        assertEq(usdc.balanceOf(user), 500_000);
        assertEq(usdc.balanceOf(dst), 500_000);
    }

    function test_TransferFrom_WithApproval() public {
        deal(address(usdc), user, 1_000_000);
        address spender = address(this);
        address dst = makeAddr("usdc_via_spender");
        vm.prank(user);
        usdc.approve(spender, 500_000);
        usdc.safeTransferFrom(user, dst, 500_000);
        assertEq(usdc.balanceOf(dst), 500_000);
        assertEq(usdc.allowance(user, spender), 0);
    }

    function test_NoFeeOnTransfer() public {
        uint256 amount = 100_000;
        deal(address(usdc), user, amount);
        address dst = makeAddr("usdc_fot_check");
        uint256 before = usdc.balanceOf(dst);
        vm.prank(user);
        usdc.transfer(dst, amount);
        assertEq(usdc.balanceOf(dst) - before, amount, "fee-on-transfer detected");
        assertEq(usdc.balanceOf(user), 0, "sender residual non-zero");
    }
}
