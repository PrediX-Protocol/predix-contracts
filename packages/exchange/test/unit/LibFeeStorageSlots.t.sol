// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import {Test} from "forge-std/Test.sol";
import {LibBuilderFeeStorage} from "../../src/libraries/LibBuilderFeeStorage.sol";
import {LibProtocolFeeStorage} from "../../src/libraries/LibProtocolFeeStorage.sol";

contract LibFeeStorageSlotsTest is Test {
    /// @dev keccak256(abi.encode(uint256(keccak256(ns)) - 1)) & ~bytes32(uint256(0xff))
    function _erc7201(string memory ns) internal pure returns (bytes32) {
        return keccak256(abi.encode(uint256(keccak256(bytes(ns))) - 1)) & ~bytes32(uint256(0xff));
    }

    function test_builderFeeSlot_matchesFormula() public pure {
        assertEq(LibBuilderFeeStorage.SLOT, _erc7201("predix.exchange.builderfee.v1"));
        assertEq(LibBuilderFeeStorage.SLOT, 0xa35e7c8baa3c0cb8b6083e44aeeab8e83487b5eefb283554ddf6e85e17c79000);
    }

    function test_protocolFeeSlot_matchesFormula() public pure {
        assertEq(LibProtocolFeeStorage.SLOT, _erc7201("predix.exchange.protocolfee.v1"));
        assertEq(LibProtocolFeeStorage.SLOT, 0xc2cb872bc9a3ca3724b5bbf38ae11b13de41b893f6d0b580ab2182f4ff581d00);
    }

    function test_slots_distinct_andLow8BitsZero() public pure {
        assertTrue(LibBuilderFeeStorage.SLOT != LibProtocolFeeStorage.SLOT);
        assertEq(uint256(LibBuilderFeeStorage.SLOT) & 0xff, 0);
        assertEq(uint256(LibProtocolFeeStorage.SLOT) & 0xff, 0);
    }
}
