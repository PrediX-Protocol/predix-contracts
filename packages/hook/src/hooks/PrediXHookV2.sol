// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {BeforeSwapDelta, BeforeSwapDeltaLibrary} from "@uniswap/v4-core/src/types/BeforeSwapDelta.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {SwapParams, ModifyLiquidityParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {LPFeeLibrary} from "@uniswap/v4-core/src/libraries/LPFeeLibrary.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";

import {IMarketFacet} from "@predix/shared/interfaces/IMarketFacet.sol";

import {IPrediXHook} from "../interfaces/IPrediXHook.sol";
import {FeeTiers} from "../constants/FeeTiers.sol";

/// @title PrediXHookV2
/// @notice Uniswap v4 hook implementation that binds YES/quote pools to PrediX markets,
///         enforces lifecycle-aware liquidity and swap rules, applies a time-decaying
///         dynamic fee, blocks same-block opposite-direction sandwich attempts, and emits
///         referral telemetry without ever escrowing referral credit on-chain.
/// @dev    DEPLOYMENT MODEL — IMPORTANT
/// @dev    This contract is the LOGIC CONTRACT behind `PrediXHookProxyV2`. It does NOT
///         inherit OpenZeppelin's `BaseHook`; it implements `IHooks` directly so its
///         deploy address does not need to satisfy `Hooks.validateHookPermissions`. Only
///         the proxy address (which IS the address PoolManager talks to) must be CREATE2
///         salt-mined to match `getHookPermissions()`. This means future upgrades only
///         need to deploy a fresh impl at any address — no per-upgrade salt mining.
/// @dev    Storage layout may only be appended; never reorder or remove existing slots
///         once the proxy is live, otherwise its delegatecalls will read corrupted state.
contract PrediXHookV2 is IPrediXHook, IHooks {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;
    using LPFeeLibrary for uint24;

    // ---------------------------------------------------------------------
    // Types
    // ---------------------------------------------------------------------

    /// @dev Per-pool binding created by `registerMarketPool`. `marketId == 0` means
    ///      "unregistered" — the diamond never mints market id 0 (see `MarketFacet`,
    ///      which uses `++marketCount`).
    struct PoolBinding {
        uint256 marketId;
        bool yesIsCurrency0;
    }

    // ---------------------------------------------------------------------
    // Immutables (live in code, not storage)
    // ---------------------------------------------------------------------

    /// @notice Uniswap v4 PoolManager. The only address whose calls into the IHooks entry
    ///         points are accepted. Set at impl deployment and re-verified by the proxy
    ///         constructor by virtue of both contracts being constructed with the same value.
    IPoolManager public immutable poolManager;

    /// @notice Canonical V4Quoter address. The ONLY third-party `caller` that
    ///         `commitSwapIdentityFor` may target (beyond self). Frozen at
    ///         impl deployment because the router relies on it for the
    ///         simulate-and-revert quote path, and changing the target would
    ///         require a coordinated router + hook upgrade.
    address public immutable quoter;

    /// @notice Canonical LP fee bits every PrediX pool must carry. Matches the
    ///         Router's `lpFeeFlag` immutable (dynamic-fee sentinel, typically
    ///         `0x800000`). Enforced at `registerMarketPool` so an attacker
    ///         cannot front-run a legitimate market registration with a junk
    ///         fee value and brick the marketId under a non-canonical binding.
    uint24 public immutable canonicalLpFee;

    /// @notice Canonical tick spacing for every PrediX pool. Matches the
    ///         Router's `tickSpacing` immutable. Enforced at
    ///         `registerMarketPool` with `canonicalLpFee` to prevent a
    ///         brick-by-grief attack via front-running with non-canonical params.
    int24 public immutable canonicalTickSpacing;

    // ---------------------------------------------------------------------
    // Storage (proxy delegate context)
    // ---------------------------------------------------------------------

    address private _diamond;
    address private _admin;
    address private _quoteToken;
    bool internal _initialized;
    bool private _paused;

    mapping(address router => bool trusted) private _trustedRouters;
    mapping(PoolId poolId => PoolBinding binding) private _poolBinding;

    /// @dev PERSISTENT (not transient) — the anti-sandwich detector compares against
    ///      previous swaps in the SAME BLOCK across multiple TRANSACTIONS by the same
    ///      identity. Transient storage would clear at the end of every tx and break
    ///      the back-leg detection. Layout: keccak256(marketId, identity) → packed
    ///      `(blockNumber << 2) | directionBits` where directionBits is `0b01` for
    ///      zeroForOne and `0b10` for oneForZero.
    ///
    ///      KNOWN LIMITATION — storage grows unbounded but each entry is per
    ///      `(marketId, identity)`. Storage cost is borne by the swapper writing
    ///      their own record — no griefing vector (cannot bloat others' slots).
    ///      If storage cost becomes a concern at scale, consider a bloom-filter
    ///      replacement (post-launch optimization).
    mapping(bytes32 lastSwapKey => uint256 packed) private _lastSwap;

    /// @dev Pending admin for the 2-step rotation. Appended at the end of storage so
    ///      the proxy's ERC-1967 layout is not disturbed — EVERY new state variable
    ///      MUST come after this line for the same reason.
    address private _pendingAdmin;

    /// @dev Reverse mapping enforcing 1-market-1-pool uniqueness. Each marketId can
    ///      have at most one registered pool; a second `registerMarketPool` for the
    ///      same marketId reverts with `Hook_MarketAlreadyHasPool`. Appended after
    ///      `_pendingAdmin` per the append-only storage rule.
    mapping(uint256 marketId => PoolId) private _marketToPoolId;

    /// @dev Append-only storage for the 2-step trusted-router rotation. Bootstrap
    ///      window: while `_bootstrapped == false`, `setTrustedRouter` takes effect
    ///      immediately so the deploy script can wire the canonical router + quoter
    ///      atomically. After `completeBootstrap()` the legacy setter is locked out
    ///      and trust changes must go through `proposeTrustedRouter` → 48h delay →
    ///      `executeTrustedRouter`.
    bool private _bootstrapped;
    mapping(address router => uint256 proposedAt) private _pendingRouterProposedAt;
    mapping(address router => bool trusted) private _pendingRouterState;

    /// @dev Append-only storage for the 2-step diamond rotation. Single-step
    ///      `setDiamond` was removed so a compromised admin cannot instant-redirect
    ///      market queries to a malicious diamond in one transaction; the 48h delay
    ///      gives off-chain watchers a window to react.
    address private _pendingDiamond;
    uint256 private _pendingDiamondProposedAt;

    /// @dev Append-only storage for the per-market timelocked unregister flow.
    ///      Without this flow, post-rotation `_poolBinding` and `_marketToPoolId`
    ///      would remain locked to the previous diamond's marketIds with no cleanup
    ///      path. Each pending slot is keyed by marketId; non-zero `proposedAt` =
    ///      pending.
    mapping(uint256 marketId => uint256 proposedAt) private _pendingUnregisterProposedAt;

    /// @dev Append-only storage for the 48h-timelocked admin rotation.
    ///      `_pendingAdmin` already exists at slot ~9; we append
    ///      `_pendingAdminProposedAt` so legitimate admin has a 48h recovery
    ///      window via `cancelAdminRotation` if a compromised admin nominates
    ///      an attacker key.
    uint256 private _pendingAdminProposedAt;

    /// @notice Minimum wait between `proposeTrustedRouter` and
    ///         `executeTrustedRouter`. Matches the diamond/hook-proxy 48h floor
    ///         so governance delays are uniform.
    uint256 public constant TRUSTED_ROUTER_DELAY = 48 hours;

    /// @notice Minimum wait between `proposeDiamond` and
    ///         `executeDiamondRotation`. Matches the trusted-router / hook-proxy
    ///         48h floor so governance delays are uniform.
    uint256 public constant DIAMOND_ROTATION_DELAY = 48 hours;

    /// @notice Minimum wait between `proposeUnregisterMarketPool` and
    ///         `executeUnregisterMarketPool`. Matches the diamond rotation
    ///         cadence so binding mutations carry the same governance notice
    ///         as the rotation that motivated them.
    uint256 public constant MARKET_UNREGISTER_DELAY = 48 hours;

    /// @notice Minimum wait between `setAdmin` and `acceptAdmin`. Mirrors
    ///         the diamond / trusted-router / unregister cadence so a
    ///         compromised admin cannot instant-rotate to a fresh attacker
    ///         key — legitimate admin has 48h to call `cancelAdminRotation`.
    uint256 public constant ADMIN_ROTATION_DELAY = 48 hours;

    // ---------------------------------------------------------------------
    // Transient storage namespaces (EIP-1153)
    // ---------------------------------------------------------------------

    /// @dev Base namespace for the per-tx identity commitment table. Per-(router, poolId)
    ///      slots are derived as `keccak256(_COMMIT_NAMESPACE, router, poolId)` and
    ///      accessed via `tload`/`tstore`. The TRANSIENT lifetime is intentional: the
    ///      commitment must be paired with an immediately-following `poolManager.swap` in
    ///      the SAME transaction, otherwise it disappears.
    bytes32 private constant _COMMIT_NAMESPACE = bytes32(uint256(keccak256("predix.hook.committed_identity.v1")) - 1);

    // ---------------------------------------------------------------------
    // Anti-sandwich packing
    // ---------------------------------------------------------------------

    uint256 private constant _DIR_SHIFT = 2;
    uint256 private constant _DIR_MASK = 0x3;
    uint256 private constant _DIR_ZERO_FOR_ONE = 0x1;
    uint256 private constant _DIR_ONE_FOR_ZERO = 0x2;
    uint256 private constant _DIR_BOTH = 0x3;

    // ---------------------------------------------------------------------
    // Init price window
    // ---------------------------------------------------------------------

    /// @dev Binary markets must initialise near the 50¢ midpoint. Tolerance is ±5% of
    ///      `PRICE_UNIT / 2`, i.e. the implied YES price must land in `[475_000, 525_000]`.
    ///      Anything tighter rejects legitimate rounding on the `_sqrtPriceToYesPrice`
    ///      conversion; anything looser defeats the front-run mitigation.
    uint256 private constant _INIT_PRICE_MIN = 475_000;
    uint256 private constant _INIT_PRICE_MAX = 525_000;

    // ---------------------------------------------------------------------
    // Modifiers
    // ---------------------------------------------------------------------

    modifier onlyAdmin() {
        if (msg.sender != _admin) revert Hook_OnlyAdmin();
        _;
    }

    modifier whenNotPaused() {
        if (_paused) revert Hook_Paused();
        _;
    }

    /// @dev Replaces `BaseHook.onlyPoolManager`. We compare against the contract's own
    ///      `poolManager` immutable, which under delegatecall resolves from the IMPL's
    ///      runtime bytecode — by construction equal to the proxy's immutable.
    modifier onlyPoolManager() {
        if (msg.sender != address(poolManager)) revert Hook_NotPoolManager();
        _;
    }

    // ---------------------------------------------------------------------
    // Constructor
    // ---------------------------------------------------------------------

    constructor(IPoolManager poolManager_, address quoter_, uint24 canonicalLpFee_, int24 canonicalTickSpacing_) {
        if (quoter_ == address(0)) revert Hook_ZeroAddress();
        if (canonicalLpFee_ == 0) revert Hook_InvalidCanonicalFee();
        if (canonicalTickSpacing_ == 0) revert Hook_InvalidCanonicalTickSpacing();
        poolManager = poolManager_;
        quoter = quoter_;
        canonicalLpFee = canonicalLpFee_;
        canonicalTickSpacing = canonicalTickSpacing_;
        // Defense-in-depth: prevent direct initialization of the bare implementation
        // contract. Only the proxy's delegatecall path (which writes to proxy storage,
        // not impl storage) should run initialize(). Without this guard, an attacker
        // could call initialize() on the implementation and become admin of the impl.
        _initialized = true;
    }

    // ---------------------------------------------------------------------
    // Initialize (atomically called by proxy constructor — see C2)
    // ---------------------------------------------------------------------

    /// @inheritdoc IPrediXHook
    function initialize(address diamond_, address admin_, address quoteToken_) external override {
        if (_initialized) revert Hook_AlreadyInitialized();
        if (diamond_ == address(0) || admin_ == address(0) || quoteToken_ == address(0)) {
            revert Hook_ZeroAddress();
        }
        _diamond = diamond_;
        _admin = admin_;
        _quoteToken = quoteToken_;
        _initialized = true;
        emit Hook_Initialized(diamond_, admin_, quoteToken_);
    }

    // ---------------------------------------------------------------------
    // Admin
    // ---------------------------------------------------------------------

    /// @inheritdoc IPrediXHook
    function proposeDiamond(address diamond_) external override onlyAdmin {
        // Reject re-propose-while-pending. Admin must explicitly cancel before
        // re-proposing, so the pending timer cannot be silently extended.
        if (_pendingDiamondProposedAt != 0) revert Hook_AlreadyPendingDiamondChange();
        if (diamond_ == address(0)) revert Hook_ZeroAddress();
        // Rotation target must be a contract. Mirrors the existing
        // `proposeUpgrade` code-length check on the proxy side.
        if (diamond_.code.length == 0) revert Hook_DiamondNotAContract();
        _pendingDiamond = diamond_;
        _pendingDiamondProposedAt = block.timestamp;
        emit Hook_DiamondRotationProposed(diamond_, block.timestamp + DIAMOND_ROTATION_DELAY);
    }

    /// @inheritdoc IPrediXHook
    function executeDiamondRotation() external override onlyAdmin {
        address pending = _pendingDiamond;
        if (pending == address(0)) revert Hook_NoPendingDiamondChange();
        if (block.timestamp < _pendingDiamondProposedAt + DIAMOND_ROTATION_DELAY) {
            revert Hook_DiamondDelayNotElapsed();
        }
        // Re-validate code length at execute. Defends against a target that was
        // a contract at propose-time but lost code before execute (selfdestruct
        // deprecated in Cancun, but principle stands).
        if (pending.code.length == 0) revert Hook_DiamondNotAContract();
        address previous = _diamond;
        _diamond = pending;
        delete _pendingDiamond;
        delete _pendingDiamondProposedAt;
        emit Hook_DiamondUpdated(previous, pending);
    }

    /// @inheritdoc IPrediXHook
    function cancelDiamondRotation() external override onlyAdmin {
        address cancelled = _pendingDiamond;
        if (cancelled == address(0)) revert Hook_NoPendingDiamondChange();
        delete _pendingDiamond;
        delete _pendingDiamondProposedAt;
        emit Hook_DiamondRotationCancelled(cancelled);
    }

    /// @inheritdoc IPrediXHook
    function pendingDiamond() external view override returns (address pending, uint256 readyAt) {
        pending = _pendingDiamond;
        readyAt = pending == address(0) ? 0 : _pendingDiamondProposedAt + DIAMOND_ROTATION_DELAY;
    }

    /// @inheritdoc IPrediXHook
    function proposeUnregisterMarketPool(uint256 marketId) external override onlyAdmin {
        // Reject re-propose-while-pending. Admin must explicitly cancel first
        // to prevent silent timer extension.
        if (_pendingUnregisterProposedAt[marketId] != 0) revert Hook_AlreadyPendingUnregister();
        if (PoolId.unwrap(_marketToPoolId[marketId]) == bytes32(0)) revert Hook_MarketNotFound();
        _pendingUnregisterProposedAt[marketId] = block.timestamp;
        emit Hook_MarketUnregisterProposed(marketId, block.timestamp + MARKET_UNREGISTER_DELAY);
    }

    /// @inheritdoc IPrediXHook
    function executeUnregisterMarketPool(uint256 marketId) external override onlyAdmin {
        uint256 proposedAt = _pendingUnregisterProposedAt[marketId];
        if (proposedAt == 0) revert Hook_NoPendingUnregister();
        if (block.timestamp < proposedAt + MARKET_UNREGISTER_DELAY) {
            revert Hook_UnregisterDelayNotElapsed();
        }
        PoolId poolId = _marketToPoolId[marketId];
        // Defensive: between propose and execute, the binding could in theory
        // have been cleared by a concurrent flow. Treat that as a no-op error
        // so the pending slot is also cleared.
        if (PoolId.unwrap(poolId) == bytes32(0)) revert Hook_MarketNotFound();
        delete _poolBinding[poolId];
        // PoolId is a user-defined value type — `delete` does not apply;
        // assign the zero-wrapped sentinel explicitly.
        _marketToPoolId[marketId] = PoolId.wrap(bytes32(0));
        delete _pendingUnregisterProposedAt[marketId];
        emit Hook_MarketUnregistered(marketId, poolId);
    }

    /// @inheritdoc IPrediXHook
    function cancelUnregisterMarketPool(uint256 marketId) external override onlyAdmin {
        if (_pendingUnregisterProposedAt[marketId] == 0) revert Hook_NoPendingUnregister();
        delete _pendingUnregisterProposedAt[marketId];
        emit Hook_MarketUnregisterCancelled(marketId);
    }

    /// @inheritdoc IPrediXHook
    function pendingUnregisterMarketPool(uint256 marketId) external view override returns (uint256 readyAt) {
        uint256 proposedAt = _pendingUnregisterProposedAt[marketId];
        readyAt = proposedAt == 0 ? 0 : proposedAt + MARKET_UNREGISTER_DELAY;
    }

    /// @inheritdoc IPrediXHook
    function setAdmin(address admin_) external override onlyAdmin {
        // Reject re-propose-while-pending so a compromised admin cannot
        // silently overwrite a legitimate-admin recovery nomination.
        if (_pendingAdminProposedAt != 0) revert Hook_AlreadyPendingAdmin();
        if (admin_ == address(0)) revert Hook_ZeroAddress();
        _pendingAdmin = admin_;
        _pendingAdminProposedAt = block.timestamp;
        emit Hook_AdminChangeProposed(_admin, admin_);
    }

    /// @inheritdoc IPrediXHook
    function acceptAdmin() external override {
        address pending = _pendingAdmin;
        if (msg.sender != pending) revert Hook_OnlyPendingAdmin();
        // Enforce 48h delay so legitimate admin has a recovery window via
        // `cancelAdminRotation`.
        if (block.timestamp < _pendingAdminProposedAt + ADMIN_ROTATION_DELAY) {
            revert Hook_AdminDelayNotElapsed();
        }
        address previous = _admin;
        _admin = pending;
        _pendingAdmin = address(0);
        delete _pendingAdminProposedAt;
        emit Hook_AdminUpdated(previous, pending);
    }

    /// @inheritdoc IPrediXHook
    function cancelAdminRotation() external override onlyAdmin {
        if (_pendingAdminProposedAt == 0) revert Hook_NoPendingAdminChange();
        address cancelled = _pendingAdmin;
        delete _pendingAdmin;
        delete _pendingAdminProposedAt;
        emit Hook_AdminChangeCancelled(cancelled);
    }

    /// @inheritdoc IPrediXHook
    function setPaused(bool paused_) external override onlyAdmin {
        _paused = paused_;
        emit Hook_PauseStatusChanged(paused_);
    }

    /// @inheritdoc IPrediXHook
    /// @dev Immediate-apply setter is available only during the bootstrap
    ///      window (`!_bootstrapped`). After `completeBootstrap()` all trust
    ///      changes must route through the propose/execute flow.
    function setTrustedRouter(address router, bool trusted) external override onlyAdmin {
        if (_bootstrapped) revert Hook_BootstrapComplete();
        if (router == address(0)) revert Hook_ZeroAddress();
        _trustedRouters[router] = trusted;
        emit Hook_TrustedRouterUpdated(router, trusted);
    }

    /// @inheritdoc IPrediXHook
    function completeBootstrap() external override onlyAdmin {
        if (_bootstrapped) revert Hook_BootstrapComplete();
        _bootstrapped = true;
        emit Hook_BootstrapCompleted();
    }

    /// @inheritdoc IPrediXHook
    function proposeTrustedRouter(address router, bool trusted) external override onlyAdmin {
        if (!_bootstrapped) revert Hook_BootstrapNotComplete();
        if (router == address(0)) revert Hook_ZeroAddress();
        if (_pendingRouterProposedAt[router] != 0) revert Hook_AlreadyPendingRouter();
        _pendingRouterProposedAt[router] = block.timestamp;
        _pendingRouterState[router] = trusted;
        emit Hook_TrustedRouterProposed(router, trusted, block.timestamp + TRUSTED_ROUTER_DELAY);
    }

    /// @inheritdoc IPrediXHook
    function executeTrustedRouter(address router) external override {
        uint256 proposedAt = _pendingRouterProposedAt[router];
        if (proposedAt == 0) revert Hook_NoPendingRouterChange();
        if (block.timestamp < proposedAt + TRUSTED_ROUTER_DELAY) {
            revert Hook_TrustedRouterDelayNotElapsed();
        }
        bool trusted = _pendingRouterState[router];
        _trustedRouters[router] = trusted;
        delete _pendingRouterProposedAt[router];
        delete _pendingRouterState[router];
        emit Hook_TrustedRouterUpdated(router, trusted);
    }

    /// @inheritdoc IPrediXHook
    function cancelTrustedRouter(address router) external override onlyAdmin {
        if (_pendingRouterProposedAt[router] == 0) revert Hook_NoPendingRouterChange();
        delete _pendingRouterProposedAt[router];
        delete _pendingRouterState[router];
        emit Hook_TrustedRouterCancelled(router);
    }

    /// @inheritdoc IPrediXHook
    function registerMarketPool(uint256 marketId, PoolKey calldata key) external override {
        if (!_initialized) revert Hook_NotInitialized();
        PoolId poolId = key.toId();
        PoolBinding storage binding = _poolBinding[poolId];
        if (binding.marketId != 0) revert Hook_PoolAlreadyRegistered();
        if (PoolId.unwrap(_marketToPoolId[marketId]) != bytes32(0)) revert Hook_MarketAlreadyHasPool();

        // Canonical PoolKey enforcement. Without this block, an attacker could
        // front-run the legitimate registration by calling with a junk fee /
        // tickSpacing / hook address; because `_marketToPoolId[marketId]` then
        // points at the junk binding, the real deploy cannot overwrite it and
        // the market is bricked. Enforce that every registered pool carries the
        // canonical fee, canonical tick spacing, and this hook address.
        if (key.fee != canonicalLpFee) revert Hook_NonCanonicalFee();
        if (key.tickSpacing != canonicalTickSpacing) revert Hook_NonCanonicalTickSpacing();
        if (address(key.hooks) != address(this)) revert Hook_WrongHookAddress();

        // Permissionless registration: anyone may call. The security barrier is the
        // validation block below, NOT a caller-address check. The hook requires that
        // `marketId` exists in the diamond (yesToken != 0) and the supplied `key`
        // references the diamond-deployed yesToken plus the configured USDC quote.
        // A caller cannot plant a junk binding because the diamond is the only source
        // of yesTokens and the currency check rejects every other ERC20.
        IMarketFacet.MarketView memory mkt = IMarketFacet(_diamond).getMarket(marketId);
        if (mkt.yesToken == address(0)) revert Hook_MarketNotFound();

        address token0 = Currency.unwrap(key.currency0);
        address token1 = Currency.unwrap(key.currency1);
        address quote = _quoteToken;
        bool yesIsCurrency0;
        if (token0 == mkt.yesToken && token1 == quote) {
            yesIsCurrency0 = true;
        } else if (token1 == mkt.yesToken && token0 == quote) {
            yesIsCurrency0 = false;
        } else {
            revert Hook_InvalidPoolCurrencies();
        }

        binding.marketId = marketId;
        binding.yesIsCurrency0 = yesIsCurrency0;
        _marketToPoolId[marketId] = poolId;

        emit Hook_PoolRegistered(marketId, poolId, mkt.yesToken, quote, yesIsCurrency0);
    }

    // ---------------------------------------------------------------------
    // Trusted-router transient identity commit (audit C-03)
    // ---------------------------------------------------------------------

    /// @inheritdoc IPrediXHook
    function commitSwapIdentity(address user, PoolId poolId) external override {
        if (!_trustedRouters[msg.sender]) revert Hook_OnlyTrustedRouter();
        if (user == address(0)) revert Hook_ZeroAddress();
        bytes32 slot = _commitSlot(msg.sender, poolId);
        assembly ("memory-safe") {
            tstore(slot, user)
        }
    }

    /// @inheritdoc IPrediXHook
    /// @dev Allows a trusted router to pre-commit identity under another trusted
    ///      caller's slot. Primary use case: the router calls this before
    ///      `V4Quoter.quoteExactInputSingle`, writing `user` under
    ///      `_commitSlot(quoter, poolId)` so the quoter's simulate-and-revert
    ///      `beforeSwap(sender=quoter, ...)` finds the identity. Both the
    ///      msg.sender (router) AND `caller` (quoter) must be trusted — this
    ///      prevents an attacker from planting commits under arbitrary slots.
    function commitSwapIdentityFor(address caller, address user, PoolId poolId) external override {
        if (!_trustedRouters[msg.sender]) revert Hook_OnlyTrustedRouter();
        if (!_trustedRouters[caller]) revert Hook_OnlyTrustedRouter();
        // Only two legitimate cross-slot writers — self (msg.sender commits its
        // own slot) and the canonical quoter (router pre-commits under quoter's
        // slot for the simulate-and-revert path). Any other caller means one
        // trusted router is writing under another trusted router's slot — an
        // identity-poisoning vector if the trusted set ever expands beyond
        // {router, quoter}.
        if (caller != msg.sender && caller != quoter) revert Hook_InvalidCommitTarget();
        if (user == address(0)) revert Hook_ZeroAddress();
        bytes32 slot = _commitSlot(caller, poolId);
        assembly ("memory-safe") {
            tstore(slot, user)
        }
    }

    // ---------------------------------------------------------------------
    // Views
    // ---------------------------------------------------------------------

    function diamond() external view override returns (address) {
        return _diamond;
    }

    function admin() external view override returns (address) {
        return _admin;
    }

    function quoteToken() external view override returns (address) {
        return _quoteToken;
    }

    function paused() external view override returns (bool) {
        return _paused;
    }

    function isTrustedRouter(address router) external view override returns (bool) {
        return _trustedRouters[router];
    }

    function poolMarketId(PoolId poolId) external view override returns (uint256) {
        return _poolBinding[poolId].marketId;
    }

    function committedIdentity(address router, PoolId poolId) external view override returns (address user) {
        bytes32 slot = _commitSlot(router, poolId);
        assembly ("memory-safe") {
            user := tload(slot)
        }
    }

    function bootstrapped() external view override returns (bool) {
        return _bootstrapped;
    }

    function pendingTrustedRouter(address router) external view override returns (bool trusted, uint256 readyAt) {
        uint256 proposedAt = _pendingRouterProposedAt[router];
        if (proposedAt == 0) return (false, 0);
        return (_pendingRouterState[router], proposedAt + TRUSTED_ROUTER_DELAY);
    }

    function pendingAdminRotation() external view override returns (address pending, uint256 readyAt) {
        pending = _pendingAdmin;
        readyAt = _pendingAdminProposedAt == 0 ? 0 : _pendingAdminProposedAt + ADMIN_ROTATION_DELAY;
    }

    // ---------------------------------------------------------------------
    // Hook permissions
    // ---------------------------------------------------------------------

    /// @notice Mirror of `PrediXHookProxyV2.getHookPermissions()`. The proxy's address bits
    ///         are what PoolManager validates; this function exists for off-chain tooling
    ///         (subgraph, test fixtures) and as a sanity contract for upgraders.
    function getHookPermissions() external pure returns (Hooks.Permissions memory) {
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
    // IHooks external entry points — ENABLED (6)
    // ---------------------------------------------------------------------

    /// @inheritdoc IHooks
    function beforeInitialize(address sender, PoolKey calldata key, uint160 sqrtPriceX96)
        external
        view
        override
        onlyPoolManager
        returns (bytes4)
    {
        return _beforeInitialize(sender, key, sqrtPriceX96);
    }

    /// @inheritdoc IHooks
    function beforeAddLiquidity(
        address sender,
        PoolKey calldata key,
        ModifyLiquidityParams calldata params,
        bytes calldata hookData
    ) external view override onlyPoolManager whenNotPaused returns (bytes4) {
        return _beforeAddLiquidity(sender, key, params, hookData);
    }

    /// @inheritdoc IHooks
    function beforeRemoveLiquidity(
        address sender,
        PoolKey calldata key,
        ModifyLiquidityParams calldata params,
        bytes calldata hookData
    ) external view override onlyPoolManager returns (bytes4) {
        return _beforeRemoveLiquidity(sender, key, params, hookData);
    }

    /// @inheritdoc IHooks
    function beforeDonate(
        address sender,
        PoolKey calldata key,
        uint256 amount0,
        uint256 amount1,
        bytes calldata hookData
    ) external view override onlyPoolManager whenNotPaused returns (bytes4) {
        return _beforeDonate(sender, key, amount0, amount1, hookData);
    }

    /// @inheritdoc IHooks
    function beforeSwap(address sender, PoolKey calldata key, SwapParams calldata params, bytes calldata hookData)
        external
        override
        onlyPoolManager
        whenNotPaused
        returns (bytes4, BeforeSwapDelta, uint24)
    {
        return _beforeSwap(sender, key, params, hookData);
    }

    /// @inheritdoc IHooks
    function afterSwap(
        address sender,
        PoolKey calldata key,
        SwapParams calldata params,
        BalanceDelta delta,
        bytes calldata hookData
    ) external override onlyPoolManager returns (bytes4, int128) {
        return _afterSwap(sender, key, params, delta, hookData);
    }

    // ---------------------------------------------------------------------
    // Internal hook logic
    // ---------------------------------------------------------------------
    // The internals below contain the entire business logic, and the externals
    // above are thin `onlyPoolManager` + (optional) `whenNotPaused` wrappers.
    // Tests inheriting this contract can call the internals directly to exercise
    // logic without faking the PoolManager or the pause state.

    /// @dev C-02: pools must be registered by the diamond before PoolManager.initialize.
    ///      Pools must also be created with the v4 dynamic-fee flag, otherwise the
    ///      override fee returned from `_beforeSwap` would be silently ignored.
    ///      The implied YES price must land inside `[_INIT_PRICE_MIN, _INIT_PRICE_MAX]`, the
    ///      ±5% window around `PRICE_UNIT / 2`. This closes the permissionless-register
    ///      front-run that would otherwise let a hostile caller lock the pool at an unfair
    ///      starting price and arbitrage the first legitimate LPs.
    function _beforeInitialize(address, PoolKey calldata key, uint160 sqrtPriceX96) internal view returns (bytes4) {
        if (!key.fee.isDynamicFee()) revert Hook_PoolFeeNotDynamic();
        PoolBinding storage binding = _poolBinding[key.toId()];
        if (binding.marketId == 0) revert Hook_PoolNotRegistered();
        // Stale-binding guard at init time. Without this, a pool registered
        // against the old diamond and initialized after a diamond rotation
        // would init successfully but be permanently unusable (every subsequent
        // swap/add/donate reverts Hook_StaleBinding). One extra diamond view-call
        // per init; init is one-shot per pool.
        IMarketFacet.MarketView memory mkt = IMarketFacet(_diamond).getMarket(binding.marketId);
        _assertYesTokenMatchesBinding(key, binding.yesIsCurrency0, mkt.yesToken);
        uint256 yesPrice = _sqrtPriceToYesPrice(sqrtPriceX96, binding.yesIsCurrency0);
        if (yesPrice < _INIT_PRICE_MIN || yesPrice > _INIT_PRICE_MAX) revert Hook_InitPriceOutOfWindow();
        return IHooks.beforeInitialize.selector;
    }

    /// @dev C-04: block JIT into resolved/expired markets. Pause is enforced in the
    ///      external wrapper, not here.
    function _beforeAddLiquidity(address, PoolKey calldata key, ModifyLiquidityParams calldata, bytes calldata)
        internal
        view
        returns (bytes4)
    {
        PoolBinding storage binding = _poolBinding[key.toId()];
        uint256 marketId = binding.marketId;
        if (marketId == 0) revert Hook_PoolNotRegistered();
        IMarketFacet.MarketView memory mkt = IMarketFacet(_diamond).getMarket(marketId);
        // Defence-in-depth against stale binding (e.g. post diamond rotation
        // where the new diamond's marketId resolves to a different yesToken).
        // Reverts loudly instead of silently routing liquidity under a
        // wrong-token assumption.
        _assertYesTokenMatchesBinding(key, binding.yesIsCurrency0, mkt.yesToken);
        if (mkt.isResolved) revert Hook_MarketResolved();
        if (mkt.refundModeActive) revert Hook_MarketInRefundMode();
        if (block.timestamp >= mkt.endTime) revert Hook_MarketExpired();
        return IHooks.beforeAddLiquidity.selector;
    }

    /// @dev LPs must always be able to exit — no pause check, no resolved/expired check.
    function _beforeRemoveLiquidity(address, PoolKey calldata key, ModifyLiquidityParams calldata, bytes calldata)
        internal
        view
        returns (bytes4)
    {
        if (_poolBinding[key.toId()].marketId == 0) revert Hook_PoolNotRegistered();
        return IHooks.beforeRemoveLiquidity.selector;
    }

    function _beforeDonate(address, PoolKey calldata key, uint256, uint256, bytes calldata)
        internal
        view
        returns (bytes4)
    {
        PoolBinding storage binding = _poolBinding[key.toId()];
        uint256 marketId = binding.marketId;
        if (marketId == 0) revert Hook_PoolNotRegistered();
        IMarketFacet.MarketView memory mkt = IMarketFacet(_diamond).getMarket(marketId);
        // Stale-binding defence. See `_beforeAddLiquidity` for rationale.
        _assertYesTokenMatchesBinding(key, binding.yesIsCurrency0, mkt.yesToken);
        if (mkt.isResolved) revert Hook_MarketResolved();
        if (mkt.refundModeActive) revert Hook_MarketInRefundMode();
        if (block.timestamp >= mkt.endTime) revert Hook_MarketExpired();
        return IHooks.beforeDonate.selector;
    }

    function _beforeSwap(address sender, PoolKey calldata key, SwapParams calldata params, bytes calldata)
        internal
        returns (bytes4, BeforeSwapDelta, uint24)
    {
        PoolBinding storage binding = _poolBinding[key.toId()];
        uint256 marketId = binding.marketId;
        if (marketId == 0) revert Hook_PoolNotRegistered();

        IMarketFacet.MarketView memory mkt = IMarketFacet(_diamond).getMarket(marketId);
        // Stale-binding defence. See `_beforeAddLiquidity`.
        _assertYesTokenMatchesBinding(key, binding.yesIsCurrency0, mkt.yesToken);
        if (mkt.isResolved) revert Hook_MarketResolved();
        if (mkt.refundModeActive) revert Hook_MarketInRefundMode();
        if (block.timestamp >= mkt.endTime) revert Hook_MarketExpired();

        address identity = _resolveIdentity(sender, key.toId());
        _checkAndRecordSandwich(marketId, identity, params.zeroForOne);

        uint24 fee = _calculateDynamicFee(mkt.endTime) | LPFeeLibrary.OVERRIDE_FEE_FLAG;
        return (IHooks.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, fee);
    }

    function _afterSwap(
        address sender,
        PoolKey calldata key,
        SwapParams calldata params,
        BalanceDelta delta,
        bytes calldata hookData
    ) internal returns (bytes4, int128) {
        PoolId poolId = key.toId();
        PoolBinding storage binding = _poolBinding[poolId];
        uint256 marketId = binding.marketId;
        bool yesIsCurrency0 = binding.yesIsCurrency0;

        (uint160 sqrtPriceX96,,,) = poolManager.getSlot0(poolId);
        _enforceSlippage(hookData, sqrtPriceX96, params.zeroForOne);

        (uint256 usdcVolume, uint256 yesVolume) = _extractVolumes(delta, yesIsCurrency0);
        address trader = _resolveIdentity(sender, poolId);
        bool isBuy = yesIsCurrency0 ? !params.zeroForOne : params.zeroForOne;
        uint256 yesPrice = _sqrtPriceToYesPrice(sqrtPriceX96, yesIsCurrency0);

        emit Hook_MarketTraded(marketId, trader, isBuy, usdcVolume, yesVolume, yesPrice);

        if (hookData.length >= FeeTiers.HOOKDATA_REFERRER_END) {
            address referrer = address(bytes20(hookData[0:FeeTiers.HOOKDATA_REFERRER_END]));
            if (referrer != address(0) && referrer != trader) {
                emit Hook_ReferralRecorded(marketId, referrer, trader, usdcVolume);
            }
        }

        return (IHooks.afterSwap.selector, int128(0));
    }

    // ---------------------------------------------------------------------
    // IHooks external entry points — DISABLED (4)
    // ---------------------------------------------------------------------
    // PoolManager will not call these because the proxy's address bits do not
    // declare them. They exist solely to satisfy the IHooks interface; any
    // direct invocation reverts with `Hook_NotImplemented`.

    /// @inheritdoc IHooks
    function afterInitialize(address, PoolKey calldata, uint160, int24) external pure override returns (bytes4) {
        revert Hook_NotImplemented();
    }

    /// @inheritdoc IHooks
    function afterAddLiquidity(
        address,
        PoolKey calldata,
        ModifyLiquidityParams calldata,
        BalanceDelta,
        BalanceDelta,
        bytes calldata
    ) external pure override returns (bytes4, BalanceDelta) {
        revert Hook_NotImplemented();
    }

    /// @inheritdoc IHooks
    function afterRemoveLiquidity(
        address,
        PoolKey calldata,
        ModifyLiquidityParams calldata,
        BalanceDelta,
        BalanceDelta,
        bytes calldata
    ) external pure override returns (bytes4, BalanceDelta) {
        revert Hook_NotImplemented();
    }

    /// @inheritdoc IHooks
    function afterDonate(address, PoolKey calldata, uint256, uint256, bytes calldata)
        external
        pure
        override
        returns (bytes4)
    {
        revert Hook_NotImplemented();
    }

    // ---------------------------------------------------------------------
    // Internal helpers
    // ---------------------------------------------------------------------

    /// @dev Defence-in-depth against stale binding. After `executeDiamondRotation`
    ///      (or any state-corrupting upgrade), the diamond's marketId map can
    ///      resolve to a different yesToken than the binding recorded at
    ///      `registerMarketPool`. Reading the wrong yesToken would let users swap
    ///      into a token that no longer represents the market. This helper turns
    ///      silent corruption into a loud `Hook_StaleBinding` revert in every
    ///      lifecycle callback.
    function _assertYesTokenMatchesBinding(PoolKey calldata key, bool yesIsCurrency0, address marketYesToken)
        private
        pure
    {
        address keyYes = yesIsCurrency0 ? Currency.unwrap(key.currency0) : Currency.unwrap(key.currency1);
        if (keyYes != marketYesToken) revert Hook_StaleBinding();
    }

    /// @dev Per-(router, poolId) transient slot. Block number is NOT included because
    ///      transient storage already auto-resets at end of tx, making the (block, tx)
    ///      composite identifier redundant.
    function _commitSlot(address router, PoolId poolId) private pure returns (bytes32) {
        return keccak256(abi.encode(_COMMIT_NAMESPACE, router, poolId));
    }

    /// @dev Every swap MUST carry a router-committed identity. Untrusted callers are
    ///      rejected outright; trusted callers without a same-tx commit are also
    ///      rejected. The silent fallback to `sender` was removed because it made the
    ///      identity invariant advisory — attackers with disposable contracts could
    ///      bypass anti-sandwich by swapping directly through PoolManager.
    function _resolveIdentity(address sender, PoolId poolId) private view returns (address) {
        if (!_trustedRouters[sender]) revert Hook_UntrustedCaller(sender);
        bytes32 slot = _commitSlot(sender, poolId);
        address committed;
        assembly ("memory-safe") {
            committed := tload(slot)
        }
        if (committed == address(0)) revert Hook_MissingRouterCommit();
        return committed;
    }

    /// @dev Reverts if `identity` already swapped in the OPPOSITE direction this block on
    ///      the same market. Same-direction repeats inside a single block are explicitly
    ///      allowed (a trader splitting a large order should not be punished).
    /// @dev MULTI-EOA LIMITATION: a sandwich attacker controlling two distinct
    ///      addresses can split the front-leg and back-leg across both, escaping this check
    ///      because `identity` will differ between calls. This is a known and accepted
    ///      limitation; the protocol-level mitigation is the Unichain sequencer's anti-MEV
    ///      ordering, not contract-side detection. Do NOT attempt a tighter check here
    ///      without an explicit spec change — `tx.origin` would break smart-wallet swaps,
    ///      and signed router commitments only move the trust boundary instead of solving it.
    function _checkAndRecordSandwich(uint256 marketId, address identity, bool zeroForOne) private {
        bytes32 slot = keccak256(abi.encode(marketId, identity));
        uint256 packed = _lastSwap[slot];
        uint256 lastBlock = packed >> _DIR_SHIFT;
        uint256 currentDir = zeroForOne ? _DIR_ZERO_FOR_ONE : _DIR_ONE_FOR_ZERO;
        uint256 newPacked;
        if (lastBlock == block.number) {
            uint256 lastDirs = packed & _DIR_MASK;
            uint256 combined = lastDirs | currentDir;
            if (combined == _DIR_BOTH) revert Hook_SandwichDetected();
            newPacked = (block.number << _DIR_SHIFT) | combined;
        } else {
            newPacked = (block.number << _DIR_SHIFT) | currentDir;
        }
        _lastSwap[slot] = newPacked;
    }

    /// @dev Fee widens as expiry approaches. The post-expiry guard is defensive: callers
    ///      from `_beforeSwap` will have already reverted with `Hook_MarketExpired`, but
    ///      keeping the guard ensures the subtraction below cannot underflow if any other
    ///      caller is added later.
    function _calculateDynamicFee(uint256 endTime) private view returns (uint24) {
        if (block.timestamp >= endTime) return FeeTiers.FEE_VERY_HIGH;
        uint256 timeToExpiry = endTime - block.timestamp;
        if (timeToExpiry > FeeTiers.LONG_WINDOW) return FeeTiers.FEE_NORMAL;
        if (timeToExpiry > FeeTiers.MID_WINDOW) return FeeTiers.FEE_MEDIUM;
        if (timeToExpiry > FeeTiers.SHORT_WINDOW) return FeeTiers.FEE_HIGH;
        return FeeTiers.FEE_VERY_HIGH;
    }

    /// @dev Cast `int128` legs to `int256` BEFORE negating so the `int128.min` edge case
    ///      cannot overflow inside the unary minus.
    function _extractVolumes(BalanceDelta delta, bool yesIsCurrency0)
        private
        pure
        returns (uint256 usdcVolume, uint256 yesVolume)
    {
        int256 amt0 = int256(delta.amount0());
        int256 amt1 = int256(delta.amount1());
        uint256 abs0 = amt0 >= 0 ? uint256(amt0) : uint256(-amt0);
        uint256 abs1 = amt1 >= 0 ? uint256(amt1) : uint256(-amt1);
        if (yesIsCurrency0) {
            yesVolume = abs0;
            usdcVolume = abs1;
        } else {
            yesVolume = abs1;
            usdcVolume = abs0;
        }
    }

    /// @dev YES price in 1e6 pip units. Computed from the post-swap sqrtPriceX96, inverted
    ///      if YES is currency1, and clamped to [0, 1e6]. Uses `FullMath.mulDiv` twice to
    ///      keep the 512-bit intermediate products from overflowing.
    function _sqrtPriceToYesPrice(uint160 sqrtPriceX96, bool yesIsCurrency0) private pure returns (uint256) {
        if (sqrtPriceX96 == 0) return 0;
        uint256 priceX96 = FullMath.mulDiv(uint256(sqrtPriceX96), uint256(sqrtPriceX96), 1 << 96);
        uint256 priceToken1PerToken0 = FullMath.mulDiv(priceX96, FeeTiers.PRICE_UNIT, 1 << 96);
        uint256 yesPrice;
        if (yesIsCurrency0) {
            yesPrice = priceToken1PerToken0;
        } else {
            if (priceToken1PerToken0 == 0) return FeeTiers.PRICE_UNIT;
            yesPrice = FullMath.mulDiv(FeeTiers.PRICE_UNIT, FeeTiers.PRICE_UNIT, priceToken1PerToken0);
        }
        if (yesPrice > FeeTiers.PRICE_UNIT) yesPrice = FeeTiers.PRICE_UNIT;
        return yesPrice;
    }

    /// @dev Slippage is checked AFTER the swap settles against the post-swap sqrtPrice
    ///      hookData length < 40 bytes opts out.
    function _enforceSlippage(bytes calldata hookData, uint160 sqrtPriceX96, bool zeroForOne) private pure {
        if (hookData.length < FeeTiers.HOOKDATA_SLIPPAGE_END) return;
        uint160 maxSqrtPriceX96 =
            uint160(bytes20(hookData[FeeTiers.HOOKDATA_REFERRER_END:FeeTiers.HOOKDATA_SLIPPAGE_END]));
        if (maxSqrtPriceX96 == 0) return;
        if (zeroForOne) {
            if (sqrtPriceX96 < maxSqrtPriceX96) revert Hook_MaxSlippageExceeded();
        } else {
            if (sqrtPriceX96 > maxSqrtPriceX96) revert Hook_MaxSlippageExceeded();
        }
    }
}
