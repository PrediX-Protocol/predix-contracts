// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";

/// @title IPrediXHook
/// @notice External surface of the PrediX Uniswap v4 hook: admin, pool registration,
///         trusted-router anti-sandwich commitment, and read-only views.
/// @dev `IHooks` callbacks themselves (`beforeSwap`, `afterSwap`, ...) are not
///      re-declared here — they live on the `IHooks` interface from v4-core and
///      are wired through `PrediXHookProxyV2` (the salt-mined hook address) into
///      `PrediXHookV2`.
interface IPrediXHook {
    // ---------------------------------------------------------------------
    // Events
    // ---------------------------------------------------------------------

    /// @notice Emitted exactly once, when `initialize` binds the hook to its diamond, admin
    ///         and quote token. Must fire inside the proxy constructor's atomic delegatecall;
    ///         a post-deploy `initialize` call is impossible because the proxy bootstraps
    ///         the implementation in its own constructor.
    event Hook_Initialized(address indexed diamond, address indexed admin, address indexed quoteToken);

    /// @notice Emitted when the diamond rebind changes. Used by off-chain indexers to follow
    ///         the active market system across diamond cuts.
    event Hook_DiamondUpdated(address indexed previous, address indexed current);

    /// @notice Emitted when the runtime admin (pause / router / diamond setter) changes.
    ///         Post-FINAL-H09 this fires from `acceptAdmin`, not `setAdmin`.
    event Hook_AdminUpdated(address indexed previous, address indexed current);

    /// @notice Emitted by `setAdmin` — FINAL-H09's propose leg of the 2-step rotation.
    ///         Pairs with `Hook_AdminUpdated` once the pending admin calls `acceptAdmin`.
    event Hook_AdminChangeProposed(address indexed current, address indexed pending);

    /// @notice M-03 (audit Pass 2.1): emitted by `cancelAdminRotation` when
    ///         a pending admin nomination is discarded before the nominee
    ///         accepts.
    event Hook_AdminChangeCancelled(address indexed cancelled);

    /// @notice Emitted by `setPaused`. When `paused` is true `_beforeSwap`,
    ///         `_beforeAddLiquidity` and `_beforeDonate` revert; `_beforeRemoveLiquidity`
    ///         is always permitted so LPs can exit.
    event Hook_PauseStatusChanged(bool paused);

    /// @notice Emitted when a router is added to or removed from the trusted set. Trusted
    ///         routers are the only callers permitted to invoke `commitSwapIdentity` and
    ///         override the anti-sandwich identity from the raw `msg.sender` to the real
    ///         end user.
    event Hook_TrustedRouterUpdated(address indexed router, bool trusted);

    /// @notice Emitted by `proposeTrustedRouter` (post-bootstrap). The eventual
    ///         state change fires a `Hook_TrustedRouterUpdated` when
    ///         `executeTrustedRouter` is called after the delay. (H-H02)
    event Hook_TrustedRouterProposed(address indexed router, bool trusted, uint256 readyAt);

    /// @notice Emitted when a pending trusted-router proposal is cancelled
    ///         before execution. (H-H02)
    event Hook_TrustedRouterCancelled(address indexed router);

    /// @notice Emitted exactly once when `completeBootstrap` is called. After
    ///         this point, immediate-apply `setTrustedRouter` is permanently
    ///         disabled; trust changes must use the propose/execute flow. (H-H02)
    event Hook_BootstrapCompleted();

    /// @notice Emitted by `proposeDiamond` (F-X-02). `Hook_DiamondUpdated`
    ///         fires later when `executeDiamondRotation` runs after
    ///         `DIAMOND_ROTATION_DELAY`.
    event Hook_DiamondRotationProposed(address indexed diamond, uint256 readyAt);

    /// @notice Emitted when a pending diamond rotation is cancelled before
    ///         execution. (F-X-02)
    event Hook_DiamondRotationCancelled(address indexed diamond);

    /// @notice H-01 audit fix: emitted by `proposeUnregisterMarketPool`. The
    ///         binding stays in place until `executeUnregisterMarketPool` is
    ///         called at or after `readyAt`.
    event Hook_MarketUnregisterProposed(uint256 indexed marketId, uint256 readyAt);

