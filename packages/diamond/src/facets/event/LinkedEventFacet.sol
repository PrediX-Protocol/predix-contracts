// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ERC165Checker} from "@openzeppelin/contracts/utils/introspection/ERC165Checker.sol";

import {ILinkedEventFacet} from "@predix/shared/interfaces/ILinkedEventFacet.sol";
import {IEventFacet} from "@predix/shared/interfaces/IEventFacet.sol";
import {IEventOracle} from "@predix/shared/interfaces/IEventOracle.sol";
import {IMarketFacet} from "@predix/shared/interfaces/IMarketFacet.sol";
import {IOutcomeToken} from "@predix/shared/interfaces/IOutcomeToken.sol";
import {Modules} from "@predix/shared/constants/Modules.sol";
import {Roles} from "@predix/shared/constants/Roles.sol";
import {TransientReentrancyGuard} from "@predix/shared/utils/TransientReentrancyGuard.sol";

import {LibAccessControl} from "@predix/diamond/libraries/LibAccessControl.sol";
import {LibConfigStorage} from "@predix/diamond/libraries/LibConfigStorage.sol";
import {LibEventStorage} from "@predix/diamond/libraries/LibEventStorage.sol";
import {LibMarket} from "@predix/diamond/libraries/LibMarket.sol";
import {LibMarketStorage} from "@predix/diamond/libraries/LibMarketStorage.sol";
import {LibPausable} from "@predix/diamond/libraries/LibPausable.sol";

