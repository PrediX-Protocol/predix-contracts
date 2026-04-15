// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {IMarketFacet} from "@predix/shared/interfaces/IMarketFacet.sol";

import {LibConfigStorage} from "@predix/diamond/libraries/LibConfigStorage.sol";
import {LibDiamondStorage} from "@predix/diamond/libraries/LibDiamondStorage.sol";

/// @title MarketInit
/// @notice One-shot bootstrap for the market facet: stores collateral token, fee
///         recipient, fee level, default per-market cap, and registers `IMarketFacet`
///         in the ERC-165 supported-interfaces map.
/// @dev Designed to be delegatecalled from a `diamondCut` that adds `MarketFacet`.
///      Re-runs are blocked by a guard on its own dedicated storage slot.
contract MarketInit {
    error MarketInit_AlreadyInitialized();
    error MarketInit_ZeroCollateral();
    error MarketInit_ZeroFeeRecipient();

    bytes32 private constant INITIALIZED_SLOT = keccak256("predix.storage.marketinit.v1");

    struct InitArgs {
        address collateralToken;
        address feeRecipient;
        uint256 marketCreationFee;
        uint256 defaultPerMarketCap;
    }

    function init(InitArgs calldata args) external {
        if (_isInitialized()) revert MarketInit_AlreadyInitialized();
        if (args.collateralToken == address(0)) revert MarketInit_ZeroCollateral();
        if (args.feeRecipient == address(0)) revert MarketInit_ZeroFeeRecipient();
        _markInitialized();

        LibConfigStorage.Layout storage cfg = LibConfigStorage.layout();
        cfg.collateralToken = IERC20(args.collateralToken);
        cfg.feeRecipient = args.feeRecipient;
        cfg.marketCreationFee = args.marketCreationFee;
        cfg.defaultPerMarketCap = args.defaultPerMarketCap;

        LibDiamondStorage.layout().supportedInterfaces[type(IMarketFacet).interfaceId] = true;
    }

    function _isInitialized() private view returns (bool flag) {
        bytes32 s = INITIALIZED_SLOT;
        assembly ("memory-safe") {
            flag := sload(s)
        }
    }

    function _markInitialized() private {
        bytes32 s = INITIALIZED_SLOT;
        assembly ("memory-safe") {
            sstore(s, 1)
        }
    }
}