    /// @notice H-01 audit fix: emitted by `executeUnregisterMarketPool` when
    ///         the per-market binding is removed.
    event Hook_MarketUnregistered(uint256 indexed marketId, PoolId indexed poolId);

    /// @notice H-01 audit fix: emitted when a pending unregister is cancelled
    ///         before execution.
    event Hook_MarketUnregisterCancelled(uint256 indexed marketId);

    /// @notice Emitted when the diamond registers a new outcome-token / quote-token pool
    ///         with the hook, binding it to `marketId` and freezing the YES/quote ordering.
    event Hook_PoolRegistered(
        uint256 indexed marketId, PoolId indexed poolId, address yesToken, address quoteToken, bool yesIsCurrency0
    );

    /// @notice Emitted for every swap settled by the hook. `usdcVolume` is measured on the
    ///         quote leg — this is the audit fix for H-02. Off-chain indexers reconstruct
    ///         per-market totals from this stream.
    event Hook_MarketTraded(
        uint256 indexed marketId,
        address indexed trader,
        bool isBuy,
        uint256 usdcVolume,
        uint256 yesVolume,
        uint256 yesPrice
    );

    /// @notice Emitted when a swap carries a non-zero referrer in its hookData prefix.
    ///         Referral credits are NEVER accumulated on-chain (legacy bug class) — off-chain
    ///         indexers consume this event and apply the commission rate themselves.
    event Hook_ReferralRecorded(
        uint256 indexed marketId, address indexed referrer, address indexed trader, uint256 usdcVolume
    );

    // ---------------------------------------------------------------------
    // Errors
    // ---------------------------------------------------------------------

    /// @notice Thrown when `initialize` runs a second time on the same proxy.
    error Hook_AlreadyInitialized();

    /// @notice Thrown when `registerMarketPool` runs before the proxy constructor has bootstrapped
    ///         implementation state (impossible in normal use; defence against custom deployers).
    error Hook_NotInitialized();

    /// @notice Thrown when any address argument is `address(0)`.
    error Hook_ZeroAddress();

    /// @notice Thrown when an admin-gated function is called by anyone other than `_admin`.
    error Hook_OnlyAdmin();

    /// @notice Thrown when `commitSwapIdentity` is called by an address that is not in the
    ///         trusted-router set.
    error Hook_OnlyTrustedRouter();

    /// @notice Thrown when an external IHooks callback is called by anyone other than the
    ///         Uniswap v4 PoolManager. Replaces `BaseHook.NotPoolManager` after the M1 refactor.
    error Hook_NotPoolManager();

    /// @notice Thrown when an IHooks callback is invoked for a permission flag the hook does
    ///         not enable (e.g. `afterSwap`'s sibling `afterAddLiquidity`). PoolManager will
    ///         not call these in normal operation; this guard catches misconfiguration.
    error Hook_NotImplemented();

    /// @notice Thrown when a swap, add-liquidity or donate is attempted while the hook is
    ///         paused. Remove-liquidity is intentionally exempt.
    error Hook_Paused();

    /// @notice Thrown when a callback fires on a pool whose `poolToMarket` binding is unset.
    error Hook_PoolNotRegistered();

    /// @notice Thrown when `registerMarketPool` is called twice for the same `PoolId`.
    error Hook_PoolAlreadyRegistered();
    error Hook_MarketAlreadyHasPool();

    /// @notice Thrown when `_beforeInitialize` sees a pool whose `key.fee` lacks the v4
    ///         dynamic-fee flag — without it the hook's per-swap fee override is silently
    ///         ignored by PoolManager.
    error Hook_PoolFeeNotDynamic();

    /// @notice Thrown when `registerMarketPool` is called with a key whose currencies do not
    ///         match the market's `(yesToken, quoteToken)` pair in either ordering.
    error Hook_InvalidPoolCurrencies();

    /// @notice Thrown when `registerMarketPool` is called with a marketId the diamond does
    ///         not know about (`MarketView.yesToken == address(0)`).
    error Hook_MarketNotFound();

    /// @notice Thrown when a swap, add-liquidity or donate hits an already-resolved market.
    error Hook_MarketResolved();

    /// @notice Thrown when a swap, add-liquidity or donate hits a market in refund mode.
    ///         Trading must stop once the diamond enables refund mode so LPs are not
    ///         adverse-selected against users who already know no resolution is coming.
    ///         `beforeRemoveLiquidity` remains open so LPs can exit. (H-H01 fix)
    error Hook_MarketInRefundMode();

