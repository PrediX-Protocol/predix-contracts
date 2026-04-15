// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {IDiamondCut} from "@predix/shared/interfaces/IDiamondCut.sol";
import {IMarketFacet} from "@predix/shared/interfaces/IMarketFacet.sol";
import {IOutcomeToken} from "@predix/shared/interfaces/IOutcomeToken.sol";

import {MarketFacet} from "@predix/diamond/facets/market/MarketFacet.sol";
import {MarketInit} from "@predix/diamond/init/MarketInit.sol";

import {DiamondFixture} from "../utils/DiamondFixture.sol";
import {MockOracle} from "../mocks/MockOracle.sol";

/// @notice Full market lifecycle end-to-end against a forked chain with the
///         real canonical USDC token instead of MockUSDC. The oracle is still
///         a protocol-internal mock because oracle adapters do not need to
///         touch on-chain state to verify the lifecycle math; the goal is to
///         catch gaps between `MockUSDC` and the real ERC-20 implementation
///         (allowance handling, decimals, `safeTransferFrom` quirks).
contract MarketLifecycleForkTest is DiamondFixture {
    MarketFacet internal marketFacet;
    MarketInit internal marketInit;
    MockOracle internal oracle;
    IERC20 internal usdc;
    IMarketFacet internal market;

    address internal feeRecipient = makeAddr("fork_fee_recipient");
    address internal alice = makeAddr("fork_alice");
    address internal bob = makeAddr("fork_bob");

    function setUp() public override {
        vm.createSelectFork(vm.envString("UNICHAIN_RPC_PRIMARY"));
        usdc = IERC20(vm.envAddress("USDC_ADDRESS"));

        super.setUp();

        marketFacet = new MarketFacet();
        marketInit = new MarketInit();
        oracle = new MockOracle();

        IDiamondCut.FacetCut[] memory cuts = new IDiamondCut.FacetCut[](1);
        cuts[0] = _add(address(marketFacet), _marketSelectors());

        MarketInit.InitArgs memory args = MarketInit.InitArgs({
            collateralToken: address(usdc),
            feeRecipient: feeRecipient,
            marketCreationFee: 0,
            defaultPerMarketCap: 0
        });
        bytes memory initData = abi.encodeCall(MarketInit.init, (args));

        vm.prank(timelock);
        diamondCut.diamondCut(cuts, address(marketInit), initData);
        market = IMarketFacet(address(diamond));

        vm.prank(admin);
        market.approveOracle(address(oracle));
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

    function _fundAndApprove(address user, uint256 amount) internal {
        deal(address(usdc), user, amount);
        vm.prank(user);
        usdc.approve(address(diamond), type(uint256).max);
    }

    // -----------------------------------------------------------------------

    function test_FullLifecycle_SplitResolveRedeem() public {
        uint256 endTime = block.timestamp + 1 days;
        uint256 deposit = 1_000e6;

        _fundAndApprove(alice, deposit);
        vm.prank(alice);
        uint256 mid = market.createMarket("Will X happen?", endTime, address(oracle));

        vm.prank(alice);
        market.splitPosition(mid, deposit);
        assertEq(usdc.balanceOf(address(diamond)), deposit);

        IMarketFacet.MarketView memory m = market.getMarket(mid);
        assertEq(IOutcomeToken(m.yesToken).balanceOf(alice), deposit);
        assertEq(IOutcomeToken(m.noToken).balanceOf(alice), deposit);

        oracle.setResolution(mid, true);
        vm.warp(endTime + 1);
        market.resolveMarket(mid);

        uint256 balBefore = usdc.balanceOf(alice);
        vm.prank(alice);
        uint256 payout = market.redeem(mid);
        assertEq(payout, deposit, "payout must equal deposit at 0% fee");
        assertEq(usdc.balanceOf(alice) - balBefore, deposit);
        assertEq(usdc.balanceOf(address(diamond)), 0);
    }

    function test_RefundMode_WithRealUSDC() public {
        uint256 endTime = block.timestamp + 1 days;
        uint256 deposit = 500e6;

        _fundAndApprove(alice, deposit);
        vm.prank(alice);
        uint256 mid = market.createMarket("Will Y happen?", endTime, address(oracle));

        vm.prank(alice);
        market.splitPosition(mid, deposit);

        vm.warp(endTime + 1);
        vm.prank(admin);
        market.enableRefundMode(mid);

        uint256 balBefore = usdc.balanceOf(alice);
        vm.prank(alice);
        uint256 refund = market.refund(mid, deposit, deposit);
        assertEq(refund, deposit);
        assertEq(usdc.balanceOf(alice) - balBefore, deposit);
    }

    function test_Gas_SplitPositionAgainstRealUSDC() public {
        uint256 endTime = block.timestamp + 1 days;
        _fundAndApprove(alice, 10_000e6);

        vm.prank(alice);
        uint256 mid = market.createMarket("Gas probe", endTime, address(oracle));

        vm.prank(alice);
        uint256 gasStart = gasleft();
        market.splitPosition(mid, 1_000e6);
        uint256 gasUsed = gasStart - gasleft();
        emit log_named_uint("splitPosition_real_usdc_gas", gasUsed);
        // Upper bound is soft — the real goal is to surface drift vs the
        // mock-USDC unit-test snapshot when a future USDC upgrade changes
        // the storage layout or adds transfer-side logic.
        assertLt(gasUsed, 250_000, "split gas regression against real USDC");
    }
}
