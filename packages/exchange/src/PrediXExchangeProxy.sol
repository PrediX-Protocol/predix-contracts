// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {PrediXExchange} from "./PrediXExchange.sol";

/// @title PrediXExchangeProxy
/// @notice Minimal ERC-1967-style upgradeable proxy for `PrediXExchange`. Mirrors
///         the `PrediXHookProxyV2` pattern: namespaced storage slots for proxy-side
///         state, 48-hour timelocked upgrade flow, two-step admin rotation with 48h
///         delay. All exchange business logic is delegated to the current implementation.
/// @dev STORAGE: this contract MUST NOT declare any Solidity state variables.
///      The implementation's storage (orders, queues, bitmaps) lives at slots 0..N
///      in the proxy's storage context (via delegatecall). Proxy-side state lives
///      at keccak-derived namespaced slots to avoid collision.
contract PrediXExchangeProxy {
    using SafeERC20 for IERC20;

    // ======== Namespaced storage slots ========

    bytes32 private constant _IMPL_SLOT = bytes32(uint256(keccak256("predix.exchange.proxy.implementation")) - 1);
    bytes32 private constant _ADMIN_SLOT = bytes32(uint256(keccak256("predix.exchange.proxy.admin")) - 1);
    bytes32 private constant _PENDING_IMPL_SLOT = bytes32(uint256(keccak256("predix.exchange.proxy.pending.impl")) - 1);
    bytes32 private constant _UPGRADE_READY_AT_SLOT =
        bytes32(uint256(keccak256("predix.exchange.proxy.upgrade.ready_at")) - 1);
    bytes32 private constant _PENDING_ADMIN_SLOT =
        bytes32(uint256(keccak256("predix.exchange.proxy.pending.admin")) - 1);
    bytes32 private constant _PENDING_ADMIN_READY_AT_SLOT =
        bytes32(uint256(keccak256("predix.exchange.proxy.pending.admin.ready_at")) - 1);

    // ======== Constants ========

    uint256 public constant UPGRADE_DELAY = 48 hours;
    uint256 public constant ADMIN_ROTATION_DELAY = 48 hours;

    // ======== Errors ========

    error Proxy_OnlyAdmin();
    error Proxy_OnlyPendingAdmin();
    error Proxy_ZeroAddress();
    error Proxy_NotAContract();
    error Proxy_NoPendingUpgrade();
    error Proxy_UpgradeNotReady();
    error Proxy_AlreadyPendingUpgrade();
    error Proxy_NoPendingAdmin();
    error Proxy_AdminDelayNotElapsed();
    error Proxy_AlreadyPendingAdmin();
    error Proxy_InitReverted();

    // ======== Events ========

    event Upgraded(address indexed implementation);
    event UpgradeProposed(address indexed implementation, uint256 readyAt);
    event UpgradeCancelled(address indexed implementation);
    event AdminChanged(address indexed previous, address indexed current);
    event AdminChangeProposed(address indexed current, address indexed pending);
    event AdminChangeCancelled(address indexed cancelled);

    // ======== Modifiers ========

    modifier onlyAdmin() {
        if (msg.sender != _readAddress(_ADMIN_SLOT)) revert Proxy_OnlyAdmin();
        _;
    }

    // ======== Constructor ========

    /// @notice Deploy the proxy, set admin + impl, and atomically initialize
    ///         the Exchange via delegatecall so no front-run window exists.
    /// @param implementation_ Initial Exchange implementation address.
    /// @param admin_          Proxy admin (controls upgrades + admin rotation).
    /// @param diamond_        Diamond address passed to Exchange.initialize.
    /// @param usdc_           USDC address passed to Exchange.initialize.
    /// @param feeRecipient_   Initial fee recipient passed to Exchange.initialize.
    constructor(address implementation_, address admin_, address diamond_, address usdc_, address feeRecipient_) {
        if (implementation_ == address(0) || admin_ == address(0)) revert Proxy_ZeroAddress();
        if (implementation_.code.length == 0) revert Proxy_NotAContract();

        _writeAddress(_IMPL_SLOT, implementation_);
        _writeAddress(_ADMIN_SLOT, admin_);
        emit Upgraded(implementation_);
        emit AdminChanged(address(0), admin_);

        // Atomic init via delegatecall (mirrors Hook proxy C2 pattern).
        (bool ok, bytes memory ret) =
            implementation_.delegatecall(abi.encodeCall(PrediXExchange.initialize, (diamond_, usdc_, feeRecipient_)));
        if (!ok) {
            if (ret.length == 0) revert Proxy_InitReverted();
            assembly ("memory-safe") {
                revert(add(ret, 0x20), mload(ret))
            }
        }
    }

    // ======== Upgrade flow (48h timelock) ========

    function proposeUpgrade(address newImpl) external onlyAdmin {
        if (_readAddress(_PENDING_IMPL_SLOT) != address(0)) revert Proxy_AlreadyPendingUpgrade();
        if (newImpl == address(0)) revert Proxy_ZeroAddress();
        if (newImpl.code.length == 0) revert Proxy_NotAContract();
        uint256 readyAt = block.timestamp + UPGRADE_DELAY;
        _writeAddress(_PENDING_IMPL_SLOT, newImpl);
        _writeUint(_UPGRADE_READY_AT_SLOT, readyAt);
        emit UpgradeProposed(newImpl, readyAt);
    }

    function executeUpgrade() external onlyAdmin {
        address pending = _readAddress(_PENDING_IMPL_SLOT);
        if (pending == address(0)) revert Proxy_NoPendingUpgrade();
        if (block.timestamp < _readUint(_UPGRADE_READY_AT_SLOT)) revert Proxy_UpgradeNotReady();
        if (pending.code.length == 0) revert Proxy_NotAContract();
        _writeAddress(_IMPL_SLOT, pending);
        _writeAddress(_PENDING_IMPL_SLOT, address(0));
        _writeUint(_UPGRADE_READY_AT_SLOT, 0);
        emit Upgraded(pending);
    }

    function cancelUpgrade() external onlyAdmin {
        address pending = _readAddress(_PENDING_IMPL_SLOT);
        if (pending == address(0)) revert Proxy_NoPendingUpgrade();
        _writeAddress(_PENDING_IMPL_SLOT, address(0));
        _writeUint(_UPGRADE_READY_AT_SLOT, 0);
        emit UpgradeCancelled(pending);
    }

    // ======== Admin rotation (48h timelock) ========

    function changeAdmin(address newAdmin) external onlyAdmin {
        if (_readAddress(_PENDING_ADMIN_SLOT) != address(0)) revert Proxy_AlreadyPendingAdmin();
        if (newAdmin == address(0)) revert Proxy_ZeroAddress();
        _writeAddress(_PENDING_ADMIN_SLOT, newAdmin);
        _writeUint(_PENDING_ADMIN_READY_AT_SLOT, block.timestamp + ADMIN_ROTATION_DELAY);
        emit AdminChangeProposed(_readAddress(_ADMIN_SLOT), newAdmin);
    }

    function acceptAdmin() external {
        address pending = _readAddress(_PENDING_ADMIN_SLOT);
        if (msg.sender != pending) revert Proxy_OnlyPendingAdmin();
        if (block.timestamp < _readUint(_PENDING_ADMIN_READY_AT_SLOT)) revert Proxy_AdminDelayNotElapsed();
        address previous = _readAddress(_ADMIN_SLOT);
        _writeAddress(_ADMIN_SLOT, pending);
        _writeAddress(_PENDING_ADMIN_SLOT, address(0));
        _writeUint(_PENDING_ADMIN_READY_AT_SLOT, 0);
        emit AdminChanged(previous, pending);
    }

    function cancelAdminChange() external onlyAdmin {
        address pending = _readAddress(_PENDING_ADMIN_SLOT);
        if (pending == address(0)) revert Proxy_NoPendingAdmin();
        _writeAddress(_PENDING_ADMIN_SLOT, address(0));
        _writeUint(_PENDING_ADMIN_READY_AT_SLOT, 0);
        emit AdminChangeCancelled(pending);
    }

    // ======== Views ========

    function implementation() external view returns (address) {
        return _readAddress(_IMPL_SLOT);
    }

    function admin() external view returns (address) {
        return _readAddress(_ADMIN_SLOT);
    }

    function pendingImplementation() external view returns (address) {
        return _readAddress(_PENDING_IMPL_SLOT);
    }

    function upgradeReadyAt() external view returns (uint256) {
        return _readUint(_UPGRADE_READY_AT_SLOT);
    }

    function pendingAdmin() external view returns (address) {
        return _readAddress(_PENDING_ADMIN_SLOT);
    }

    function pendingAdminReadyAt() external view returns (uint256) {
        return _readUint(_PENDING_ADMIN_READY_AT_SLOT);
    }

    // ======== Fallback: delegate everything else to impl ========

    fallback() external payable {
        if (msg.value > 0) revert(); // Exchange is USDC-only, reject ETH.
        address impl = _readAddress(_IMPL_SLOT);
        assembly {
            calldatacopy(0, 0, calldatasize())
            let result := delegatecall(gas(), impl, 0, calldatasize(), 0, 0)
            returndatacopy(0, 0, returndatasize())
            switch result
            case 0 { revert(0, returndatasize()) }
            default { return(0, returndatasize()) }
        }
    }

    // ======== Internal slot I/O ========

    function _readAddress(bytes32 slot) private view returns (address value) {
        assembly ("memory-safe") {
            value := sload(slot)
        }
    }

    function _writeAddress(bytes32 slot, address value) private {
        assembly ("memory-safe") {
            sstore(slot, value)
        }
    }

    function _readUint(bytes32 slot) private view returns (uint256 value) {
        assembly ("memory-safe") {
            value := sload(slot)
        }
    }

    function _writeUint(bytes32 slot, uint256 value) private {
        assembly ("memory-safe") {
            sstore(slot, value)
        }
    }
}
