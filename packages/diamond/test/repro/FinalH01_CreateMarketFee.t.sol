// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {IMarketFacet} from "@predix/shared/interfaces/IMarketFacet.sol";

import {MarketFixture} from "../utils/MarketFixture.sol";

/// @notice Repro for FINAL-H01: `createMarket` must collect the
///         admin-configured `marketCreationFee` from the caller and forward
///         it to `feeRecipient` in the same transaction. Pre-fix claim in
///         the audit report was that the facet never pulled USDC; verified
///         by this test.
contract FinalH01_CreateMarketFee is MarketFixture {
    function test_CreateMarket_ChargesConfiguredFee() public {
        uint256 fee = 5e6;
        vm.prank(admin);
        market.setMarketCreationFee(fee);

        _fundAndApprove(alice, fee);
        uint256 creatorBefore = usdc.balanceOf(alice);
        uint256 recipBefore = usdc.balanceOf(feeRecipient);

        vm.prank(alice);
        market.createMarket("Q?", block.timestamp + 1 days, address(oracle));

        assertEq(creatorBefore - usdc.balanceOf(alice), fee, "creator charged");
        assertEq(usdc.balanceOf(feeRecipient) - recipBefore, fee, "recipient credited");
    }

    function test_CreateMarket_ZeroFee_NoTransfer() public {
        uint256 creatorBefore = usdc.balanceOf(alice);
        vm.prank(alice);
        market.createMarket("Q?", block.timestamp + 1 days, address(oracle));
        assertEq(usdc.balanceOf(alice), creatorBefore);
    }
}