/// @title LinkedEventFacet
/// @notice Shared-collateral (NegRisk-style) multi-outcome events. One USDC pool (`eventPool[eventId]`)
///         backs N mutually-exclusive binary child markets. Per-outcome split/merge is handled by the
///         linked-aware `MarketFacet.splitPosition`/`mergePositions` (which route to the pool); this facet
///         owns event creation, complete-set mint/redeem, and the resolution-time pooled redemption.
/// @dev Solvency invariant (proved in DESIGN/PLAN §2): with `yᵢ = YES_i.totalSupply`,
///      `nᵢ = NO_i.totalSupply`, and `M = yᵢ − nᵢ` (uniform across i), `eventPool == Σ nᵢ + M`, and the
///      payout if outcome k wins, `y_k + Σ_{j≠k} n_j`, equals `eventPool` for EVERY k. Every state change
///      below preserves this; `totalCollateralLocked` is updated in lockstep so `rescueSurplus` is correct.
contract LinkedEventFacet is ILinkedEventFacet, TransientReentrancyGuard {
    using SafeERC20 for IERC20;

    /// @notice Minimum / maximum candidate outcomes per event. Mirror `EventFacet` so linked and legacy
    ///         events share the same bounds; `MAX_CANDIDATES` also bounds the completeSet/redeem loops.
    uint256 internal constant MIN_CANDIDATES = 2;
    uint256 internal constant MAX_CANDIDATES = 50;

    /// @notice Basis-point denominator (100% = 10000). Mirrors `MarketFacet.BPS_DENOMINATOR`.
    uint256 internal constant BPS_DENOMINATOR = 10000;

    // -----------------------------------------------------------------------
    // Lifecycle
    // -----------------------------------------------------------------------

    /// @inheritdoc ILinkedEventFacet
    function createLinkedEvent(
        string calldata name,
        string[] calldata candidateQuestions,
        uint256 endTime,
        address oracle
    ) external override nonReentrant returns (uint256 eventId, uint256[] memory marketIds) {
        LibPausable.enforceNotPaused(Modules.MARKET);
        if (!LibAccessControl.hasRole(Roles.CREATOR_ROLE, msg.sender)) revert IEventFacet.Event_NotCreator();

        if (bytes(name).length == 0) revert IEventFacet.Event_EmptyName();
        if (endTime <= block.timestamp) revert IEventFacet.Event_InvalidEndTime();
        if (oracle == address(0)) revert IEventFacet.Event_ZeroOracle();
        if (!LibConfigStorage.layout().approvedOracles[oracle]) revert IEventFacet.Event_OracleNotApproved();
        if (!ERC165Checker.supportsInterface(oracle, type(IEventOracle).interfaceId)) {
            revert IEventFacet.Event_OracleNotEventCapable();
        }

        uint256 n = candidateQuestions.length;
        if (n < MIN_CANDIDATES) revert IEventFacet.Event_TooFewCandidates();
        if (n > MAX_CANDIDATES) revert IEventFacet.Event_TooManyCandidates();
        for (uint256 i; i < n; ++i) {
            if (bytes(candidateQuestions[i]).length == 0) revert IMarketFacet.Market_EmptyQuestion();
        }

        LibEventStorage.Layout storage es = LibEventStorage.layout();
        eventId = ++es.eventCount;
        LibEventStorage.EventData storage e = es.events[eventId];
        e.name = name;
        e.endTime = endTime;
        e.creator = msg.sender;
        e.oracle = oracle;
        e.linked = true;
        // v1: linked events are redemption-fee-free (owner decision 2026-05-31). `redemptionFeeBps`
        // stays 0 (struct default), so `redeemLinked` pays the full claim and IGNORES the global
        // default fee. The general fee path in `redeemLinked` is retained for a configurable linked
        // fee in v1.1.

        LibMarketStorage.Layout storage ms = LibMarketStorage.layout();
        marketIds = new uint256[](n);
        for (uint256 i; i < n; ++i) {
            uint256 marketId = LibMarket.create(candidateQuestions[i], endTime, address(0), eventId);
            ms.markets[marketId].linkedChild = true;
            marketIds[i] = marketId;
            e.marketIds.push(marketId);
            es.marketToEvent[marketId] = eventId;
        }

        emit LinkedEventCreated(eventId, msg.sender, endTime, marketIds, oracle);
    }

    /// @inheritdoc ILinkedEventFacet
    function mintCompleteSet(uint256 eventId, uint256 amount) external override nonReentrant {
        LibPausable.enforceNotPaused(Modules.MARKET);
        if (amount == 0) revert LinkedEvent_ZeroAmount();

        LibEventStorage.EventData storage e = _linkedEvent(eventId);
        if (e.isResolved) revert LinkedEvent_AlreadyResolved();
        if (e.refundModeActive) revert LinkedEvent_RefundModeActive();
        if (block.timestamp >= e.endTime) revert LinkedEvent_Ended();

        // Effects (CEI): credit the pool + global lock before the external pull/mint.
        LibEventStorage.layout().eventPool[eventId] += amount;
        LibMarketStorage.layout().totalCollateralLocked += amount;

        LibConfigStorage.layout().collateralToken.safeTransferFrom(msg.sender, address(this), amount);

        LibMarketStorage.Layout storage ms = LibMarketStorage.layout();
        uint256 n = e.marketIds.length;
        for (uint256 i; i < n; ++i) {
            IOutcomeToken(ms.markets[e.marketIds[i]].yesToken).mint(msg.sender, amount);
        }

        emit CompleteSetMinted(eventId, msg.sender, amount);
    }

    /// @inheritdoc ILinkedEventFacet
    function redeemCompleteSet(uint256 eventId, uint256 amount) external override nonReentrant {
        LibPausable.enforceNotPaused(Modules.MARKET);
        if (amount == 0) revert LinkedEvent_ZeroAmount();

        LibEventStorage.EventData storage e = _linkedEvent(eventId);
        if (e.isResolved) revert LinkedEvent_AlreadyResolved();
        if (e.refundModeActive) revert LinkedEvent_RefundModeActive();

        LibMarketStorage.Layout storage ms = LibMarketStorage.layout();
        uint256 n = e.marketIds.length;
        // Burn one YES of every outcome first — reverts if the caller is short any leg.
        for (uint256 i; i < n; ++i) {
            IOutcomeToken(ms.markets[e.marketIds[i]].yesToken).burn(msg.sender, amount);
        }

        LibEventStorage.layout().eventPool[eventId] -= amount; // underflow-checked
        LibMarketStorage.layout().totalCollateralLocked -= amount;

        LibConfigStorage.layout().collateralToken.safeTransfer(msg.sender, amount);

        emit CompleteSetRedeemed(eventId, msg.sender, amount);
    }

    /// @inheritdoc ILinkedEventFacet
    /// @dev Post-resolution redemption deliberately bypasses the MARKET pause guard, mirroring
    ///      `MarketFacet.redeem`: the outcome is final and a paused module must not hold winners' funds.
    function redeemLinked(uint256 eventId) external override nonReentrant returns (uint256 payout) {
        LibEventStorage.EventData storage e = _linkedEvent(eventId);
        if (!e.isResolved) revert LinkedEvent_NotResolved();
        // Defense-in-depth: linked events cannot enter refund mode in v1 (Event_LinkedNoRefund), so this
        // is unreachable today — kept so redeemLinked can never run against a future refund state.
        if (e.refundModeActive) revert LinkedEvent_RefundModeActive();

        LibMarketStorage.Layout storage ms = LibMarketStorage.layout();
        uint256 n = e.marketIds.length;
        uint256 winningIndex = e.winningIndex;
        uint256 grossClaim;

        for (uint256 i; i < n; ++i) {
            LibMarketStorage.MarketData storage m = ms.markets[e.marketIds[i]];
            // Winner pays on YES, every loser pays on NO — `payout(k) == eventPool` by the solvency THM.
            IOutcomeToken token = i == winningIndex ? IOutcomeToken(m.yesToken) : IOutcomeToken(m.noToken);
            uint256 bal = token.balanceOf(msg.sender);
            if (bal > 0) {
                token.burn(msg.sender, bal);
                grossClaim += bal;
            }
        }
        if (grossClaim == 0) revert LinkedEvent_NothingToRedeem();

        uint256 pool = LibEventStorage.layout().eventPool[eventId];
        // Accounting tripwire: must never fire if `eventPool == Σ nᵢ + M` holds.
        if (pool < grossClaim) revert LinkedEvent_PoolInsolvent();

        // Floor rounding (fee down → payout up) is intentional and matches MarketFacet.redeem; the pool is
        // decremented by the FULL grossClaim so `fee + payout == grossClaim` and the pool still drains to 0.
        uint256 fee = (grossClaim * e.redemptionFeeBps) / BPS_DENOMINATOR;
        payout = grossClaim - fee;

        LibEventStorage.layout().eventPool[eventId] = pool - grossClaim;
        LibMarketStorage.layout().totalCollateralLocked -= grossClaim;

        LibConfigStorage.Layout storage cfg = LibConfigStorage.layout();
        if (fee > 0) {
            cfg.collateralToken.safeTransfer(cfg.feeRecipient, fee);
        }
        if (payout > 0) {
            cfg.collateralToken.safeTransfer(msg.sender, payout);
        }

        emit LinkedRedeemed(eventId, msg.sender, grossClaim, fee, payout);
    }

    // -----------------------------------------------------------------------
    // Views
    // -----------------------------------------------------------------------

    /// @inheritdoc ILinkedEventFacet
    function eventPoolOf(uint256 eventId) external view override returns (uint256) {
        return LibEventStorage.layout().eventPool[eventId];
    }

    /// @inheritdoc ILinkedEventFacet
    function isLinkedEvent(uint256 eventId) external view override returns (bool) {
        return LibEventStorage.layout().events[eventId].linked;
    }

    // -----------------------------------------------------------------------
    // Internal helpers
    // -----------------------------------------------------------------------

    function _linkedEvent(uint256 eventId) private view returns (LibEventStorage.EventData storage e) {
        e = LibEventStorage.layout().events[eventId];
        if (e.creator == address(0)) revert LinkedEvent_NotFound();
        if (!e.linked) revert LinkedEvent_NotLinked();
    }
}
