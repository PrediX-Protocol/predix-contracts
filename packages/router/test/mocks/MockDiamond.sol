// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IMarketFacet} from "@predix/shared/interfaces/IMarketFacet.sol";
import {IPausableFacet} from "@predix/shared/interfaces/IPausableFacet.sol";
import {Modules} from "@predix/shared/constants/Modules.sol";
import {MockERC20} from "./MockERC20.sol";

/// @dev Minimal diamond stub: implements the subset of IMarketFacet/IPausableFacet that the
///      router reads. Markets are configured via `setMarket`. Split/merge mint/burn directly
///      to keep tests focused on router logic.
contract MockDiamond {
    struct MarketConfig {
        address yesToken;
        address noToken;
        uint256 endTime;
        bool isResolved;
        bool refundModeActive;
        uint256 totalCollateral;
        uint256 perMarketCap;
        address creator;
    }

    address public immutable usdc;
    mapping(uint256 => MarketConfig) internal _markets;
    mapping(bytes32 => bool) internal _modulePaused;
    bool internal _globalPaused;
    /// @dev L-01 (audit Pass 2.1): MockDiamond must mirror the diamond's
    ///      `defaultPerMarketCap()` view so router's effective-cap formula
    ///      (perMarketCap > 0 ? perMarketCap : default) can be exercised.
    uint256 internal _defaultPerMarketCap;

    constructor(address _usdc) {
        usdc = _usdc;
    }

    // ---- Test setters ----
    function setMarket(
        uint256 marketId,
        address yesToken,
        address noToken,
        uint256 endTime,
        bool isResolved,
        bool refundModeActive
    ) external {
        MarketConfig storage m = _markets[marketId];
        m.yesToken = yesToken;
        m.noToken = noToken;
        m.endTime = endTime;
        m.isResolved = isResolved;
        m.refundModeActive = refundModeActive;
        m.creator = address(this);
    }

    function setPerMarketCap(uint256 marketId, uint256 cap) external {
        _markets[marketId].perMarketCap = cap;
    }

    function setDefaultPerMarketCap(uint256 cap) external {
        _defaultPerMarketCap = cap;
    }

    function defaultPerMarketCap() external view returns (uint256) {
        return _defaultPerMarketCap;
    }

    /// @dev Test helper: seed `totalCollateral` without running `splitPosition`. Used when a
    ///      unit test wants `mergePositions` to succeed without a prior split step.
    function seedCollateral(uint256 marketId, uint256 amount) external {
        _markets[marketId].totalCollateral += amount;
    }

    function setModulePaused(bytes32 moduleId, bool p) external {
        _modulePaused[moduleId] = p;
    }

    function setGlobalPaused(bool p) external {
        _globalPaused = p;
    }

    // ---- IPausableFacet subset ----
    function isModulePaused(bytes32 moduleId) external view returns (bool) {
        return _globalPaused || _modulePaused[moduleId];
    }

    function paused() external view returns (bool) {
        return _globalPaused;
    }

    // ---- IMarketFacet subset ----
    function getMarketStatus(uint256 marketId)
        external
        view
        returns (address yesToken, address noToken, uint256 endTime, bool isResolved, bool refundModeActive)
    {
        MarketConfig storage m = _markets[marketId];
        return (m.yesToken, m.noToken, m.endTime, m.isResolved, m.refundModeActive);
    }

    function getMarket(uint256 marketId) external view returns (IMarketFacet.MarketView memory v) {
        MarketConfig storage m = _markets[marketId];
        v.yesToken = m.yesToken;
        v.noToken = m.noToken;
        v.endTime = m.endTime;
        v.isResolved = m.isResolved;
        v.refundModeActive = m.refundModeActive;
        v.totalCollateral = m.totalCollateral;
        v.perMarketCap = m.perMarketCap;
        v.creator = m.creator;
    }

    /// @dev splitPosition pulls USDC and mints matching YES+NO via the mock outcome tokens.
    function splitPosition(uint256 marketId, uint256 amount) external {
        MarketConfig storage m = _markets[marketId];
        require(m.yesToken != address(0), "market missing");
        if (m.perMarketCap != 0) {
            require(m.totalCollateral + amount <= m.perMarketCap, "cap");
        }
        m.totalCollateral += amount;
        IERC20(usdc).transferFrom(msg.sender, address(this), amount);
        MockERC20(m.yesToken).mint(msg.sender, amount);
        MockERC20(m.noToken).mint(msg.sender, amount);
    }

    /// @dev mergePositions burns YES+NO and returns USDC.
    function mergePositions(uint256 marketId, uint256 amount) external {
        MarketConfig storage m = _markets[marketId];
        require(m.yesToken != address(0), "market missing");
        MockERC20(m.yesToken).burn(msg.sender, amount);
        MockERC20(m.noToken).burn(msg.sender, amount);
        m.totalCollateral -= amount;
        IERC20(usdc).transfer(msg.sender, amount);
    }
}