    /// @notice Thrown when a swap or add-liquidity hits a market whose `endTime` has passed.
    error Hook_MarketExpired();

    /// @notice Thrown when an identity attempts to swap in the OPPOSITE direction inside the
    ///         same block on the same market — same-block back-leg of a sandwich. Same-direction
    ///         repeats inside one block are explicitly allowed.
    error Hook_SandwichDetected();

    /// @notice Thrown in `_afterSwap` when the post-swap `sqrtPriceX96` violates the
    ///         `maxSqrtPriceX96` carried in the swap's `hookData[20:40]` slice.
    error Hook_MaxSlippageExceeded();

    /// @notice Thrown in `_beforeSwap` when the caller is not in the trusted-router set.
    ///         Hard-gate replaces the pre-FINAL-H06 silent fallback to `sender`, which
    ///         made INV-5 advisory and allowed attacker-deployed contracts to bypass the
    ///         anti-sandwich identity commit by swapping directly through PoolManager.
    error Hook_UntrustedCaller(address caller);

    /// @notice Thrown in `_beforeSwap` when a trusted router swapped without first calling
    ///         `commitSwapIdentity`. INV-5 requires that every swap carries a user identity
    ///         — no commit means the router has nothing to resolve.
    error Hook_MissingRouterCommit();

    /// @notice Thrown by `acceptAdmin` when the caller is not the address queued by `setAdmin`.
    error Hook_OnlyPendingAdmin();

    /// @notice Thrown in `_beforeInitialize` when the implied YES price derived from
    ///         `sqrtPriceX96` sits outside the ±5% window around `PRICE_UNIT / 2`. Per
    ///         FINAL-H11 this closes the permissionless-register-then-initialize front-run
    ///         that would otherwise let a hostile caller lock the pool at an unfair price.
    error Hook_InitPriceOutOfWindow();

    /// @notice H-H02: reverts when the immediate-apply `setTrustedRouter` is
    ///         called after `completeBootstrap`. Use the propose/execute flow.
    error Hook_BootstrapComplete();

    /// @notice H-H02: reverts when the propose/execute flow is called before
    ///         `completeBootstrap` — the deploy window requires the immediate
    ///         setter and the propose/execute path would otherwise race.
    error Hook_BootstrapNotComplete();

    /// @notice H-H02: reverts when `executeTrustedRouter` / `cancelTrustedRouter`
    ///         find no pending change for `router`.
    error Hook_NoPendingRouterChange();

    /// @notice H-H02: reverts when `executeTrustedRouter` is called before
    ///         `TRUSTED_ROUTER_DELAY` has elapsed since the proposal.
    error Hook_TrustedRouterDelayNotElapsed();

    /// @notice FIN-03: reverts when `proposeTrustedRouter` is called while a
    ///         proposal for the same router is still pending. Admin must
    ///         cancel the outstanding proposal first; a silent overwrite
    ///         would let admin reset the 48h timer indefinitely.
    error Hook_AlreadyPendingRouter();

    /// @notice F-X-02: reverts when `executeDiamondRotation` or
    ///         `cancelDiamondRotation` is called with no pending proposal.
    error Hook_NoPendingDiamondChange();

    /// @notice F-X-02: reverts when `executeDiamondRotation` is called
    ///         before `DIAMOND_ROTATION_DELAY` has elapsed since the proposal.
    error Hook_DiamondDelayNotElapsed();

    /// @notice M-01 audit fix: reverts when `proposeDiamond` is called while
    ///         a proposal is still pending. Admin must `cancelDiamondRotation`
    ///         first; mirrors H4's no-silent-reset pattern.
    error Hook_AlreadyPendingDiamondChange();

    /// @notice L-04 audit fix: reverts when `proposeDiamond` /
    ///         `executeDiamondRotation` is called with a target whose
    ///         `code.length == 0`. Mirrors the proxy's
    ///         `HookProxy_NotAContract` defence.
    error Hook_DiamondNotAContract();

    /// @notice H-01 audit fix: reverts when `executeUnregisterMarketPool` /
    ///         `cancelUnregisterMarketPool` is called with no pending
    ///         unregister for the marketId.
    error Hook_NoPendingUnregister();

