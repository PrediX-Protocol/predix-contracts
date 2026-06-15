// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

/// @dev Settable `feeOf` stub matching IBuilderRegistry's read surface. Tests register a
///      code → (takerBps, makerBps, recipient). The router only reads `feeOf(code).takerBps`.
contract MockBuilderRegistry {
    struct B {
        uint16 takerBps;
        uint16 makerBps;
        address recipient;
    }

    mapping(bytes32 => B) internal _b;

    function setBuilder(bytes32 code, uint16 takerBps, uint16 makerBps, address recipient) external {
        _b[code] = B({takerBps: takerBps, makerBps: makerBps, recipient: recipient});
    }

    function feeOf(bytes32 code) external view returns (uint16 takerBps, uint16 makerBps, address recipient) {
        B storage b = _b[code];
        return (b.takerBps, b.makerBps, b.recipient);
    }

    function recipientOf(bytes32 code) external view returns (address) {
        return _b[code].recipient;
    }

    function exists(bytes32 code) external view returns (bool) {
        return _b[code].recipient != address(0);
    }
}
