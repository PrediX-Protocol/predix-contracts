// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

interface IMockFacet {
    function mockReadValue() external view returns (uint256);
    function mockWriteValue(uint256 v) external;
}

contract MockFacetA is IMockFacet {
    bytes32 private constant SLOT = keccak256("predix.test.mock.v1");

    function mockReadValue() external view override returns (uint256 v) {
        bytes32 slot = SLOT;
        assembly {
            v := sload(slot)
        }
    }

    function mockWriteValue(uint256 v) external override {
        bytes32 slot = SLOT;
        assembly {
            sstore(slot, v)
        }
    }
}

contract MockFacetB is IMockFacet {
    bytes32 private constant SLOT = keccak256("predix.test.mock.v1");

    function mockReadValue() external view override returns (uint256 v) {
        bytes32 slot = SLOT;
        assembly {
            v := sload(slot)
        }
    }

    function mockWriteValue(uint256 v) external override {
        bytes32 slot = SLOT;
        uint256 next = v + 1;
        assembly {
            sstore(slot, next)
        }
    }
}