    /// @notice H-01 audit fix: reverts when `executeUnregisterMarketPool`
    ///         is called before `MARKET_UNREGISTER_DELAY` has elapsed.
    error Hook_UnregisterDelayNotElapsed();

    /// @notice M-01 universal guard: reverts when `proposeUnregisterMarketPool`
    ///         is called for a marketId whose unregister proposal is still
    ///         pending. Mirrors `Hook_AlreadyPendingDiamondChange` /
    ///         `Hook_AlreadyPendingRouter` so all five propose flows share
    ///         the same no-silent-reset contract.
    error Hook_AlreadyPendingUnregister();

    /// @notice M-03 (audit Pass 2.1): reverts when `acceptAdmin` is called
    ///         before the 48h `ADMIN_ROTATION_DELAY` has elapsed since
    ///         `setAdmin` proposed the new admin. Brings hook admin rotation
    ///         in line with the diamond / trusted-router / unregister /
    ///         upgrade / timelock-duration governance cadence.
    error Hook_AdminDelayNotElapsed();

    /// @notice M-03 (audit Pass 2.1): reverts when `setAdmin` is called
    ///         while a previous admin nomination is still pending. Mirrors
    ///         the universal AlreadyPending pattern (M-01).
    error Hook_AlreadyPendingAdmin();

    /// @notice M-03 (audit Pass 2.1): reverts when `cancelAdminRotation`
    ///         is called with no pending admin nomination.
    error Hook_NoPendingAdminChange();

    /// @notice M-02 audit fix: reverts in `_beforeSwap` /
    ///         `_beforeAddLiquidity` / `_beforeDonate` when the registered
    ///         binding's yesToken position no longer matches the diamond's
    ///         current marketView for the bound marketId. Catches stale
    ///         bindings that survived a diamond rotation without being
    ///         cleared via `proposeUnregisterMarketPool`.
    error Hook_StaleBinding();

    /// @notice NEW-M4: reverts when the impl constructor is called with
    ///         `canonicalLpFee_ == 0`. Zero would disable the canonical-key
    ///         check at registration time.
    error Hook_InvalidCanonicalFee();

    /// @notice NEW-M4: reverts when the impl constructor is called with
    ///         `canonicalTickSpacing_ == 0`. Same rationale as
    ///         `Hook_InvalidCanonicalFee`.
    error Hook_InvalidCanonicalTickSpacing();

    /// @notice NEW-M4: reverts when `registerMarketPool` is called with a
    ///         `PoolKey` whose `fee` does not match `canonicalLpFee`.
    ///         Front-run-brick defence.
    error Hook_NonCanonicalFee();

    /// @notice NEW-M4: reverts when `registerMarketPool` is called with a
    ///         `PoolKey` whose `tickSpacing` does not match
    ///         `canonicalTickSpacing`. Front-run-brick defence.
    error Hook_NonCanonicalTickSpacing();

    /// @notice NEW-M4: reverts when `registerMarketPool` is called with a
    ///         `PoolKey` whose `hooks` field does not equal this hook's
    ///         own address. Prevents registering a pool that routes callbacks
    ///         to an unrelated contract while holding the canonical marketId
    ///         binding on this hook.
    error Hook_WrongHookAddress();

    /// @notice H-H03 / NEW-M6: reverts from `commitSwapIdentityFor` when
    ///         `caller != msg.sender` AND `caller != quoter`. Only two
    ///         cross-slot writes are legitimate — self-commit or the
    ///         canonical quoter pre-commit path.
    error Hook_InvalidCommitTarget();

    // ---------------------------------------------------------------------
    // Admin
    // ---------------------------------------------------------------------

    /// @notice One-shot bootstrap. Binds the hook to its diamond, admin, and quote token.
    /// @dev MUST be invoked exactly once, atomically, from `PrediXHookProxyV2`'s constructor
    ///      via delegatecall. Any post-deploy call reverts because `_initialized` is already
    ///      `true`. There is intentionally no caller gate here — atomicity is the gate.
    function initialize(address diamond_, address admin_, address quoteToken_) external;

