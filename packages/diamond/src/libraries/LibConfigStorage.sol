// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @title LibConfigStorage
/// @notice Diamond storage layout for protocol-wide configuration shared by every facet
///         that handles money: collateral token, fee recipient, market creation fee,
///         default per-market cap, oracle whitelist.
library LibConfigStorage {
    bytes32 internal constant SLOT = keccak256("predix.storage.config.v1");

    struct Layout {
        IERC20 collateralToken;
        address feeRecipient;
        uint256 marketCreationFee;
        uint256 defaultPerMarketCap;
        mapping(address => bool) approvedOracles;
        /// @dev Append-only field added in v1.2 to back the protocol redemption fee.
        ///      Value is in basis points (10000 = 100%); hard-capped at
        ///      `MAX_REDEMPTION_FEE_BPS` by `MarketFacet.setDefaultRedemptionFeeBps`.
        ///      0 = fee disabled (the launch default).
        uint256 defaultRedemptionFeeBps;
        /// @dev Append-only field added in v1.3 — master implementation address
        ///      for `OutcomeTokenClone` (EIP-1167 minimal proxy template).
        ///      `LibMarket.create` clones this address for every new YES/NO leg,
        ///      cutting per-market deploy gas by ~76% vs `new OutcomeToken(...)`.
        ///      0 = clone path disabled → `LibMarket.create` reverts. Admin sets via
        ///      `MarketFacet.setOutcomeTokenImpl`. NEVER REORDER — namespaced
        ///      storage append-only contract.
        address outcomeTokenImpl;
    }

    function layout() internal pure returns (Layout storage l) {
        bytes32 slot = SLOT;
        assembly ("memory-safe") {
            l.slot := slot
        }
    }
}
