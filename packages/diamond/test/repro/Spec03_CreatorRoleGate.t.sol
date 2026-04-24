// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {IEventFacet} from "@predix/shared/interfaces/IEventFacet.sol";
import {IMarketFacet} from "@predix/shared/interfaces/IMarketFacet.sol";
import {Roles} from "@predix/shared/constants/Roles.sol";

import {EventFixture} from "../utils/EventFixture.sol";

/// @notice Repro for SPEC-03 (Bundle C #11) — Phase 1-2 creation is
///         admin-gated. Pre-fix, both `createMarket` and `createEvent`
///         were permissionless, drifting from the security spec which
///         calls for `ADMIN_ROLE`-gated creation until Phase 4+.
///         This test file exercises the CREATOR_ROLE gate: only holders
///         can create, admin can delegate / revoke, DiamondInit seats the
///         role on the initial admin.
contract Spec03_CreatorRoleGate is EventFixture {
    address internal operator = makeAddr("operator");
    address internal rando = makeAddr("rando");

    uint256 internal endTime;

    function setUp() public override {
        super.setUp();
        endTime = block.timestamp + 7 days;
    }

    // --- createMarket ---

    function test_Spec03_CreateMarket_WithoutRole_Reverts() public {
        vm.prank(rando);
        vm.expectRevert(IMarketFacet.Market_NotCreator.selector);
        market.createMarket("unauthorized", endTime, address(oracle));
    }

    function test_Spec03_CreateMarket_WithRole_Success() public {
        // `alice` is granted CREATOR_ROLE by MarketFixture.setUp.
        vm.prank(alice);
        uint256 marketId = market.createMarket("authorized", endTime, address(oracle));
        assertEq(marketId, 1, "authorized creation succeeds");
    }

    function test_Spec03_GrantCreatorRole_ThenCreate_Success() public {
        vm.prank(admin);
        accessControl.grantRole(Roles.CREATOR_ROLE, operator);

        vm.prank(operator);
        uint256 marketId = market.createMarket("operator market", endTime, address(oracle));
        assertEq(marketId, 1, "delegate creation succeeds");
    }

    function test_Spec03_RevokeCreatorRole_ThenCreate_Reverts() public {
        vm.prank(admin);
        accessControl.revokeRole(Roles.CREATOR_ROLE, alice);

        vm.prank(alice);
        vm.expectRevert(IMarketFacet.Market_NotCreator.selector);
        market.createMarket("revoked", endTime, address(oracle));
    }

    // --- createEvent ---

    function test_Spec03_CreateEvent_SameGate() public {
        string[] memory qs = new string[](2);
        qs[0] = "A wins";
        qs[1] = "B wins";

        vm.prank(rando);
        vm.expectRevert(IEventFacet.Event_NotCreator.selector);
        eventFacet.createEvent("AvB", qs, endTime);

        // `alice` has the role, same call succeeds.
        vm.prank(alice);
        (uint256 eventId,) = eventFacet.createEvent("AvB", qs, endTime);
        assertEq(eventId, 1, "alice can create events");
    }

    // --- DiamondInit seeds admin with CREATOR_ROLE ---

    function test_Spec03_DiamondInit_GrantsCreatorRoleToAdmin() public view {
        assertTrue(
            accessControl.hasRole(Roles.CREATOR_ROLE, admin),
            "admin must hold CREATOR_ROLE post-init so operators can be onboarded"
        );
    }
}
