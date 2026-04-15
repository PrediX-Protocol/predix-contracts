// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";

import {OutcomeToken} from "@predix/shared/tokens/OutcomeToken.sol";
import {IOutcomeToken} from "@predix/shared/interfaces/IOutcomeToken.sol";

contract OutcomeTokenTest is Test {
    OutcomeToken internal token;
    address internal factory = address(0xF1);
    address internal alice = address(0xA1);
    address internal bob = address(0xB1);
    uint256 internal constant MARKET_ID = 42;

    function setUp() public {
        token = new OutcomeToken(factory, MARKET_ID, true, "PrediX YES #42", "pxY-42");
    }

    function test_Constructor_StoresImmutables() public view {
        assertEq(token.factory(), factory);
        assertEq(token.marketId(), MARKET_ID);
        assertTrue(token.isYes());
        assertEq(token.name(), "PrediX YES #42");
        assertEq(token.symbol(), "pxY-42");
        assertEq(token.decimals(), 6);
        assertEq(token.totalSupply(), 0);
    }

    function test_Mint_HappyPath() public {
        vm.prank(factory);
        token.mint(alice, 1_000_000);
        assertEq(token.balanceOf(alice), 1_000_000);
        assertEq(token.totalSupply(), 1_000_000);
    }

    function test_Burn_HappyPath() public {
        vm.startPrank(factory);
        token.mint(alice, 1_000_000);
        token.burn(alice, 400_000);
        vm.stopPrank();
        assertEq(token.balanceOf(alice), 600_000);
        assertEq(token.totalSupply(), 600_000);
    }

    function test_Revert_Mint_NotFactory() public {
        vm.prank(alice);
        vm.expectRevert(IOutcomeToken.OutcomeToken_NotFactory.selector);
        token.mint(alice, 1);
    }

    function test_Revert_Burn_NotFactory() public {
        vm.prank(factory);
        token.mint(alice, 1);
        vm.prank(alice);
        vm.expectRevert(IOutcomeToken.OutcomeToken_NotFactory.selector);
        token.burn(alice, 1);
    }

    function test_Transfer_BetweenUsers() public {
        vm.prank(factory);
        token.mint(alice, 1_000);
        vm.prank(alice);
        token.transfer(bob, 400);
        assertEq(token.balanceOf(alice), 600);
        assertEq(token.balanceOf(bob), 400);
    }

    function test_Permit_AllowsGaslessApproval() public {
        uint256 ownerPk = 0xA11CE;
        address owner = vm.addr(ownerPk);

        vm.prank(factory);
        token.mint(owner, 1_000);

        uint256 deadline = block.timestamp + 1 hours;
        bytes32 permitTypehash =
            keccak256("Permit(address owner,address spender,uint256 value,uint256 nonce,uint256 deadline)");
        bytes32 structHash = keccak256(abi.encode(permitTypehash, owner, bob, 500, token.nonces(owner), deadline));
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", token.DOMAIN_SEPARATOR(), structHash));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(ownerPk, digest);

        token.permit(owner, bob, 500, deadline, v, r, s);
        assertEq(token.allowance(owner, bob), 500);
    }

    function testFuzz_MintBurn_Roundtrip(uint128 mintAmt, uint128 burnAmt) public {
        burnAmt = uint128(bound(burnAmt, 0, mintAmt));
        vm.startPrank(factory);
        token.mint(alice, mintAmt);
        token.burn(alice, burnAmt);
        vm.stopPrank();
        assertEq(token.balanceOf(alice), uint256(mintAmt) - uint256(burnAmt));
        assertEq(token.totalSupply(), uint256(mintAmt) - uint256(burnAmt));
    }
}