    /// @notice Propose re-pointing the hook at a new diamond. Admin-gated.
    ///         Emits `Hook_DiamondRotationProposed`; the rotation applies only
    ///         after `executeDiamondRotation` is called post
    ///         `DIAMOND_ROTATION_DELAY`. Replaces the single-step `setDiamond`
    ///         so a compromised admin cannot instant-redirect market queries
    ///         to a malicious diamond (F-X-02).
    /// @dev    Pending storage slots are overwritten by a later propose; there
    ///         is no pending-exists guard because diamond rotation is a
    ///         rarely-used ops path and an admin re-evaluating the target
    ///         address within the delay window is a legitimate case.
    /// @dev    IMPORTANT — `_poolBinding` and `_marketToPoolId` are NOT
    ///         auto-cleared on rotation. Use the `proposeUnregisterMarketPool`
    ///         / `executeUnregisterMarketPool` flow (also 48h timelocked) to
    ///         clear stale bindings for any marketId whose pool is no longer
    ///         valid under the new diamond.
    function proposeDiamond(address diamond_) external;

    /// @notice Finalize a pending diamond rotation after the delay has
    ///         elapsed. Admin-gated. Emits `Hook_DiamondUpdated`.
    function executeDiamondRotation() external;

    /// @notice Cancel a pending diamond rotation. Admin-gated.
    function cancelDiamondRotation() external;

    /// @notice View the pending diamond rotation.
    /// @return pending  Proposed new diamond, `address(0)` if none.
    /// @return readyAt  Earliest timestamp at which `executeDiamondRotation`
    ///                  may succeed, zero if no pending change.
    function pendingDiamond() external view returns (address pending, uint256 readyAt);

    /// @notice H-01 audit fix: schedule removal of a market's pool binding.
    ///         48h timelock matches the diamond rotation cadence — every
    ///         binding-affecting operation carries the same governance
    ///         notice as the rotation that motivated it. Admin-gated.
    /// @dev    Pending state is keyed per marketId; concurrent unregisters
    ///         for different markets do not interfere.
    function proposeUnregisterMarketPool(uint256 marketId) external;

    /// @notice Finalize a pending unregister. Clears `_poolBinding[poolId]`
    ///         and `_marketToPoolId[marketId]` so a subsequent
    ///         `registerMarketPool` for the same `marketId` (typically
    ///         post-rotation under a new diamond) succeeds. Admin-gated.
    function executeUnregisterMarketPool(uint256 marketId) external;

    /// @notice Cancel a pending unregister before its timelock elapses.
    ///         Admin-gated.
    function cancelUnregisterMarketPool(uint256 marketId) external;

    /// @notice View the pending unregister readyAt for a marketId.
    /// @return readyAt Earliest timestamp at which
    ///                 `executeUnregisterMarketPool(marketId)` may succeed,
    ///                 zero if no pending unregister.
    function pendingUnregisterMarketPool(uint256 marketId) external view returns (uint256 readyAt);

    /// @notice Propose a new admin. Admin-gated, emits `Hook_AdminChangeProposed`.
    ///         Per FINAL-H09 + M-03 (audit Pass 2.1) this only stores the
    ///         pending address with a 48h timelock; the rotation is completed
    ///         by `acceptAdmin` AT OR AFTER `_pendingAdminReadyAt`. The
    ///         AlreadyPending guard prevents silent overwrite of an in-flight
    ///         nomination — admin must `cancelAdminRotation` first.
    function setAdmin(address admin_) external;

    /// @notice Complete a pending admin rotation after the 48h timelock has
    ///         elapsed. Callable only by the address previously queued via
    ///         `setAdmin`. Clears the pending slot and emits `Hook_AdminUpdated`.
    function acceptAdmin() external;

    /// @notice M-03 (audit Pass 2.1): cancel a pending admin nomination
    ///         before the nominee accepts. Admin-only — gives legitimate
    ///         admin a recovery window if a compromised admin proposed an
    ///         attacker key.
    function cancelAdminRotation() external;

    /// @notice Toggle the emergency pause. Admin-gated, emits `Hook_PauseStatusChanged`.
    function setPaused(bool paused_) external;

    /// @notice Add or remove a router from the trusted set. Admin-gated.
    /// @dev H-H02: available ONLY during the bootstrap window
    ///      (`bootstrapped() == false`). After `completeBootstrap`, all trust
    ///      changes must route through `proposeTrustedRouter` / `executeTrustedRouter`
    ///      with a 48h delay between the two.
    function setTrustedRouter(address router, bool trusted) external;

