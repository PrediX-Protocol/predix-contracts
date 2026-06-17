// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import {Test} from "forge-std/Test.sol";
import {PrediXExchange} from "@predix/exchange/PrediXExchange.sol";
import {IPrediXExchange} from "@predix/exchange/IPrediXExchange.sol";

interface IExchangeProxyAdmin {
    function admin() external view returns (address);
    function implementation() external view returns (address);
    function pendingImplementation() external view returns (address);
    function upgradeReadyAt() external view returns (uint256);
    function proposeUpgrade(address newImpl) external;
    function executeUpgrade() external;
    function UPGRADE_DELAY() external view returns (uint256);
}

/// @notice Sub-plan 05 Task 2 — storage-layout safety for the Sub-plan 03 Exchange upgrade. On a chain-130
///         fork, deploy the new impl, run the REAL proxy upgrade flow (proposeUpgrade -> +48h -> executeUpgrade)
///         AS the proxy admin (prank), and assert no live state is perturbed and the new ERC-7201 namespaces
///         are clean. Nothing is broadcast; the admin is pranked.
/// @dev Requires env UNICHAIN_RPC_PRIMARY (+ optional EXCHANGE_ADDRESS / ORDER_ID). Skips if an upgrade is
///      already pending/live on the proxy. Run from packages/exchange.
contract FeeStorageLayoutForkSim is Test {
    address internal constant EXCHANGE = 0x506367C7c48C95A4843F45d5C2F177B35e69594E;

    // ERC-7201 slot literals (Sub-plan 03). Re-derived in-test below to assert they match.
    bytes32 internal constant BUILDER_SLOT = 0xa35e7c8baa3c0cb8b6083e44aeeab8e83487b5eefb283554ddf6e85e17c79000;
    bytes32 internal constant PROTOCOL_SLOT = 0xc2cb872bc9a3ca3724b5bbf38ae11b13de41b893f6d0b580ab2182f4ff581d00;

    function _erc7201(string memory ns) internal pure returns (bytes32) {
        return keccak256(abi.encode(uint256(keccak256(bytes(ns))) - 1)) & ~bytes32(uint256(0xff));
    }

    function test_Fork_ExchangeUpgrade_StorageLayout_Survives() public {
        vm.createSelectFork(vm.envString("UNICHAIN_RPC_PRIMARY"));
        address proxy = vm.envOr("EXCHANGE_ADDRESS", EXCHANGE);
        IExchangeProxyAdmin p = IExchangeProxyAdmin(proxy);

        // --- 0) ERC-7201 literals match the canonical derivation (catches a bad copy in the libs). ---
        assertEq(BUILDER_SLOT, _erc7201("predix.exchange.builderfee.v1"), "builder slot drift");
        assertEq(PROTOCOL_SLOT, _erc7201("predix.exchange.protocolfee.v1"), "protocol slot drift");
        assertTrue(BUILDER_SLOT != PROTOCOL_SLOT, "ns alias");
        assertTrue(uint256(BUILDER_SLOT) > 8 && uint256(PROTOCOL_SLOT) > 8, "ns collides with low slots");

        // --- 1) snapshot live state pre-upgrade ---
        address adminAddr = p.admin();
        address implBefore = p.implementation();
        bool pausedBefore = PrediXExchange(proxy).paused(); // slot-8 canary
        address diamondBefore = PrediXExchange(proxy).diamond();
        address usdcBefore = PrediXExchange(proxy).usdc();
        address feeRecipBefore = PrediXExchange(proxy).feeRecipient();
        bytes32 slot8Before = vm.load(proxy, bytes32(uint256(8))); // raw slot-8 word

        if (p.pendingImplementation() != address(0)) {
            vm.skip(true, "an upgrade is already pending on the live proxy - sim not applicable");
            return;
        }

        // --- 2) deploy new impl + run the REAL 2-step 48h upgrade as the proxy admin ---
        address newImpl = address(new PrediXExchange());
        vm.startPrank(adminAddr);
        p.proposeUpgrade(newImpl);
        assertEq(p.pendingImplementation(), newImpl, "pending not set");
        assertEq(p.upgradeReadyAt(), block.timestamp + p.UPGRADE_DELAY(), "readyAt != now+48h");
        // executing before the delay must revert (the 48h gate)
        vm.expectRevert();
        p.executeUpgrade();
        vm.warp(block.timestamp + p.UPGRADE_DELAY());
        p.executeUpgrade();
        vm.stopPrank();
        assertEq(p.implementation(), newImpl, "impl not swapped");
        assertEq(p.pendingImplementation(), address(0), "pending not cleared");

        // --- 3) NO-BRICK: slot-8 paused + the init triple survive byte-for-byte ---
        assertEq(PrediXExchange(proxy).paused(), pausedBefore, "paused flipped across upgrade");
        assertEq(vm.load(proxy, bytes32(uint256(8))), slot8Before, "slot-8 word changed");
        assertEq(PrediXExchange(proxy).diamond(), diamondBefore, "diamond changed");
        assertEq(PrediXExchange(proxy).usdc(), usdcBefore, "usdc changed");
        assertEq(PrediXExchange(proxy).feeRecipient(), feeRecipBefore, "feeRecipient changed");
        assertTrue(implBefore != newImpl, "expected a genuinely new impl");

        // --- 4) the new namespaces are zero on the live proxy (never written before) ---
        assertEq(vm.load(proxy, BUILDER_SLOT), bytes32(0), "builder ns dirty");
        assertEq(vm.load(proxy, PROTOCOL_SLOT), bytes32(0), "protocol ns dirty");
        assertEq(PrediXExchange(proxy).accruedProtocolFee(), 0, "accruedProtocolFee != 0");

        // --- 5) a known live order survives the upgrade (set ORDER_ID to a real live orderId; else skipped) ---
        // Uses getOrder() (interface), so the Order struct grew by `builder` (appended) without breaking old
        // entries — an old order reads builder == 0 and its owner/amount survive.
        bytes32 orderId = vm.envOr("ORDER_ID", bytes32(0));
        if (orderId != bytes32(0)) {
            IPrediXExchange.Order memory ord = PrediXExchange(proxy).getOrder(orderId);
            assertTrue(ord.owner != address(0), "known live order vanished after upgrade");
            assertEq(ord.builder, bytes32(0), "pre-fee order must read builder == 0 (appended field)");
        }
    }
}
