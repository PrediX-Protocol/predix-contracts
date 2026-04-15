// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {IMarketFacet} from "@predix/shared/interfaces/IMarketFacet.sol";
import {IOracle} from "@predix/shared/interfaces/IOracle.sol";
import {IOutcomeToken} from "@predix/shared/interfaces/IOutcomeToken.sol";
import {Modules} from "@predix/shared/constants/Modules.sol";
import {Roles} from "@predix/shared/constants/Roles.sol";
import {TransientReentrancyGuard} from "@predix/shared/utils/TransientReentrancyGuard.sol";

import {LibAccessControl} from "@predix/diamond/libraries/LibAccessControl.sol";
import {LibConfigStorage} from "@predix/diamond/libraries/LibConfigStorage.sol";
import {LibMarket} from "@predix/diamond/libraries/LibMarket.sol";
import {LibMarketStorage} from "@predix/diamond/libraries/LibMarketStorage.sol";
import {LibPausable} from "@predix/diamond/libraries/LibPausable.sol";

/// @title MarketFacet
/// @notice Lifecycle facet for binary prediction markets: create, split, merge, resolve,
///         emergency-resolve, redeem, refund, sweep, and admin configuration.
/// @dev Pool initialization is intentionally OUT OF SCOPE — the diamond emits
///      `MarketCreated` and an off-chain script (or the hook package) is responsible
///      for wiring the YES/NO tokens into Uniswap v4. The diamond never imports v4.
///      Admin-emergency entry points (`emergencyResolve`, `enableRefundMode`,
///      `sweepUnclaimed`) bypass the pause guard so the protocol stays recoverable.
contract MarketFacet is IMarketFacet, TransientReentrancyGuard {
    using SafeERC20 for IERC20;

    /// @notice Cooling-off period before an unresolved market can be force-closed by an operator.
    uint256 internal constant EMERGENCY_DELAY = 7 days;

    /// @notice Window after a market enters a final state during which users can still
    ///         claim. After this window an admin may sweep leftover collateral to the
    ///         fee recipient.
    uint256 internal constant GRACE_PERIOD = 365 days;

    /// @notice Hard ceiling on redemption fees. 1500 bps = 15%. Both
    ///         `defaultRedemptionFeeBps` and `perMarketRedemptionFeeBps` are bounded by this.
    uint256 internal constant MAX_REDEMPTION_FEE_BPS = 1500;

    /// @notice Basis-point denominator. 10000 = 100%.
    uint256 internal constant BPS_DENOMINATOR = 10000;

    // -----------------------------------------------------------------------
    // Lifecycle
    // -----------------------------------------------------------------------

    /// @inheritdoc IMarketFacet
    function createMarket(string calldata question, uint256 endTime, address oracle)
        external
        override
        nonReentrant
        returns (uint256 marketId)
    {
        LibPausable.enforceNotPaused(Modules.MARKET);

        if (bytes(question).length == 0) revert Market_EmptyQuestion();
        if (endTime <= block.timestamp) revert Market_InvalidEndTime();
        if (oracle == address(0)) revert Market_ZeroAddress();
        if (!LibConfigStorage.layout().approvedOracles[oracle]) revert Market_OracleNotApproved();

        marketId = LibMarket.create(question, endTime, oracle, 0);
    }

    /// @inheritdoc IMarketFacet
    function splitPosition(uint256 marketId, uint256 amount) external override nonReentrant {
        LibPausable.enforceNotPaused(Modules.MARKET);
        if (amount == 0) revert Market_ZeroAmount();

        LibMarketStorage.MarketData storage m = _market(marketId);
        if (m.isResolved) revert Market_AlreadyResolved();
        if (m.refundModeActive) revert Market_RefundModeActive();
        if (block.timestamp >= m.endTime) revert Market_Ended();

        uint256 cap = m.perMarketCap > 0 ? m.perMarketCap : LibConfigStorage.layout().defaultPerMarketCap;
        if (cap > 0 && m.totalCollateral + amount > cap) revert Market_ExceedsPerMarketCap();

        m.totalCollateral += amount;
        LibConfigStorage.layout().collateralToken.safeTransferFrom(msg.sender, address(this), amount);

        IOutcomeToken(m.yesToken).mint(msg.sender, amount);
        IOutcomeToken(m.noToken).mint(msg.sender, amount);

        emit PositionSplit(marketId, msg.sender, amount);
    }

    /// @inheritdoc IMarketFacet
    function mergePositions(uint256 marketId, uint256 amount) external override nonReentrant {
        LibPausable.enforceNotPaused(Modules.MARKET);
        if (amount == 0) revert Market_ZeroAmount();

        LibMarketStorage.MarketData storage m = _market(marketId);
        if (m.isResolved) revert Market_AlreadyResolved();
        if (m.refundModeActive) revert Market_RefundModeActive();

        IOutcomeToken(m.yesToken).burn(msg.sender, amount);
        IOutcomeToken(m.noToken).burn(msg.sender, amount);
        m.totalCollateral -= amount;

        LibConfigStorage.layout().collateralToken.safeTransfer(msg.sender, amount);
        emit PositionMerged(marketId, msg.sender, amount);
    }

    /// @inheritdoc IMarketFacet
    function resolveMarket(uint256 marketId) external override {
        LibPausable.enforceNotPaused(Modules.MARKET);

        LibMarketStorage.MarketData storage m = _market(marketId);
        if (m.eventId != 0) revert Market_PartOfEvent();
        if (m.isResolved) revert Market_AlreadyResolved();
        if (m.refundModeActive) revert Market_RefundModeActive();
        if (block.timestamp < m.endTime) revert Market_NotEnded();

        IOracle oracle = IOracle(m.oracle);
        if (!oracle.isResolved(marketId)) revert Market_OracleNotResolved();
        bool result = oracle.outcome(marketId);

        m.isResolved = true;
        m.outcome = result;
        m.resolvedAt = block.timestamp;

        emit MarketResolved(marketId, result, msg.sender);
    }

    /// @inheritdoc IMarketFacet
    function emergencyResolve(uint256 marketId, bool outcome) external override {
        LibAccessControl.checkRole(Roles.OPERATOR_ROLE);

        LibMarketStorage.MarketData storage m = _market(marketId);
        if (m.eventId != 0) revert Market_PartOfEvent();
        if (m.isResolved) revert Market_AlreadyResolved();
        if (m.refundModeActive) revert Market_RefundModeActive();
        if (block.timestamp < m.endTime + EMERGENCY_DELAY) revert Market_TooEarlyForEmergency();

        // If the oracle has since produced an answer, defer to it. Emergency
        // path is for genuine stalls only, not operator override.
        try IOracle(m.oracle).isResolved(marketId) returns (bool oracleReady) {
            if (oracleReady) revert Market_OracleResolvedUseResolve();
        } catch {
            // Oracle unreachable — emergency bypass intended.
        }

        m.isResolved = true;
        m.outcome = outcome;
        m.resolvedAt = block.timestamp;

        emit MarketEmergencyResolved(marketId, outcome, msg.sender);
    }

    /// @inheritdoc IMarketFacet
    function redeem(uint256 marketId) external override nonReentrant returns (uint256 payout) {
        LibPausable.enforceNotPaused(Modules.MARKET);

        LibMarketStorage.MarketData storage m = _market(marketId);
        if (!m.isResolved) revert Market_NotResolved();

        IOutcomeToken yes = IOutcomeToken(m.yesToken);
        IOutcomeToken no = IOutcomeToken(m.noToken);
        uint256 yesBal = yes.balanceOf(msg.sender);
        uint256 noBal = no.balanceOf(msg.sender);
        if (yesBal + noBal == 0) revert Market_NothingToRedeem();

        uint256 winningBurned;
        uint256 losingBurned;
        if (m.outcome) {
            winningBurned = yesBal;
            losingBurned = noBal;
        } else {
            winningBurned = noBal;
            losingBurned = yesBal;
        }

        if (yesBal > 0) yes.burn(msg.sender, yesBal);
        if (noBal > 0) no.burn(msg.sender, noBal);

        uint256 fee;
        if (winningBurned > 0) {
            uint256 feeBps = _effectiveRedemptionFee(m);
            fee = (winningBurned * feeBps) / BPS_DENOMINATOR;
            payout = winningBurned - fee;

            // Effects: decrement collateral by the FULL winning amount so fee + payout
            // sum exactly to `winningBurned` (integer math is exact by construction).
            m.totalCollateral -= winningBurned;

            // Interactions
            LibConfigStorage.Layout storage cfg = LibConfigStorage.layout();
            if (fee > 0) {
                cfg.collateralToken.safeTransfer(cfg.feeRecipient, fee);
            }
            if (payout > 0) {
                cfg.collateralToken.safeTransfer(msg.sender, payout);
            }
        }

        emit TokensRedeemed(marketId, msg.sender, winningBurned, losingBurned, fee, payout);
    }

    /// @inheritdoc IMarketFacet
    function enableRefundMode(uint256 marketId) external override {
        LibAccessControl.checkRole(Roles.ADMIN_ROLE);

        LibMarketStorage.MarketData storage m = _market(marketId);
        if (m.eventId != 0) revert Market_PartOfEvent();
        if (m.isResolved) revert Market_AlreadyResolved();
        if (m.refundModeActive) revert Market_RefundModeActive();
        if (block.timestamp < m.endTime) revert Market_NotEnded();

        m.refundModeActive = true;
        m.refundEnabledAt = block.timestamp;
        emit RefundModeEnabled(marketId, msg.sender);
    }

    /// @inheritdoc IMarketFacet
    function refund(uint256 marketId, uint256 yesAmount, uint256 noAmount)
        external
        override
        nonReentrant
        returns (uint256 payout)
    {
        LibPausable.enforceNotPaused(Modules.MARKET);

        LibMarketStorage.MarketData storage m = _market(marketId);
        if (!m.refundModeActive) revert Market_RefundModeInactive();

        uint256 refundable = yesAmount < noAmount ? yesAmount : noAmount;
        if (refundable == 0) revert Market_NothingToRefund();
        payout = refundable;

        IOutcomeToken(m.yesToken).burn(msg.sender, refundable);
        IOutcomeToken(m.noToken).burn(msg.sender, refundable);

        m.totalCollateral -= payout;
        LibConfigStorage.layout().collateralToken.safeTransfer(msg.sender, payout);

        emit MarketRefunded(marketId, msg.sender, refundable, refundable, payout);
    }

    /// @inheritdoc IMarketFacet
    function sweepUnclaimed(uint256 marketId) external override nonReentrant returns (uint256 amount) {
        LibAccessControl.checkRole(Roles.ADMIN_ROLE);

        LibMarketStorage.MarketData storage m = _market(marketId);
        uint256 finalAt = m.isResolved ? m.resolvedAt : (m.refundModeActive ? m.refundEnabledAt : 0);
        if (finalAt == 0) revert Market_NotInFinalState();
        if (block.timestamp < finalAt + GRACE_PERIOD) revert Market_GracePeriodNotElapsed();

        uint256 outstanding;
        if (m.isResolved) {
            address winningToken = m.outcome ? m.yesToken : m.noToken;
            outstanding = IOutcomeToken(winningToken).totalSupply();
        } else {
            // Refund-mode: FINAL-C01 ensures YES.supply == NO.supply so reading
            // either leg yields the per-user claim still outstanding.
            outstanding = IOutcomeToken(m.yesToken).totalSupply();
        }
        if (m.totalCollateral < outstanding) revert Market_AccountingBroken();
        amount = m.totalCollateral - outstanding;
        if (amount == 0) return 0;
        m.totalCollateral -= amount;

        LibConfigStorage.Layout storage cfg = LibConfigStorage.layout();
        cfg.collateralToken.safeTransfer(cfg.feeRecipient, amount);
        emit UnclaimedSwept(marketId, cfg.feeRecipient, amount);
    }

    // -----------------------------------------------------------------------
    // Admin config
    // -----------------------------------------------------------------------

    /// @inheritdoc IMarketFacet
    function approveOracle(address oracle) external override {
        LibAccessControl.checkRole(Roles.ADMIN_ROLE);
        if (oracle == address(0)) revert Market_ZeroAddress();
        LibConfigStorage.Layout storage cfg = LibConfigStorage.layout();
        if (cfg.approvedOracles[oracle]) revert Market_OracleAlreadyApproved();
        cfg.approvedOracles[oracle] = true;
        emit OracleApproved(oracle);
    }

    /// @inheritdoc IMarketFacet
    function revokeOracle(address oracle) external override {
        LibAccessControl.checkRole(Roles.ADMIN_ROLE);
        LibConfigStorage.Layout storage cfg = LibConfigStorage.layout();
        if (!cfg.approvedOracles[oracle]) revert Market_OracleNotApproved();
        cfg.approvedOracles[oracle] = false;
        emit OracleRevoked(oracle);
    }

    /// @inheritdoc IMarketFacet
    function setFeeRecipient(address recipient) external override {
        LibAccessControl.checkRole(Roles.ADMIN_ROLE);
        if (recipient == address(0)) revert Market_ZeroAddress();
        LibConfigStorage.Layout storage cfg = LibConfigStorage.layout();
        address previous = cfg.feeRecipient;
        cfg.feeRecipient = recipient;
        emit FeeRecipientUpdated(previous, recipient);
    }

    /// @inheritdoc IMarketFacet
    function setMarketCreationFee(uint256 fee) external override {
        LibAccessControl.checkRole(Roles.ADMIN_ROLE);
        LibConfigStorage.Layout storage cfg = LibConfigStorage.layout();
        uint256 previous = cfg.marketCreationFee;
        cfg.marketCreationFee = fee;
        emit MarketCreationFeeUpdated(previous, fee);
    }

    /// @inheritdoc IMarketFacet
    function setDefaultPerMarketCap(uint256 cap) external override {
        LibAccessControl.checkRole(Roles.ADMIN_ROLE);
        LibConfigStorage.Layout storage cfg = LibConfigStorage.layout();
        uint256 previous = cfg.defaultPerMarketCap;
        cfg.defaultPerMarketCap = cap;
        emit DefaultPerMarketCapUpdated(previous, cap);
    }

    /// @inheritdoc IMarketFacet
    function setPerMarketCap(uint256 marketId, uint256 cap) external override {
        LibAccessControl.checkRole(Roles.ADMIN_ROLE);
        LibMarketStorage.MarketData storage m = _market(marketId);
        uint256 previous = m.perMarketCap;
        m.perMarketCap = cap;
        emit PerMarketCapUpdated(marketId, previous, cap);
    }

    /// @inheritdoc IMarketFacet
    function setDefaultRedemptionFeeBps(uint256 bps) external override {
        LibAccessControl.checkRole(Roles.ADMIN_ROLE);
        if (bps > MAX_REDEMPTION_FEE_BPS) revert Market_FeeTooHigh();
        LibConfigStorage.Layout storage cfg = LibConfigStorage.layout();
        uint256 previous = cfg.defaultRedemptionFeeBps;
        cfg.defaultRedemptionFeeBps = bps;
        emit DefaultRedemptionFeeUpdated(previous, bps);
    }

    /// @inheritdoc IMarketFacet
    function setPerMarketRedemptionFeeBps(uint256 marketId, uint16 bps) external override {
        LibAccessControl.checkRole(Roles.ADMIN_ROLE);
        if (bps > MAX_REDEMPTION_FEE_BPS) revert Market_FeeTooHigh();
        LibMarketStorage.MarketData storage m = _market(marketId);
        if (m.isResolved || m.refundModeActive) revert Market_FeeLockedAfterFinal();
        m.perMarketRedemptionFeeBps = bps;
        m.redemptionFeeOverridden = true;
        emit PerMarketRedemptionFeeUpdated(marketId, bps, true);
    }

    /// @inheritdoc IMarketFacet
    function clearPerMarketRedemptionFee(uint256 marketId) external override {
        LibAccessControl.checkRole(Roles.ADMIN_ROLE);
        LibMarketStorage.MarketData storage m = _market(marketId);
        if (m.isResolved || m.refundModeActive) revert Market_FeeLockedAfterFinal();
        m.perMarketRedemptionFeeBps = 0;
        m.redemptionFeeOverridden = false;
        emit PerMarketRedemptionFeeUpdated(marketId, 0, false);
    }

    // -----------------------------------------------------------------------
    // Views
    // -----------------------------------------------------------------------

    /// @inheritdoc IMarketFacet
    function getMarket(uint256 marketId) external view override returns (MarketView memory) {
        LibMarketStorage.MarketData storage m = _market(marketId);
        return MarketView({
            question: m.question,
            endTime: m.endTime,
            oracle: m.oracle,
            creator: m.creator,
            yesToken: m.yesToken,
            noToken: m.noToken,
            totalCollateral: m.totalCollateral,
            perMarketCap: m.perMarketCap,
            resolvedAt: m.resolvedAt,
            isResolved: m.isResolved,
            outcome: m.outcome,
            refundModeActive: m.refundModeActive,
            eventId: m.eventId,
            perMarketRedemptionFeeBps: m.perMarketRedemptionFeeBps,
            redemptionFeeOverridden: m.redemptionFeeOverridden
        });
    }

    /// @inheritdoc IMarketFacet
    function getMarketStatus(uint256 marketId)
        external
        view
        override
        returns (address yesToken, address noToken, uint256 endTime, bool isResolved, bool refundModeActive)
    {
        LibMarketStorage.MarketData storage m = _market(marketId);
        return (m.yesToken, m.noToken, m.endTime, m.isResolved, m.refundModeActive);
    }

    /// @inheritdoc IMarketFacet
    function isOracleApproved(address oracle) external view override returns (bool) {
        return LibConfigStorage.layout().approvedOracles[oracle];
    }

    /// @inheritdoc IMarketFacet
    function feeRecipient() external view override returns (address) {
        return LibConfigStorage.layout().feeRecipient;
    }

    /// @inheritdoc IMarketFacet
    function marketCreationFee() external view override returns (uint256) {
        return LibConfigStorage.layout().marketCreationFee;
    }

    /// @inheritdoc IMarketFacet
    function defaultPerMarketCap() external view override returns (uint256) {
        return LibConfigStorage.layout().defaultPerMarketCap;
    }

    /// @inheritdoc IMarketFacet
    function marketCount() external view override returns (uint256) {
        return LibMarketStorage.layout().marketCount;
    }

    /// @inheritdoc IMarketFacet
    function defaultRedemptionFeeBps() external view override returns (uint256) {
        return LibConfigStorage.layout().defaultRedemptionFeeBps;
    }

    /// @inheritdoc IMarketFacet
    function effectiveRedemptionFeeBps(uint256 marketId) external view override returns (uint256) {
        return _effectiveRedemptionFee(_market(marketId));
    }

    // -----------------------------------------------------------------------
    // Internal helpers
    // -----------------------------------------------------------------------

    function _market(uint256 marketId) private view returns (LibMarketStorage.MarketData storage m) {
        m = LibMarketStorage.layout().markets[marketId];
        if (m.creator == address(0)) revert Market_NotFound();
    }

    function _effectiveRedemptionFee(LibMarketStorage.MarketData storage m) private view returns (uint256) {
        return m.redemptionFeeOverridden ? m.perMarketRedemptionFeeBps : m.snapshottedDefaultRedemptionFeeBps;
    }
}
