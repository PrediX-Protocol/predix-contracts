// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {Roles} from "@predix/shared/constants/Roles.sol";

import {IPrediXExchange} from "../../src/IPrediXExchange.sol";
import {PrediXExchange} from "../../src/PrediXExchange.sol";

import {ExchangeTestBase} from "../base/ExchangeTestBase.sol";

/// @title Audit_PRE_L01_RevokeOldDiamond
/// @notice Fix-lock for PRE-L01: the exchange grants the diamond
///         `type(uint256).max` USDC allowance at initialize for the synthetic
///         MINT path. If an impl upgrade rebinds the exchange to a new
///         diamond, the old diamond would retain pull rights unless the
///         allowance is explicitly revoked. `revokeOldDiamondAllowance` zeroes
///         the residual allowance under the current diamond's ADMIN_ROLE
///         guard, and refuses to touch the live binding.
contract Audit_PRE_L01_RevokeOldDiamond is ExchangeTestBase {
    address internal admin = makeAddr("admin");
    address internal nonAdmin = makeAddr("nonAdmin");
    address internal oldDiamond = makeAddr("oldDiamond");

    function setUp() public override {
        super.setUp();
        // Grant ADMIN_ROLE on the (mock) diamond so the exchange's onlyAdmin
        // modifier permits the test's admin actor.
        diamond.grantRole(Roles.ADMIN_ROLE, admin);
    }

    /// @dev Happy path: an out-of-band allowance to a stale diamond is zeroed.
    function test_RevokeOldDiamond_ZeroesAllowance() public {
        // Simulate the historical state: exchange had previously approved an
        // old diamond. The current allowance after setUp is to the live mock
        // diamond, set in `initialize`. Approve a separate `oldDiamond` to
        // mimic the post-rotation residual that the fix targets.
        vm.prank(address(exchange));
        usdc.approve(oldDiamond, type(uint256).max);
        assertEq(
            usdc.allowance(address(exchange), oldDiamond), type(uint256).max, "precondition: residual allowance"
        );

        vm.prank(admin);
        exchange.revokeOldDiamondAllowance(oldDiamond);

        assertEq(usdc.allowance(address(exchange), oldDiamond), 0, "allowance revoked");
    }

    /// @dev Idempotent: zero allowance stays at zero, no revert.
    function test_RevokeOldDiamond_Idempotent() public {
        assertEq(usdc.allowance(address(exchange), oldDiamond), 0, "starts at zero");

        vm.prank(admin);
        exchange.revokeOldDiamondAllowance(oldDiamond);

        assertEq(usdc.allowance(address(exchange), oldDiamond), 0);
    }

    /// @dev Refuses to revoke the live diamond's allowance — would break the
    ///      synthetic MINT path silently.
    function test_RevokeOldDiamond_Revert_OnCurrentDiamond() public {
        vm.prank(admin);
        vm.expectRevert(PrediXExchange.Exchange_CannotRevokeCurrentDiamond.selector);
        exchange.revokeOldDiamondAllowance(address(diamond));
    }

    function test_RevokeOldDiamond_Revert_OnZeroAddress() public {
        vm.prank(admin);
        vm.expectRevert(IPrediXExchange.ZeroAddress.selector);
        exchange.revokeOldDiamondAllowance(address(0));
    }

    function test_RevokeOldDiamond_Revert_NonAdmin() public {
        vm.prank(nonAdmin);
        vm.expectRevert(PrediXExchange.OnlyAdmin.selector);
        exchange.revokeOldDiamondAllowance(oldDiamond);
    }
}
