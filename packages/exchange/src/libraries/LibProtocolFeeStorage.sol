// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

/// @title LibProtocolFeeStorage
/// @notice ERC-7201 namespaced storage for the protocol-fee ledger (treasury
///         recipient + accrued treasury cut + per-order placer reserve). Separate
///         namespace from the builder fee; both kept OUT of `ExchangeStorage`.
library LibProtocolFeeStorage {
    /// @dev keccak256(abi.encode(uint256(keccak256("predix.exchange.protocolfee.v1")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 internal constant SLOT = 0xc2cb872bc9a3ca3724b5bbf38ae11b13de41b893f6d0b580ab2182f4ff581d00;

    struct Layout {
        address protocolFeeRecipient; // set via setProtocolFeeRecipient (admin); 0 at launch
        uint256 accruedProtocolFee; // treasury cut T accrued until sweepProtocolFee()
        mapping(bytes32 orderId => uint256) placerProtocolFeeBudget; // BUY placer reserve
    }

    function layout() internal pure returns (Layout storage l) {
        bytes32 s = SLOT;
        assembly {
            l.slot := s
        }
    }
}
