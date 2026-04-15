// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

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
    }

    function layout() internal pure returns (Layout storage l) {
        bytes32 slot = SLOT;
        assembly ("memory-safe") {
            l.slot := slot
        }
    }
}
