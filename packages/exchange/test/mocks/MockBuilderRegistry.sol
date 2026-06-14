// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import {IBuilderRegistry} from "@predix/shared/interfaces/IBuilderRegistry.sol";

/// @notice Minimal IBuilderRegistry stub: settable per-code rates + recipient.
contract MockBuilderRegistry {
    mapping(bytes32 => uint16) public takerBpsOf;
    mapping(bytes32 => uint16) public makerBpsOf;
    mapping(bytes32 => address) public recipients;

    function set(bytes32 code, uint16 takerBps, uint16 makerBps, address recipient) external {
        takerBpsOf[code] = takerBps;
        makerBpsOf[code] = makerBps;
        recipients[code] = recipient;
    }

    function feeOf(bytes32 code) external view returns (uint16 takerBps, uint16 makerBps, address recipient) {
        return (takerBpsOf[code], makerBpsOf[code], recipients[code]);
    }

    function recipientOf(bytes32 code) external view returns (address) {
        return recipients[code];
    }
}