    /// @notice Finalize the bootstrap window. Once called, `setTrustedRouter`
    ///         is permanently disabled and trust changes require the 48h
    ///         propose/execute flow. Admin-gated, one-shot, emits
    ///         `Hook_BootstrapCompleted`.
    function completeBootstrap() external;

    /// @notice Propose adding or removing a router from the trusted set.
    ///         Admin-gated. Requires bootstrap to have completed. Call
    ///         `executeTrustedRouter` after `TRUSTED_ROUTER_DELAY` to apply.
    function proposeTrustedRouter(address router, bool trusted) external;

    /// @notice Execute a pending trusted-router change after the delay.
    ///         Permissionless — anyone can cron the execution once ready.
    function executeTrustedRouter(address router) external;

    /// @notice Cancel a pending trusted-router proposal. Admin-gated.
    function cancelTrustedRouter(address router) external;

    /// @notice Permissionless. Binds `poolId` (derived from `key`) to `marketId`, verifying
    ///         that one leg is the market's YES outcome token and the other is the configured
    ///         quote token. MUST be called BEFORE `poolManager.initialize(key, ...)` for the
    ///         same key.
    /// @dev Anyone can call this. The hook validates that `marketId` exists in the diamond
    ///      (`yesToken != address(0)`) and that the currency pair is `(diamond-issued yesToken,
    ///      configured quote token)` in either ordering — so a junk binding cannot be planted.
    ///      The deploy script is the expected caller in production.
    function registerMarketPool(uint256 marketId, PoolKey calldata key) external;

    // ---------------------------------------------------------------------
    // Trusted-router commit (anti-sandwich C-03)
    // ---------------------------------------------------------------------

    /// @notice Called by a trusted router immediately before `poolManager.swap`. Stores the
    ///         real end-user against the `(router, poolId)` pair so the next `_beforeSwap`
    ///         in the same transaction reads the user identity rather than the router's.
    /// @dev Storage is **transient** (EIP-1153). The commitment lives only inside the current
    ///      transaction and MUST be paired with an immediately-following `poolManager.swap`
    ///      in the same call frame. There is no cross-transaction commit/swap path.
    function commitSwapIdentity(address user, PoolId poolId) external;

    /// @notice Pre-commit identity under another trusted caller's transient slot.
    /// @dev Used by the router to pre-populate `_commitSlot(quoter, poolId)` before
    ///      calling `V4Quoter.quoteExactInputSingle`, so the quoter's simulate-and-revert
    ///      `beforeSwap(sender=quoter, ...)` finds the committed identity. Both `msg.sender`
    ///      AND `caller` must be in the trusted-router set — prevents arbitrary slot planting.
    /// @param caller The address whose commit slot will be written (e.g., V4Quoter address).
    /// @param user   The real end-user identity to commit.
    /// @param poolId The pool the swap targets.
    function commitSwapIdentityFor(address caller, address user, PoolId poolId) external;

    // ---------------------------------------------------------------------
    // Views
    // ---------------------------------------------------------------------

    function diamond() external view returns (address);
    function admin() external view returns (address);
    function quoteToken() external view returns (address);
    function paused() external view returns (bool);
    function isTrustedRouter(address router) external view returns (bool);
    function poolMarketId(PoolId poolId) external view returns (uint256);

    /// @notice Whether the bootstrap window has been closed. Post-bootstrap
    ///         `setTrustedRouter` is disabled; trust changes require the
    ///         propose/execute flow.
    function bootstrapped() external view returns (bool);

    /// @notice Read the pending trusted-router change for `router`, if any.
    /// @return trusted The proposed final state.
    /// @return readyAt Timestamp at which `executeTrustedRouter` becomes callable. Zero if none pending.
    function pendingTrustedRouter(address router) external view returns (bool trusted, uint256 readyAt);

    /// @notice M-03 (audit Pass 2.1): pending admin rotation, or (zero, 0)
    ///         if none.
    /// @return pending The proposed new admin address, or zero if no pending.
    /// @return readyAt Timestamp at which `acceptAdmin` becomes callable.
    function pendingAdminRotation() external view returns (address pending, uint256 readyAt);

    /// @notice Reads the transient identity commitment. Returns `address(0)` outside the
    ///         transaction in which `commitSwapIdentity` was called — useful in tests to
    ///         assert per-tx scoping.
    function committedIdentity(address router, PoolId poolId) external view returns (address);
}
