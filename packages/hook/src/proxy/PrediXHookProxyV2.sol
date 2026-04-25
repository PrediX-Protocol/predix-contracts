// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {BaseHook} from "@openzeppelin/uniswap-hooks/src/base/BaseHook.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {BeforeSwapDelta} from "@uniswap/v4-core/src/types/BeforeSwapDelta.sol";
import {SwapParams, ModifyLiquidityParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";

import {IPrediXHook} from "../interfaces/IPrediXHook.sol";
import {IPrediXHookProxy} from "../interfaces/IPrediXHookProxy.sol";

/// @title PrediXHookProxyV2
/// @notice ERC1967-style upgradeable proxy for `PrediXHookV2` with a 48-hour upgrade
///         timelock and two-step proxy-admin rotation. The proxy itself is the address
///         registered with the Uniswap v4 PoolManager — every hook callback flows
///         through here and is delegate-forwarded to the current implementation.
/// @dev DEPLOYMENT — SALT MINING REQUIRED: this contract inherits `BaseHook`, whose
///      constructor calls `Hooks.validateHookPermissions(this, getHookPermissions())`.
///      The proxy MUST therefore be deployed via CREATE2 with a salt that produces an
///      address whose low-order bits match the permission bitmap below. Use
///      `v4-periphery/src/utils/HookMiner.sol` to mine the salt. The implementation
///      (`PrediXHookV2`) does NOT inherit `BaseHook` and can be deployed at any
///      address — every upgrade only needs a fresh impl deploy, not a fresh mining run.
/// @dev STORAGE: this contract MUST NOT declare any state variables. The
///      implementation contract uses regular slots (0..N) for its own state, and any
///      proxy-side state would collide. All proxy state lives at namespaced slots
///      written via assembly. The only "state" allowed in the proxy is `immutable`,
///      because immutables are stored in code, not storage.
contract PrediXHookProxyV2 is IPrediXHookProxy, BaseHook {
    // ---------------------------------------------------------------------
    // Storage slots (ERC1967 + custom timelock slots)
    // ---------------------------------------------------------------------

    /// @dev `bytes32(uint256(keccak256("eip1967.proxy.implementation")) - 1)`
    bytes32 private constant _IMPL_SLOT = 0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc;

    /// @dev `bytes32(uint256(keccak256("eip1967.proxy.admin")) - 1)`
    bytes32 private constant _ADMIN_SLOT = 0xb53127684a568b3173ae13b9f8a6016e243e63b6e8ee1178d6a717850b5d6103;

    /// @dev Custom slots are namespaced under "predix.hook.proxy.*". The `- 1`
    ///      pattern matches ERC1967 to make accidental preimage collisions impossible.
    bytes32 private constant _PENDING_ADMIN_SLOT = bytes32(uint256(keccak256("predix.hook.proxy.pending.admin")) - 1);
    bytes32 private constant _PENDING_IMPL_SLOT =
        bytes32(uint256(keccak256("predix.hook.proxy.pending.implementation")) - 1);
    bytes32 private constant _UPGRADE_READY_AT_SLOT =
        bytes32(uint256(keccak256("predix.hook.proxy.upgrade.ready_at")) - 1);
    bytes32 private constant _TIMELOCK_DURATION_SLOT =
        bytes32(uint256(keccak256("predix.hook.proxy.timelock.duration")) - 1);

    /// @dev SPEC-04 self-gated propose/execute for `timelockDuration`. Pending
    ///      slots are kept at fresh keccak-derived paths to avoid any chance of
    ///      colliding with the upgrade-flow slots above.
    bytes32 private constant _PENDING_TIMELOCK_DURATION_SLOT =
        bytes32(uint256(keccak256("predix.hook.proxy.pending.timelock.duration")) - 1);
    bytes32 private constant _PENDING_TIMELOCK_READY_AT_SLOT =
        bytes32(uint256(keccak256("predix.hook.proxy.pending.timelock.ready_at")) - 1);

    // ---------------------------------------------------------------------
    // Timelock bounds
    // ---------------------------------------------------------------------

    /// @notice Default timelock applied at construction. Mirrors the diamond /
    ///         Timelock governance cadence so every slow path is synchronised.
    uint256 private constant _DEFAULT_TIMELOCK = 48 hours;

    /// @notice Floor for `proposeTimelockDuration`. Raised from 24h → 48h per
    ///         FINAL-M06 so the proxy can never drop below the governance
    ///         cadence admin is committed to elsewhere.
    uint256 private constant _MIN_TIMELOCK = 48 hours;

    /// @notice Ceiling for `proposeTimelockDuration` (H-02 audit fix). Bounds
    ///         the timelock to a value that, combined with the SPEC-05
    ///         monotonic guard, cannot brick the upgrade governance via an
    ///         arithmetic overflow on `block.timestamp + current`. 30 days is
    ///         the industry standard upper bound (Aave / OZ TimelockController
    ///         conventions) — enough headroom for any legitimate cooldown
    ///         while keeping `block.timestamp + 30 days` safely within
    ///         uint256.
    uint256 private constant _MAX_TIMELOCK = 30 days;

    // ---------------------------------------------------------------------
    // Modifiers
    // ---------------------------------------------------------------------

    modifier onlyProxyAdmin() {
        if (msg.sender != _readAddress(_ADMIN_SLOT)) revert HookProxy_OnlyAdmin();
        _;
    }

    // ---------------------------------------------------------------------
    // Constructor
    // ---------------------------------------------------------------------

    /// @param poolManager_ Uniswap v4 PoolManager. Must match the value the
    ///        implementation was constructed with so the immutable read inside the
    ///        implementation's bytecode resolves to the correct address even though
    ///        the proxy is the call target.
    /// @param implementation_ Initial logic contract (`PrediXHookV2`). Must be a
    ///        deployed contract; reverts with `HookProxy_NotAContract` otherwise.
    /// @param proxyAdmin_ Initial proxy admin (controls upgrade flow). SHOULD be a
    ///        distinct key from `hookAdmin_` — these are two separate trust roles.
    /// @param hookAdmin_ Initial hook runtime admin (pause / router / diamond setter).
    /// @param diamond_ Initial diamond address bound to the hook.
    /// @param quoteToken_ Quote token (USDC) frozen at deploy time. All registered pools
    ///        must use this token as one of their two currencies.
    /// @dev C2 FIX — atomic init. The constructor delegate-forwards `initialize` into
    ///      the implementation BEFORE returning, so the proxy is fully bootstrapped at
    ///      the moment its address becomes observable. This closes the front-running
    ///      window that existed when init was a separate transaction.
    constructor(
        IPoolManager poolManager_,
        address implementation_,
        address proxyAdmin_,
        address hookAdmin_,
        address diamond_,
        address quoteToken_
    ) BaseHook(poolManager_) {
        if (
            implementation_ == address(0) || proxyAdmin_ == address(0) || hookAdmin_ == address(0)
                || diamond_ == address(0) || quoteToken_ == address(0)
        ) revert HookProxy_ZeroAddress();
        if (implementation_.code.length == 0) revert HookProxy_NotAContract();

        _writeAddress(_IMPL_SLOT, implementation_);
        _writeAddress(_ADMIN_SLOT, proxyAdmin_);
        _writeUint(_TIMELOCK_DURATION_SLOT, _DEFAULT_TIMELOCK);
        emit HookProxy_Upgraded(implementation_);
        emit HookProxy_AdminChanged(address(0), proxyAdmin_);
        emit HookProxy_TimelockDurationUpdated(0, _DEFAULT_TIMELOCK);

        (bool ok, bytes memory ret) =
            implementation_.delegatecall(abi.encodeCall(IPrediXHook.initialize, (diamond_, hookAdmin_, quoteToken_)));
        if (!ok) {
            if (ret.length == 0) revert HookProxy_InitReverted();
            assembly ("memory-safe") {
                revert(add(ret, 0x20), mload(ret))
            }
        }
    }

    // ---------------------------------------------------------------------
    // Upgrade flow
    // ---------------------------------------------------------------------

    /// @inheritdoc IPrediXHookProxy
    function proposeUpgrade(address newImpl) external override onlyProxyAdmin {
        if (newImpl == address(0)) revert HookProxy_ZeroAddress();
        if (newImpl.code.length == 0) revert HookProxy_NotAContract();
        uint256 readyAt = block.timestamp + _readUint(_TIMELOCK_DURATION_SLOT);
        _writeAddress(_PENDING_IMPL_SLOT, newImpl);
        _writeUint(_UPGRADE_READY_AT_SLOT, readyAt);
        emit HookProxy_UpgradeProposed(newImpl, readyAt);
    }

    /// @inheritdoc IPrediXHookProxy
    function executeUpgrade() external override onlyProxyAdmin {
        address pending = _readAddress(_PENDING_IMPL_SLOT);
        if (pending == address(0)) revert HookProxy_NoPendingUpgrade();
        uint256 readyAt = _readUint(_UPGRADE_READY_AT_SLOT);
        if (block.timestamp < readyAt) revert HookProxy_UpgradeNotReady();
        if (pending.code.length == 0) revert HookProxy_NotAContract();

        _writeAddress(_IMPL_SLOT, pending);
        _writeAddress(_PENDING_IMPL_SLOT, address(0));
        _writeUint(_UPGRADE_READY_AT_SLOT, 0);
        emit HookProxy_Upgraded(pending);
    }

    /// @inheritdoc IPrediXHookProxy
    function cancelUpgrade() external override onlyProxyAdmin {
        address pending = _readAddress(_PENDING_IMPL_SLOT);
        if (pending == address(0)) revert HookProxy_NoPendingUpgrade();
        _writeAddress(_PENDING_IMPL_SLOT, address(0));
        _writeUint(_UPGRADE_READY_AT_SLOT, 0);
        emit HookProxy_UpgradeCancelled(pending);
    }

    /// @inheritdoc IPrediXHookProxy
    function proposeTimelockDuration(uint256 duration) external override onlyProxyAdmin {
        if (duration < _MIN_TIMELOCK) revert HookProxy_TimelockTooShort();
        if (duration > _MAX_TIMELOCK) revert HookProxy_TimelockTooLong();
        uint256 current = _readUint(_TIMELOCK_DURATION_SLOT);
        // SPEC-05: monotonic increase only. `duration < current` would let a
        // compromised admin shorten the next delay; `duration == current` is
        // a no-op that should be rejected so proposals always represent an
        // explicit intent change (noise reduction + audit-trail clarity).
        if (duration <= current) revert HookProxy_TimelockCannotDecrease();
        // Self-gated: `readyAt` is anchored to the CURRENT timelock, not
        // `_MIN_TIMELOCK`. If admin has raised the delay above the floor,
        // lowering (or even re-raising) follows the higher cadence.
        uint256 readyAt = block.timestamp + current;
        _writeUint(_PENDING_TIMELOCK_DURATION_SLOT, duration);
        _writeUint(_PENDING_TIMELOCK_READY_AT_SLOT, readyAt);
        emit HookProxy_TimelockDurationProposed(duration, readyAt);
    }

    /// @inheritdoc IPrediXHookProxy
    function executeTimelockDuration() external override onlyProxyAdmin {
        uint256 pending = _readUint(_PENDING_TIMELOCK_DURATION_SLOT);
        if (pending == 0) revert HookProxy_NoPendingTimelockChange();
        uint256 readyAt = _readUint(_PENDING_TIMELOCK_READY_AT_SLOT);
        if (block.timestamp < readyAt) revert HookProxy_TimelockDelayNotElapsed();

        uint256 previous = _readUint(_TIMELOCK_DURATION_SLOT);
        _writeUint(_TIMELOCK_DURATION_SLOT, pending);
        _writeUint(_PENDING_TIMELOCK_DURATION_SLOT, 0);
        _writeUint(_PENDING_TIMELOCK_READY_AT_SLOT, 0);
        emit HookProxy_TimelockDurationUpdated(previous, pending);
    }

    /// @inheritdoc IPrediXHookProxy
    function cancelTimelockDuration() external override onlyProxyAdmin {
        uint256 pending = _readUint(_PENDING_TIMELOCK_DURATION_SLOT);
        if (pending == 0) revert HookProxy_NoPendingTimelockChange();
        _writeUint(_PENDING_TIMELOCK_DURATION_SLOT, 0);
        _writeUint(_PENDING_TIMELOCK_READY_AT_SLOT, 0);
        emit HookProxy_TimelockDurationCancelled(pending);
    }

    // ---------------------------------------------------------------------
    // Two-step proxy-admin rotation
    // ---------------------------------------------------------------------

    /// @inheritdoc IPrediXHookProxy
    function changeProxyAdmin(address newAdmin) external override onlyProxyAdmin {
        if (newAdmin == address(0)) revert HookProxy_ZeroAddress();
        _writeAddress(_PENDING_ADMIN_SLOT, newAdmin);
        emit HookProxy_AdminChangeProposed(_readAddress(_ADMIN_SLOT), newAdmin);
    }

    /// @inheritdoc IPrediXHookProxy
    function acceptProxyAdmin() external override {
        address pending = _readAddress(_PENDING_ADMIN_SLOT);
        if (msg.sender != pending) revert HookProxy_OnlyPendingAdmin();
        address previous = _readAddress(_ADMIN_SLOT);
        _writeAddress(_ADMIN_SLOT, pending);
        _writeAddress(_PENDING_ADMIN_SLOT, address(0));
        emit HookProxy_AdminChanged(previous, pending);
    }

    // ---------------------------------------------------------------------
    // Views
    // ---------------------------------------------------------------------

    function implementation() external view override returns (address) {
        return _readAddress(_IMPL_SLOT);
    }

    function pendingImplementation() external view override returns (address) {
        return _readAddress(_PENDING_IMPL_SLOT);
    }

    function upgradeReadyAt() external view override returns (uint256) {
        return _readUint(_UPGRADE_READY_AT_SLOT);
    }

    function timelockDuration() external view override returns (uint256) {
        return _readUint(_TIMELOCK_DURATION_SLOT);
    }

    function pendingTimelockDuration() external view override returns (uint256 duration, uint256 readyAt) {
        duration = _readUint(_PENDING_TIMELOCK_DURATION_SLOT);
        readyAt = _readUint(_PENDING_TIMELOCK_READY_AT_SLOT);
    }

    function proxyAdmin() external view override returns (address) {
        return _readAddress(_ADMIN_SLOT);
    }

    function pendingProxyAdmin() external view override returns (address) {
        return _readAddress(_PENDING_ADMIN_SLOT);
    }

    // ---------------------------------------------------------------------
    // Hook permissions — must mirror PrediXHookV2 EXACTLY so the salt-mined
    // proxy address satisfies `Hooks.validateHookPermissions` in BaseHook's
    // constructor.
    // ---------------------------------------------------------------------

    /// @inheritdoc BaseHook
    function getHookPermissions() public pure override returns (Hooks.Permissions memory) {
        return Hooks.Permissions({
            beforeInitialize: true,
            afterInitialize: false,
            beforeAddLiquidity: true,
            afterAddLiquidity: false,
            beforeRemoveLiquidity: true,
            afterRemoveLiquidity: false,
            beforeSwap: true,
            afterSwap: true,
            beforeDonate: true,
            afterDonate: false,
            beforeSwapReturnDelta: false,
            afterSwapReturnDelta: false,
            afterAddLiquidityReturnDelta: false,
            afterRemoveLiquidityReturnDelta: false
        });
    }

    // ---------------------------------------------------------------------
    // Hook callback delegation
    // ---------------------------------------------------------------------

    /// @dev BaseHook validates `msg.sender == poolManager` on the external entry
    ///      points before invoking each `_beforeX` override. Each override here
    ///      delegate-forwards the raw calldata to the implementation, which re-runs
    ///      its own external entry point (msg.sender preserved via delegatecall).
    ///      Inline assembly terminates the function with `return`/`revert` so no
    ///      Solidity-level return statement is required.

    function _beforeInitialize(address, PoolKey calldata, uint160) internal override returns (bytes4) {
        _delegateToImpl();
    }

    function _beforeAddLiquidity(address, PoolKey calldata, ModifyLiquidityParams calldata, bytes calldata)
        internal
        override
        returns (bytes4)
    {
        _delegateToImpl();
    }

    function _beforeRemoveLiquidity(address, PoolKey calldata, ModifyLiquidityParams calldata, bytes calldata)
        internal
        override
        returns (bytes4)
    {
        _delegateToImpl();
    }

    function _beforeSwap(address, PoolKey calldata, SwapParams calldata, bytes calldata)
        internal
        override
        returns (bytes4, BeforeSwapDelta, uint24)
    {
        _delegateToImpl();
    }

    function _afterSwap(address, PoolKey calldata, SwapParams calldata, BalanceDelta, bytes calldata)
        internal
        override
        returns (bytes4, int128)
    {
        _delegateToImpl();
    }

    function _beforeDonate(address, PoolKey calldata, uint256, uint256, bytes calldata)
        internal
        override
        returns (bytes4)
    {
        _delegateToImpl();
    }

    // ---------------------------------------------------------------------
    // Generic fallback for non-callback functions (initialize, setPaused, ...)
    // ---------------------------------------------------------------------

    /// @dev `external` (NOT payable) — Solidity automatically rejects any ETH sent
    ///      to a non-payable fallback, so the proxy cannot accumulate a stuck
    ///      balance. There is no `receive()` function for the same reason.
    fallback() external {
        _delegateToImpl();
    }

    // ---------------------------------------------------------------------
    // Internal: delegate + raw slot I/O
    // ---------------------------------------------------------------------

    /// @dev Delegate the entire calldata to the current implementation. The inline
    ///      assembly always terminates with `return` or `revert`; control never
    ///      falls back to Solidity, so callers do not need an explicit return
    ///      statement after invoking this helper. NOT marked `memory-safe` because
    ///      the calldatacopy writes past the free-memory pointer without updating
    ///      it (matches OpenZeppelin Proxy v5).
    function _delegateToImpl() private {
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
