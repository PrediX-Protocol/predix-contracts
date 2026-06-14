// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

/// @title LibBuilderFeeStorage
/// @notice ERC-7201 namespaced storage for the builder-fee ledger. Kept OUT of
///         `ExchangeStorage` so appending state never shifts the live proxy's
///         `paused` slot (PrediXExchange.sol:35, slot 8).
library LibBuilderFeeStorage {
    /// @dev keccak256(abi.encode(uint256(keccak256("predix.exchange.builderfee.v1")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 internal constant SLOT = 0xa35e7c8baa3c0cb8b6083e44aeeab8e83487b5eefb283554ddf6e85e17c79000;

    struct Layout {
        address builderRegistry; // set via setBuilderRegistry (admin)
        mapping(bytes32 code => uint256) accrued; // claimable USDC per builder code
        mapping(bytes32 orderId => uint256) makerFeeLocked; // prefunded BUY maker-fee budget
        mapping(bytes32 orderId => uint16) orderMakerBps; // makerBps snapshot at placeOrder
    }

    function layout() internal pure returns (Layout storage l) {
        bytes32 s = SLOT;
        assembly {
            l.slot := s
        }
    }
}
