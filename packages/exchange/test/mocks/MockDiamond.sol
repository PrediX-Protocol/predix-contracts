// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {IMarketFacet} from "@predix/shared/interfaces/IMarketFacet.sol";
import {IPausableFacet} from "@predix/shared/interfaces/IPausableFacet.sol";
import {IOutcomeToken} from "@predix/shared/interfaces/IOutcomeToken.sol";
import {OutcomeToken} from "@predix/shared/tokens/OutcomeToken.sol";

/// @title MockDiamond
/// @notice Minimal Diamond stand-in for Exchange smoke tests.
/// @dev Implements only the surface Exchange touches: getMarket / splitPosition /
///      mergePositions / isModulePaused / hasRole. Real OutcomeToken instances are
///      deployed with this contract as `factory` so the onlyFactory invariant matches
///      production behaviour.
contract MockDiamond {
    using SafeERC20 for IERC20;

    IERC20 public immutable usdc;

    mapping(uint256 => IMarketFacet.MarketView) private _markets;
    mapping(bytes32 => bool) private _modulePaused;
    mapping(bytes32 => mapping(address => bool)) private _roles;
    bool private _globalPaused;

    constructor(address usdc_) {
        usdc = IERC20(usdc_);
    }

    // ======== Test helpers ========

    /// @notice Create a market backed by real `OutcomeToken` instances. Returns the
    ///         deployed yes / no addresses so the test can mint / approve.
    function createMarket(uint256 marketId, uint256 endTime, address creator)
        external
        returns (address yesToken, address noToken)
    {
        OutcomeToken yes = new OutcomeToken(address(this), marketId, true, "YES", "YES");
        OutcomeToken no = new OutcomeToken(address(this), marketId, false, "NO", "NO");
        yesToken = address(yes);
        noToken = address(no);

        _markets[marketId] = IMarketFacet.MarketView({
            question: "",
            endTime: endTime,
            oracle: address(0),
            creator: creator,
            yesToken: yesToken,
            noToken: noToken,
            totalCollateral: 0,
            perMarketCap: 0,
            resolvedAt: 0,
            isResolved: false,
            outcome: false,
            refundModeActive: false,
            eventId: 0,
            perMarketRedemptionFeeBps: 0,
            redemptionFeeOverridden: false
        });
    }

    function setMarketResolved(uint256 marketId, bool resolved) external {
        _markets[marketId].isResolved = resolved;
    }

    function setMarketRefundMode(uint256 marketId, bool active) external {
        _markets[marketId].refundModeActive = active;
    }

    function setMarketEndTime(uint256 marketId, uint256 endTime) external {
        _markets[marketId].endTime = endTime;
    }

    function setModulePaused(bytes32 moduleId, bool value) external {
        _modulePaused[moduleId] = value;
    }

    function setGlobalPaused(bool value) external {
        _globalPaused = value;
    }

    function grantRole(bytes32 role, address account) external {
        _roles[role][account] = true;
    }

    // ======== IMarketFacet (subset) ========

    function getMarket(uint256 marketId) external view returns (IMarketFacet.MarketView memory) {
        IMarketFacet.MarketView memory m = _markets[marketId];
        if (m.creator == address(0)) revert IMarketFacet.Market_NotFound();
        return m;
    }

    function splitPosition(uint256 marketId, uint256 amount) external {
        IMarketFacet.MarketView storage m = _markets[marketId];
        usdc.safeTransferFrom(msg.sender, address(this), amount);
        IOutcomeToken(m.yesToken).mint(msg.sender, amount);
        IOutcomeToken(m.noToken).mint(msg.sender, amount);
        m.totalCollateral += amount;
    }

    function mergePositions(uint256 marketId, uint256 amount) external {
        IMarketFacet.MarketView storage m = _markets[marketId];
        IOutcomeToken(m.yesToken).burn(msg.sender, amount);
        IOutcomeToken(m.noToken).burn(msg.sender, amount);
        m.totalCollateral -= amount;
        usdc.safeTransfer(msg.sender, amount);
    }

    // ======== IPausableFacet (subset) ========

    function paused() external view returns (bool) {
        return _globalPaused;
    }

    function isModulePaused(bytes32 moduleId) external view returns (bool) {
        return _globalPaused || _modulePaused[moduleId];
    }

    // ======== IAccessControlFacet (subset) ========

    function hasRole(bytes32 role, address account) external view returns (bool) {
        return _roles[role][account];
    }
}
