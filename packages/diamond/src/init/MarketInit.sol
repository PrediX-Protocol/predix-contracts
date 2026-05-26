// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";

import {IMarketFacet} from "@predix/shared/interfaces/IMarketFacet.sol";
import {IEventFacet} from "@predix/shared/interfaces/IEventFacet.sol";

import {LibConfigStorage} from "@predix/diamond/libraries/LibConfigStorage.sol";
import {LibDiamondStorage} from "@predix/diamond/libraries/LibDiamondStorage.sol";

/// @title MarketInit
/// @notice One-shot bootstrap for the market facet: stores collateral token, fee
///         recipient, fee level, default per-market cap, the v1.3 OutcomeTokenClone
///         master impl, and registers `IMarketFacet` + `IEventFacet` in the ERC-165
///         supported-interfaces map.
/// @dev Designed to be delegatecalled from the `diamondCut` that adds `MarketFacet`
///      and `EventFacet` together (see `DiamondDeployLib.wireMarketAndEvent`), so
///      both interface ids are advertised the moment their selectors become
///      routable. Re-runs are blocked by a guard on its own dedicated storage slot.
///
///      v1.3 introduced `outcomeTokenImpl` storage; `initWithOutcomeImpl` is the
///      canonical entry point for fresh-diamond deploys, so the master clone target
///      is set atomically with the rest of the market-facet wiring. The legacy
///      `init(args)` is retained for cuts that *only* want to (re)wire the market
///      config — but using it on a fresh diamond will leave `outcomeTokenImpl`
///      unset and the first `createMarket` will revert with
///      `Market_OutcomeTokenImplNotSet` until an ADMIN calls `setOutcomeTokenImpl`.
contract MarketInit {
    error MarketInit_AlreadyInitialized();
    error MarketInit_ZeroCollateral();
    error MarketInit_ZeroFeeRecipient();
    /// @notice Reverts when the collateral token does not report 6 decimals. The
    ///         outcome tokens are fixed at 6 decimals and the AMM/router price math
    ///         assumes a 1e6 unit, so a mismatched collateral would silently break
    ///         pricing despite split/merge staying 1:1.
    error MarketInit_CollateralNotSixDecimals();
    /// @notice Reverts when `initWithOutcomeImpl` is called with a zero address
    ///         for the OutcomeTokenClone master. Catches mis-wiring at cut time
    ///         instead of letting the first `createMarket` revert post-deploy.
    error MarketInit_ZeroOutcomeImpl();

    bytes32 private constant INITIALIZED_SLOT = keccak256("predix.storage.marketinit.v1");

    struct InitArgs {
        address collateralToken;
        address feeRecipient;
        uint256 marketCreationFee;
        uint256 defaultPerMarketCap;
    }

    /// @notice Legacy entry point — wires core market config but leaves
    ///         `outcomeTokenImpl` unset.
    /// @dev    Prefer `initWithOutcomeImpl` for v1.3+ fresh deploys. This overload
    ///         is kept for cut shapes that (1) don't need to (re)set the impl,
    ///         or (2) follow up with `MarketFacet.setOutcomeTokenImpl(...)` via
    ///         a separate ADMIN tx.
    function init(InitArgs calldata args) external {
        _init(args);
    }

    /// @notice Atomic v1.3 entry point — wires market config AND the
    ///         OutcomeTokenClone master pointer in a single diamondCut.
    /// @dev    Must be the `_init` calldata when adding `MarketFacet` for the
    ///         first time on a fresh diamond. With this path, the first
    ///         `createMarket(...)` after the cut succeeds; without it the first
    ///         call reverts with `Market_OutcomeTokenImplNotSet`.
    /// @param  args              standard market-init args
    /// @param  outcomeTokenImpl_ deployed `OutcomeTokenClone` master address
    function initWithOutcomeImpl(InitArgs calldata args, address outcomeTokenImpl_) external {
        if (outcomeTokenImpl_ == address(0)) revert MarketInit_ZeroOutcomeImpl();
        _init(args);
        LibConfigStorage.layout().outcomeTokenImpl = outcomeTokenImpl_;
    }

    function _init(InitArgs calldata args) private {
        if (_isInitialized()) revert MarketInit_AlreadyInitialized();
        if (args.collateralToken == address(0)) revert MarketInit_ZeroCollateral();
        if (args.feeRecipient == address(0)) revert MarketInit_ZeroFeeRecipient();
        if (IERC20Metadata(args.collateralToken).decimals() != 6) revert MarketInit_CollateralNotSixDecimals();
        _markInitialized();

        LibConfigStorage.Layout storage cfg = LibConfigStorage.layout();
        cfg.collateralToken = IERC20(args.collateralToken);
        cfg.feeRecipient = args.feeRecipient;
        cfg.marketCreationFee = args.marketCreationFee;
        cfg.defaultPerMarketCap = args.defaultPerMarketCap;

        LibDiamondStorage.Layout storage ds = LibDiamondStorage.layout();
        ds.supportedInterfaces[type(IMarketFacet).interfaceId] = true;
        ds.supportedInterfaces[type(IEventFacet).interfaceId] = true;
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
