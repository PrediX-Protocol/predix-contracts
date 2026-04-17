// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {RouterFixture} from "../utils/RouterFixture.sol";
import {IPrediXRouter} from "@predix/router/interfaces/IPrediXRouter.sol";
import {IPrediXExchangeView} from "@predix/router/interfaces/IPrediXExchangeView.sol";
import {IAllowanceTransfer} from "permit2/src/interfaces/IAllowanceTransfer.sol";

contract PrediXRouter_Permit2 is RouterFixture {
    function _permit(address token, uint160 amount, uint48 deadline)
        internal
        view
        returns (IAllowanceTransfer.PermitSingle memory)
    {
        return IAllowanceTransfer.PermitSingle({
            details: IAllowanceTransfer.PermitDetails({token: token, amount: amount, expiration: deadline, nonce: 0}),
            spender: address(router),
            sigDeadline: deadline
        });
    }

    function test_Permit2_BuyYes_HappyPath() public {
        uint256 usdcIn = 100e6;
        exchange.setResult(MARKET_ID, IPrediXExchangeView.Side.BUY_YES, 200e6, usdcIn);

        // Alice approves Permit2 to pull USDC (mock permit2 uses plain transferFrom).
        vm.prank(alice);
        usdc.approve(address(permit2), type(uint256).max);

        IAllowanceTransfer.PermitSingle memory p =
            _permit(address(usdc), uint160(usdcIn), uint48(block.timestamp + 1 hours));
        vm.prank(alice);
        (uint256 yesOut,,) = router.buyYesWithPermit(MARKET_ID, usdcIn, 0, alice, 5, _deadline(), p, "");
        assertEq(yesOut, 200e6);
        assertEq(permit2.permitCount(), 1);
    }

    function test_Revert_Permit2_InvalidSignature() public {
        permit2.setRevertOnPermit(true);
        vm.prank(alice);
        usdc.approve(address(permit2), type(uint256).max);

        IAllowanceTransfer.PermitSingle memory p =
            _permit(address(usdc), uint160(100e6), uint48(block.timestamp + 1 hours));
        vm.prank(alice);
        vm.expectRevert(bytes("MockPermit2: invalid signature"));
        router.buyYesWithPermit(MARKET_ID, 100e6, 0, alice, 5, _deadline(), p, "");
    }

    function test_Revert_Permit2_TokenMismatch() public {
        vm.prank(alice);
        usdc.approve(address(permit2), type(uint256).max);

        // Permit references the YES token, not USDC.
        IAllowanceTransfer.PermitSingle memory p =
            _permit(address(yes1), uint160(100e6), uint48(block.timestamp + 1 hours));
        vm.prank(alice);
        vm.expectRevert(IPrediXRouter.InvalidPermitToken.selector);
        router.buyYesWithPermit(MARKET_ID, 100e6, 0, alice, 5, _deadline(), p, "");
    }

    function test_Revert_Permit2_AmountMismatch_Under() public {
        // NEW-M5 post-fix: _consumePermit enforces amount == permit.amount.
        // Permit signed for less than the trade reverts InvalidPermitAmount.
        vm.prank(alice);
        usdc.approve(address(permit2), type(uint256).max);

        IAllowanceTransfer.PermitSingle memory p =
            _permit(address(usdc), uint160(50e6), uint48(block.timestamp + 1 hours));
        vm.prank(alice);
        vm.expectRevert(IPrediXRouter.InvalidPermitAmount.selector);
        router.buyYesWithPermit(MARKET_ID, 100e6, 0, alice, 5, _deadline(), p, "");
    }

    function test_Revert_Permit2_AmountMismatch_Over() public {
        // NEW-M5 post-fix: permit signed for MORE than the trade also reverts.
        // Prevents residual Permit2 allowance accumulating on the router.
        vm.prank(alice);
        usdc.approve(address(permit2), type(uint256).max);

        IAllowanceTransfer.PermitSingle memory p =
            _permit(address(usdc), uint160(200e6), uint48(block.timestamp + 1 hours));
        vm.prank(alice);
        vm.expectRevert(IPrediXRouter.InvalidPermitAmount.selector);
        router.buyYesWithPermit(MARKET_ID, 100e6, 0, alice, 5, _deadline(), p, "");
    }

    function test_Revert_Permit2_PermitDeadlineExpired() public {
        vm.prank(alice);
        usdc.approve(address(permit2), type(uint256).max);

        // sigDeadline < block.timestamp  → the mock asserts sigDeadline
        IAllowanceTransfer.PermitSingle memory p = IAllowanceTransfer.PermitSingle({
            details: IAllowanceTransfer.PermitDetails({
                token: address(usdc), amount: uint160(100e6), expiration: uint48(block.timestamp + 1 hours), nonce: 0
            }),
            spender: address(router),
            sigDeadline: block.timestamp - 1
        });
        vm.prank(alice);
        vm.expectRevert(bytes("MockPermit2: permit expired"));
        router.buyYesWithPermit(MARKET_ID, 100e6, 0, alice, 5, _deadline(), p, "");
    }

    function test_Permit2_SellYes_HappyPath() public {
        exchange.setResult(MARKET_ID, IPrediXExchangeView.Side.SELL_YES, 60e6, 100e6);
        vm.prank(alice);
        yes1.approve(address(permit2), type(uint256).max);
        IAllowanceTransfer.PermitSingle memory p =
            _permit(address(yes1), uint160(100e6), uint48(block.timestamp + 1 hours));
        uint256 aliceUsdcBefore = usdc.balanceOf(alice);
        vm.prank(alice);
        router.sellYesWithPermit(MARKET_ID, 100e6, 0, alice, 5, _deadline(), p, "");
        assertEq(usdc.balanceOf(alice), aliceUsdcBefore + 60e6);
    }
}
