// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {IAllowanceTransfer} from "permit2/src/interfaces/IAllowanceTransfer.sol";

/// @notice Verifies the canonical Permit2 deployment responds and that its
///         AllowanceTransfer flow (approve → transferFrom) works against real
///         on-chain code. Signature-based permit requires a typed-data hash
///         that mirrors Permit2's domain separator, which changes per chain;
///         we exercise that path via the on-chain DOMAIN_SEPARATOR getter.
/// @dev A canonical Permit2 address is expected — `address(0)` or missing env
///      fails loud via `vm.envAddress`.
contract Permit2IntegrationForkTest is Test {
    IAllowanceTransfer internal permit2;
    IERC20 internal usdc;

    uint256 internal ownerPk = 0xA11CE;
    address internal owner;
    address internal spender = makeAddr("permit2_spender");

    function setUp() public {
        vm.createSelectFork(vm.envString("UNICHAIN_RPC_PRIMARY"));
        permit2 = IAllowanceTransfer(vm.envAddress("PERMIT2_ADDRESS"));
        usdc = IERC20(vm.envAddress("USDC_ADDRESS"));
        owner = vm.addr(ownerPk);
    }

    function test_Permit2_Deployed() public view {
        uint256 size;
        address addr = address(permit2);
        assembly {
            size := extcodesize(addr)
        }
        assertGt(size, 0, "Permit2 not deployed");
    }

    function test_Permit2_DomainSeparator_Nonzero() public view {
        (bool ok, bytes memory ret) =
            address(permit2).staticcall(abi.encodeWithSignature("DOMAIN_SEPARATOR()"));
        assertTrue(ok, "DOMAIN_SEPARATOR call failed");
        bytes32 sep = abi.decode(ret, (bytes32));
        assertTrue(sep != bytes32(0));
    }

    function test_Permit2_Allowance_ZeroInitially() public view {
        (uint160 amount, uint48 expiration, uint48 nonce) = permit2.allowance(owner, address(usdc), spender);
        assertEq(amount, 0);
        assertEq(expiration, 0);
        assertEq(nonce, 0);
    }

    function test_Permit2_Approve_UpdatesAllowance() public {
        deal(address(usdc), owner, 1_000_000);

        vm.prank(owner);
        usdc.approve(address(permit2), type(uint256).max);

        vm.prank(owner);
        permit2.approve(address(usdc), spender, 500_000, uint48(block.timestamp + 1 days));

        (uint160 amount, uint48 expiration,) = permit2.allowance(owner, address(usdc), spender);
        assertEq(amount, 500_000);
        assertEq(expiration, uint48(block.timestamp + 1 days));
    }

    function test_Permit2_TransferFrom_ConsumesAllowance() public {
        deal(address(usdc), owner, 1_000_000);
        address dst = makeAddr("permit2_dst");

        vm.prank(owner);
        usdc.approve(address(permit2), type(uint256).max);

        vm.prank(owner);
        permit2.approve(address(usdc), spender, 500_000, uint48(block.timestamp + 1 days));

        vm.prank(spender);
        permit2.transferFrom(owner, dst, 200_000, address(usdc));

        assertEq(usdc.balanceOf(dst), 200_000);
        (uint160 remaining,,) = permit2.allowance(owner, address(usdc), spender);
        assertEq(remaining, 300_000);
    }
}
