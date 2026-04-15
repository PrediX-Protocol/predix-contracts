// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {MarketFixture} from "../utils/MarketFixture.sol";
import {RedemptionFeeHandler} from "./RedemptionFeeHandler.sol";

/// @notice Invariant: once a market is resolved and the protocol redemption fee is
///         enabled, the fee recipient's USDC balance only ever grows as users redeem.
///         The fixture isolates `feeRecipient` from the participant set so this
///         invariant is meaningful (no path out of the recipient's wallet).
contract RedemptionFeeInvariantTest is MarketFixture {
    RedemptionFeeHandler internal handler;
    uint256 internal marketId;
    uint256 internal feeRecipientBaseline;

    function setUp() public override {
        super.setUp();

        // Enable a non-trivial fee so redemptions route value to the fee recipient.
        vm.prank(admin);
        market.setDefaultRedemptionFeeBps(500); // 5%

        uint256 endTime_ = block.timestamp + 1 days;
        marketId = _createMarket(endTime_);

        // Seed 5 participants with winning positions.
        address[5] memory users;
        for (uint256 i; i < 5; ++i) {
            address u = address(uint160(uint256(keccak256(abi.encode("redemption.user", i)))));
            users[i] = u;
            _split(u, marketId, 1_000_000e6);
        }

        // Resolve with YES winning.
        oracle.setResolution(marketId, true);
        vm.warp(endTime_ + 1);
        market.resolveMarket(marketId);

        feeRecipientBaseline = usdc.balanceOf(feeRecipient);
        handler = new RedemptionFeeHandler(address(diamond), marketId, users);

        bytes4[] memory selectors = new bytes4[](1);
        selectors[0] = RedemptionFeeHandler.redeem.selector;
        targetSelector(FuzzSelector({addr: address(handler), selectors: selectors}));
        targetContract(address(handler));
    }

    /// @notice The fee recipient's balance only grows, never shrinks. Any redemption
    ///         that moves value into the recipient's wallet is a one-way push; no
    ///         function on the diamond pulls from the fee recipient.
    function invariant_FeeRecipientBalanceMonotonic() public view {
        assertGe(usdc.balanceOf(feeRecipient), feeRecipientBaseline);
    }
}
