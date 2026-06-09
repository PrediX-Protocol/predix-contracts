// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Strings} from "@openzeppelin/contracts/utils/Strings.sol";
import {Clones} from "@openzeppelin/contracts/proxy/Clones.sol";

import {IMarketFacet} from "@predix/shared/interfaces/IMarketFacet.sol";
import {OutcomeTokenClone} from "@predix/shared/tokens/OutcomeTokenClone.sol";

import {LibConfigStorage} from "@predix/diamond/libraries/LibConfigStorage.sol";
import {LibMarketStorage} from "@predix/diamond/libraries/LibMarketStorage.sol";

/// @title LibMarket
/// @notice Internal creation primitive shared by `MarketFacet.createMarket` (standalone
///         binary markets) and `EventFacet.createEvent` (event child markets).
/// @dev Trusted: callers MUST validate `question`, `endTime`, and (when applicable)
///      `oracle` approval before calling. This library just charges the protocol fee,
///      deploys the YES/NO outcome token pair, writes `MarketData`, and emits
///      `IMarketFacet.MarketCreated`. `msg.sender` inside an internal library call is
///      the original caller of whichever facet invoked it, so the fee is pulled from
///      the user who called `createMarket` / `createEvent`.
library LibMarket {
    using SafeERC20 for IERC20;

    /// @notice Hard ceiling on redemption fees (1000 bps = 10%). Single source of truth shared by
    ///         `MarketFacet` and `EventFacet` (keyti-fqn8).
    uint256 internal constant MAX_REDEMPTION_FEE_BPS = 1000;

    /// @notice Create a new binary market. Caller handles all input validation.
    /// @param question  Market question. Caller must ensure non-empty.
    /// @param endTime   Unix timestamp after which the market accepts no more splits.
    /// @param oracle    Oracle address for the market. May be `address(0)` for event
    ///                  children — resolution then comes exclusively from `EventFacet`.
    /// @param eventId   `0` for standalone markets; non-zero for event children.
    /// @param feeBps    Redemption fee (bps) to snapshot for this market — caller passes the system
    ///                  default or an explicit fee (already bounded by the caller to `MAX_REDEMPTION_FEE_BPS`).
    /// @return marketId Newly assigned market id (1-indexed, monotonic).
    function create(string memory question, uint256 endTime, address oracle, uint256 eventId, uint256 feeBps)
        internal
        returns (uint256 marketId)
    {
        LibConfigStorage.Layout storage cfg = LibConfigStorage.layout();

        uint256 fee = cfg.marketCreationFee;
        if (fee > 0) {
            cfg.collateralToken.safeTransferFrom(msg.sender, cfg.feeRecipient, fee);
        }

        LibMarketStorage.Layout storage ms = LibMarketStorage.layout();
        marketId = ++ms.marketCount;

        // v1.3 path: clone the configured OutcomeTokenClone master via EIP-1167
        // minimal proxy. Cuts per-market token-deploy gas ~76% vs `new OutcomeToken(...)`.
        // Admin must call `MarketFacet.setOutcomeTokenImpl` once before any market is
        // ever created on a fresh diamond; the revert here is the single fail-fast
        // gate that catches a missed init.
        address impl = cfg.outcomeTokenImpl;
        if (impl == address(0)) revert IMarketFacet.Market_OutcomeTokenImplNotSet();

        string memory idStr = Strings.toString(marketId);
        address yesAddr = Clones.clone(impl);
        address noAddr = Clones.clone(impl);
        OutcomeTokenClone(yesAddr)
            .initialize(marketId, true, string.concat("PrediX YES #", idStr), string.concat("pxY-", idStr));
        OutcomeTokenClone(noAddr)
            .initialize(marketId, false, string.concat("PrediX NO #", idStr), string.concat("pxN-", idStr));

        LibMarketStorage.MarketData storage m = ms.markets[marketId];
        m.question = question;
        m.endTime = endTime;
        m.oracle = oracle;
        m.creator = msg.sender;
        m.yesToken = yesAddr;
        m.noToken = noAddr;
        m.eventId = eventId;
        if (feeBps > type(uint16).max) revert IMarketFacet.Market_FeeTooHigh();
        m.snapshottedDefaultRedemptionFeeBps = uint16(feeBps);

        emit IMarketFacet.MarketCreated(
            marketId, msg.sender, oracle, yesAddr, noAddr, endTime, question, uint16(feeBps)
        );
    }

    /// @notice Resolve a market's effective redemption fee (bps), clamped to the hard cap.
    /// @dev Override wins over the snapshotted default; the read-time clamp guarantees a stored value
    ///      from before the 1500->1000 cap drop can never charge above `MAX_REDEMPTION_FEE_BPS`. Single
    ///      read path shared by `MarketFacet` (binary redeem + view) and `EventFacet.redeemEvent`.
    function effectiveRedemptionFee(LibMarketStorage.MarketData storage m) internal view returns (uint16) {
        uint16 raw = m.redemptionFeeOverridden ? m.perMarketRedemptionFeeBps : m.snapshottedDefaultRedemptionFeeBps;
        return raw > MAX_REDEMPTION_FEE_BPS ? uint16(MAX_REDEMPTION_FEE_BPS) : raw;
    }
}
