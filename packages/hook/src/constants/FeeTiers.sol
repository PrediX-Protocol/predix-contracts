// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

/// @title FeeTiers
/// @notice Dynamic-fee schedule and hookData layout constants for the PrediX hook.
/// @dev Fees are expressed in Uniswap v4 pip units (1 pip = 1e-6). The tiers below
///      are applied by `PrediXHookV2._beforeSwap` based on time-to-expiry, widening
///      the spread as a market approaches resolution to discourage late-stage
///      informed flow.
library FeeTiers {
    /// @notice 50 bps. Applied while expiry is more than `LONG_WINDOW` away.
    uint24 internal constant FEE_NORMAL = 5_000;
    /// @notice 100 bps. Applied while expiry is within `LONG_WINDOW`.
    uint24 internal constant FEE_MEDIUM = 10_000;
    /// @notice 200 bps. Applied while expiry is within `MID_WINDOW`.
    uint24 internal constant FEE_HIGH = 20_000;
    /// @notice 500 bps. Applied within `SHORT_WINDOW` and after expiry.
    uint24 internal constant FEE_VERY_HIGH = 50_000;

    uint256 internal constant LONG_WINDOW = 7 days;
    uint256 internal constant MID_WINDOW = 3 days;
    uint256 internal constant SHORT_WINDOW = 1 days;

    /// @notice hookData byte offsets. Layout is packed (NO ABI padding):
    ///         [0:20)  = referrer address  (or `address(0)` to skip)
    ///         [20:40) = uint160 maxSqrtPriceX96  (or `0` to skip the slippage check)
    /// @dev Encode in a caller (router or test fixture):
    /// ```solidity
    /// bytes memory hookData = abi.encodePacked(
    ///     referrer,                  // 20 bytes — address(0) opts out of referral telemetry
    ///     uint160(maxSqrtPriceX96)   // 20 bytes — 0 opts out of post-swap slippage check
    /// );
    /// // Total length: 40 bytes. DO NOT use abi.encode — it would pad each field to 32 bytes.
    /// ```
    /// `hookData.length < 20` skips the referral path. `hookData.length < 40` skips the
    /// slippage path. Empty `hookData` is valid and incurs no extra checks.
    uint256 internal constant HOOKDATA_REFERRER_END = 20;
    uint256 internal constant HOOKDATA_SLIPPAGE_END = 40;

    /// @notice Full 1.0 price in 6-decimal pip units. Clamp ceiling for YES price.
    uint256 internal constant PRICE_UNIT = 1e6;
}
