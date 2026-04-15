// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Strings} from "@openzeppelin/contracts/utils/Strings.sol";

import {IMarketFacet} from "@predix/shared/interfaces/IMarketFacet.sol";
import {OutcomeToken} from "@predix/shared/tokens/OutcomeToken.sol";

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

    /// @notice Create a new binary market. Caller handles all input validation.
    /// @param question  Market question. Caller must ensure non-empty.
    /// @param endTime   Unix timestamp after which the market accepts no more splits.
    /// @param oracle    Oracle address for the market. May be `address(0)` for event
    ///                  children — resolution then comes exclusively from `EventFacet`.
    /// @param eventId   `0` for standalone markets; non-zero for event children.
    /// @return marketId Newly assigned market id (1-indexed, monotonic).
    function create(string memory question, uint256 endTime, address oracle, uint256 eventId)
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

        string memory idStr = Strings.toString(marketId);
        OutcomeToken yes = new OutcomeToken(
            address(this), marketId, true, string.concat("PrediX YES #", idStr), string.concat("pxY-", idStr)
        );
        OutcomeToken no = new OutcomeToken(
            address(this), marketId, false, string.concat("PrediX NO #", idStr), string.concat("pxN-", idStr)
        );

        LibMarketStorage.MarketData storage m = ms.markets[marketId];
        m.question = question;
        m.endTime = endTime;
        m.oracle = oracle;
        m.creator = msg.sender;
        m.yesToken = address(yes);
        m.noToken = address(no);
        m.eventId = eventId;
        m.snapshottedDefaultRedemptionFeeBps = uint16(cfg.defaultRedemptionFeeBps);

        emit IMarketFacet.MarketCreated(marketId, msg.sender, oracle, address(yes), address(no), endTime, question);
    }
}
