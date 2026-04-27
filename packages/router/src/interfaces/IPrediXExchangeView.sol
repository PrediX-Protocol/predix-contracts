// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

/// @title IPrediXExchangeView
/// @notice Minimal local copy of the surface of `IPrediXExchange` that `PrediXRouter` uses.
/// @dev Canonical interface lives at `packages/exchange/src/IPrediXExchange.sol`. Copying is
///      required by `SC/CLAUDE.md §2` — the router cannot import cross-package `src/`. This
///      copy includes only `Side`, `fillMarketOrder`, and `previewFillMarketOrder`. Struct
///      layouts and event definitions are intentionally omitted. If the canonical interface
///      changes, update this file and re-verify the router's CLOB helpers.
interface IPrediXExchangeView {
    /// @notice Trading sides for binary outcome markets. Must match the canonical enum
    ///         ordering in `IPrediXExchange.Side` (BUY_YES = 0, SELL_YES = 1, BUY_NO = 2,
    ///         SELL_NO = 3).
    enum Side {
        BUY_YES,
        SELL_YES,
        BUY_NO,
        SELL_NO
    }

    /// @notice Permissionless taker path. Pulls `amountIn` of the input asset from `taker`,
    ///         walks the orderbook up to `maxFills` iterations, returns unused input to the
    ///         taker, and delivers output to `recipient`.
    /// @return filled Total output delivered to `recipient`.
    /// @return cost   Total input consumed from `taker`.
    function fillMarketOrder(
        uint256 marketId,
        Side takerSide,
        uint256 limitPrice,
        uint256 amountIn,
        address taker,
        address recipient,
        uint256 maxFills,
        uint256 deadline
    ) external returns (uint256 filled, uint256 cost);

    /// @notice Simulate `fillMarketOrder` without execution. Safe to call from `eth_call`.
    /// @dev L-07 (audit Pass 2.1): `taker` parameter mirrors the self-match
    ///      filter in `fillMarketOrder` so preview output matches execute when
    ///      caller has resting orders on the opposite side. Pass `address(0)`
    ///      to opt out of the filter.
    function previewFillMarketOrder(
        uint256 marketId,
        Side takerSide,
        uint256 limitPrice,
        uint256 amountIn,
        uint256 maxFills,
        address taker
    ) external view returns (uint256 filled, uint256 cost);
}
