// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {IDiamondCut} from "@predix/shared/interfaces/IDiamondCut.sol";
import {IMarketFacet} from "@predix/shared/interfaces/IMarketFacet.sol";
import {IOutcomeToken} from "@predix/shared/interfaces/IOutcomeToken.sol";
import {Roles} from "@predix/shared/constants/Roles.sol";

import {MarketFacet} from "@predix/diamond/facets/market/MarketFacet.sol";
import {MarketInit} from "@predix/diamond/init/MarketInit.sol";

import {DiamondFixture} from "./DiamondFixture.sol";
import {MockOracle} from "../mocks/MockOracle.sol";
import {MockUSDC} from "../mocks/MockUSDC.sol";

abstract contract MarketFixture is DiamondFixture {
    MarketFacet internal marketFacet;
    MarketInit internal marketInit;
    MockUSDC internal usdc;
    MockOracle internal oracle;

    IMarketFacet internal market;

    address internal feeRecipient = makeAddr("feeRecipient");
    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");
    address internal carol = makeAddr("carol");

    function setUp() public virtual override {
        super.setUp();

        marketFacet = new MarketFacet();
        marketInit = new MarketInit();
        usdc = new MockUSDC();
        oracle = new MockOracle();

        IDiamondCut.FacetCut[] memory cuts = new IDiamondCut.FacetCut[](1);
        cuts[0] = _add(address(marketFacet), _marketSelectors());

        MarketInit.InitArgs memory args = MarketInit.InitArgs({
            collateralToken: address(usdc), feeRecipient: feeRecipient, marketCreationFee: 0, defaultPerMarketCap: 0
        });
        bytes memory initData = abi.encodeCall(MarketInit.init, (args));

        vm.prank(timelock);
        diamondCut.diamondCut(cuts, address(marketInit), initData);

        market = IMarketFacet(address(diamond));

        vm.startPrank(admin);
        market.approveOracle(address(oracle));
        // SPEC-03: createMarket / createEvent are CREATOR_ROLE-gated. Tests
        // drive creation from `alice` by convention (see `_createMarket`
        // below) so the fixture pre-grants the role. Individual tests can
        // revoke or regrant via `accessControl` to exercise the guard.
        accessControl.grantRole(Roles.CREATOR_ROLE, alice);
        vm.stopPrank();
    }

    function _marketSelectors() internal pure returns (bytes4[] memory s) {
        s = new bytes4[](27);
        s[0] = IMarketFacet.createMarket.selector;
        s[1] = IMarketFacet.splitPosition.selector;
        s[2] = IMarketFacet.mergePositions.selector;
        s[3] = IMarketFacet.resolveMarket.selector;
        s[4] = IMarketFacet.emergencyResolve.selector;
        s[5] = IMarketFacet.redeem.selector;
        s[6] = IMarketFacet.enableRefundMode.selector;
        s[7] = IMarketFacet.refund.selector;
        s[8] = IMarketFacet.sweepUnclaimed.selector;
        s[9] = IMarketFacet.approveOracle.selector;
        s[10] = IMarketFacet.revokeOracle.selector;
        s[11] = IMarketFacet.setFeeRecipient.selector;
        s[12] = IMarketFacet.setMarketCreationFee.selector;
        s[13] = IMarketFacet.setDefaultPerMarketCap.selector;
        s[14] = IMarketFacet.setPerMarketCap.selector;
        s[15] = IMarketFacet.getMarket.selector;
        s[16] = IMarketFacet.getMarketStatus.selector;
        s[17] = IMarketFacet.isOracleApproved.selector;
        s[18] = IMarketFacet.feeRecipient.selector;
        s[19] = IMarketFacet.marketCreationFee.selector;
        s[20] = IMarketFacet.defaultPerMarketCap.selector;
        s[21] = IMarketFacet.marketCount.selector;
        s[22] = IMarketFacet.setDefaultRedemptionFeeBps.selector;
        s[23] = IMarketFacet.setPerMarketRedemptionFeeBps.selector;
        s[24] = IMarketFacet.clearPerMarketRedemptionFee.selector;
        s[25] = IMarketFacet.defaultRedemptionFeeBps.selector;
        s[26] = IMarketFacet.effectiveRedemptionFeeBps.selector;
    }

    function _createMarket(uint256 endTime) internal returns (uint256 id) {
        vm.prank(alice);
        id = market.createMarket("Will X happen?", endTime, address(oracle));
    }

    function _fundAndApprove(address user, uint256 amount) internal {
        usdc.mint(user, amount);
        vm.prank(user);
        usdc.approve(address(diamond), type(uint256).max);
    }

    function _split(address user, uint256 marketId, uint256 amount) internal {
        _fundAndApprove(user, amount);
        vm.prank(user);
        market.splitPosition(marketId, amount);
    }

    function _yes(uint256 marketId) internal view returns (IOutcomeToken) {
        return IOutcomeToken(market.getMarket(marketId).yesToken);
    }

    function _no(uint256 marketId) internal view returns (IOutcomeToken) {
        return IOutcomeToken(market.getMarket(marketId).noToken);
    }
}
