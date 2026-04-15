// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {IAccessControlFacet} from "@predix/shared/interfaces/IAccessControlFacet.sol";
import {IMarketFacet} from "@predix/shared/interfaces/IMarketFacet.sol";
import {IOutcomeToken} from "@predix/shared/interfaces/IOutcomeToken.sol";
import {IPausableFacet} from "@predix/shared/interfaces/IPausableFacet.sol";
import {Modules} from "@predix/shared/constants/Modules.sol";
import {Roles} from "@predix/shared/constants/Roles.sol";

import {MarketFixture} from "../utils/MarketFixture.sol";
import {MockOracle} from "../mocks/MockOracle.sol";

contract MarketCreateTest is MarketFixture {
    function test_CreateMarket_HappyPath_StoresData() public {
        uint256 endTime = block.timestamp + 7 days;
        uint256 id = _createMarket(endTime);

        assertEq(id, 1);
        IMarketFacet.MarketView memory m = market.getMarket(id);
        assertEq(m.question, "Will X happen?");
        assertEq(m.endTime, endTime);
        assertEq(m.oracle, address(oracle));
        assertEq(m.creator, alice);
        assertEq(m.totalCollateral, 0);
        assertFalse(m.isResolved);
        assertFalse(m.refundModeActive);
    }

    function test_CreateMarket_DeploysTwoTokensWithRightFlags() public {
        uint256 id = _createMarket(block.timestamp + 1 days);
        IOutcomeToken y = _yes(id);
        IOutcomeToken n = _no(id);
        assertEq(y.factory(), address(diamond));
        assertEq(y.marketId(), id);
        assertTrue(y.isYes());
        assertEq(n.factory(), address(diamond));
        assertFalse(n.isYes());
        assertEq(y.decimals(), 6);
    }

    function test_CreateMarket_IncrementsCount() public {
        _createMarket(block.timestamp + 1 days);
        _createMarket(block.timestamp + 2 days);
        assertEq(market.marketCount(), 2);
    }

    function test_CreateMarket_ChargesFee() public {
        vm.prank(admin);
        market.setMarketCreationFee(5e6);

        _fundAndApprove(alice, 5e6);

        uint256 feeRecipientBefore = usdc.balanceOf(feeRecipient);
        vm.prank(alice);
        market.createMarket("Q?", block.timestamp + 1 days, address(oracle));
        assertEq(usdc.balanceOf(feeRecipient) - feeRecipientBefore, 5e6);
    }

    function test_Revert_CreateMarket_EmptyQuestion() public {
        vm.expectRevert(IMarketFacet.Market_EmptyQuestion.selector);
        vm.prank(alice);
        market.createMarket("", block.timestamp + 1 days, address(oracle));
    }

    function test_Revert_CreateMarket_PastEndTime() public {
        vm.expectRevert(IMarketFacet.Market_InvalidEndTime.selector);
        vm.prank(alice);
        market.createMarket("Q?", block.timestamp, address(oracle));
    }

    function test_Revert_CreateMarket_ZeroOracle() public {
        vm.expectRevert(IMarketFacet.Market_ZeroAddress.selector);
        vm.prank(alice);
        market.createMarket("Q?", block.timestamp + 1 days, address(0));
    }

    function test_Revert_CreateMarket_OracleNotApproved() public {
        MockOracle other = new MockOracle();
        vm.expectRevert(IMarketFacet.Market_OracleNotApproved.selector);
        vm.prank(alice);
        market.createMarket("Q?", block.timestamp + 1 days, address(other));
    }

    function test_Revert_CreateMarket_WhenMarketModulePaused() public {
        vm.prank(admin);
        pausable.pauseModule(Modules.MARKET);
        vm.expectRevert(abi.encodeWithSelector(IPausableFacet.Pausable_EnforcedPause.selector, Modules.MARKET));
        vm.prank(alice);
        market.createMarket("Q?", block.timestamp + 1 days, address(oracle));
    }

    function test_Revert_CreateMarket_WhenPausedGlobally() public {
        vm.prank(admin);
        pausable.pause();
        vm.expectRevert(abi.encodeWithSelector(IPausableFacet.Pausable_EnforcedPause.selector, Modules.MARKET));
        vm.prank(alice);
        market.createMarket("Q?", block.timestamp + 1 days, address(oracle));
    }

    function test_ApproveOracle_HappyPath() public {
        MockOracle other = new MockOracle();
        vm.expectEmit(true, true, true, true);
        emit IMarketFacet.OracleApproved(address(other));
        vm.prank(admin);
        market.approveOracle(address(other));
        assertTrue(market.isOracleApproved(address(other)));
    }

    function test_Revert_ApproveOracle_NotAdmin() public {
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControlFacet.AccessControl_MissingRole.selector, Roles.ADMIN_ROLE, alice)
        );
        vm.prank(alice);
        market.approveOracle(address(0xBEEF));
    }

    function test_Revert_ApproveOracle_AlreadyApproved() public {
        vm.expectRevert(IMarketFacet.Market_OracleAlreadyApproved.selector);
        vm.prank(admin);
        market.approveOracle(address(oracle));
    }

    function test_Revert_ApproveOracle_Zero() public {
        vm.expectRevert(IMarketFacet.Market_ZeroAddress.selector);
        vm.prank(admin);
        market.approveOracle(address(0));
    }

    function test_RevokeOracle_HappyPath() public {
        vm.prank(admin);
        market.revokeOracle(address(oracle));
        assertFalse(market.isOracleApproved(address(oracle)));
    }

    function test_Revert_RevokeOracle_NotApproved() public {
        vm.expectRevert(IMarketFacet.Market_OracleNotApproved.selector);
        vm.prank(admin);
        market.revokeOracle(address(0xBEEF));
    }

    function test_SetFeeRecipient() public {
        address newRecipient = makeAddr("newRecipient");
        vm.prank(admin);
        market.setFeeRecipient(newRecipient);
        assertEq(market.feeRecipient(), newRecipient);
    }

    function test_Revert_SetFeeRecipient_Zero() public {
        vm.expectRevert(IMarketFacet.Market_ZeroAddress.selector);
        vm.prank(admin);
        market.setFeeRecipient(address(0));
    }

    function test_SetMarketCreationFee() public {
        vm.prank(admin);
        market.setMarketCreationFee(1e6);
        assertEq(market.marketCreationFee(), 1e6);
    }

    function test_SetDefaultPerMarketCap() public {
        vm.prank(admin);
        market.setDefaultPerMarketCap(1000e6);
        assertEq(market.defaultPerMarketCap(), 1000e6);
    }

    function test_SetPerMarketCap() public {
        uint256 id = _createMarket(block.timestamp + 1 days);
        vm.prank(admin);
        market.setPerMarketCap(id, 500e6);
        assertEq(market.getMarket(id).perMarketCap, 500e6);
    }

    function test_GetMarketStatus_MatchesFullView() public {
        uint256 endTime = block.timestamp + 3 days;
        uint256 id = _createMarket(endTime);
        IMarketFacet.MarketView memory full = market.getMarket(id);
        (address yes, address no, uint256 et, bool resolved, bool refundMode) = market.getMarketStatus(id);
        assertEq(yes, full.yesToken);
        assertEq(no, full.noToken);
        assertEq(et, full.endTime);
        assertEq(resolved, full.isResolved);
        assertEq(refundMode, full.refundModeActive);
    }

    function test_Revert_GetMarketStatus_NotFound() public {
        vm.expectRevert(IMarketFacet.Market_NotFound.selector);
        market.getMarketStatus(999);
    }
}
