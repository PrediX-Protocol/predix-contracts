// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import {IEventFacet} from "@predix/shared/interfaces/IEventFacet.sol";
import {IMarketFacet} from "@predix/shared/interfaces/IMarketFacet.sol";
import {IOutcomeToken} from "@predix/shared/interfaces/IOutcomeToken.sol";

import {EventFixture} from "./EventFixture.sol";

/// @notice Forges a pre-consolidation LEGACY event (per-child collateral, `linked == false`) for
///         lifecycle regression tests. `createEvent` only produces shared-pool events post-
///         consolidation, but chain-130 still carries legacy events whose lifecycle (resolve,
///         refund-mode, per-child redeem/refund, sweep) must keep working — so tests flip a fresh
///         event into the exact storage state legacy bytecode would have left.
/// @dev Slot math mirrors `Gap1LayoutProbe` / `Gap1UpgradeStorageBrick`: EventData `linked` at
///      slot 7 byte 22; MarketData `totalCollateral` at slot 6 and `linkedChild` at slot 12 byte 5;
///      `eventPool` mapping at EVENT_SLOT+3. Every store is cross-checked through the public views
///      so a future layout drift fails loud here instead of silently forging garbage.
abstract contract LegacyEventForge is EventFixture {
    bytes32 internal constant EVENT_SLOT = keccak256("predix.storage.event.v1");
    bytes32 internal constant MARKET_SLOT = keccak256("predix.storage.market.v1");

    /// @notice Flip `eventId` (created via the always-linked `createEvent`) into a legacy event.
    /// @dev Precondition: positions were entered ONLY via per-child `splitPosition` (no
    ///      `splitEvent`), so every child has `YES.totalSupply == NO.totalSupply` and
    ///      `Σ child supplies == eventPool`. The forge re-attributes the pool to per-child
    ///      `totalCollateral`, restoring the exact legacy binary invariant per child;
    ///      `totalCollateralLocked` is already correct and stays untouched.
    function _forgeLegacyEvent(uint256 eventId) internal {
        IEventFacet.EventView memory e = eventFacet.getEvent(eventId);
        require(e.linked, "forge: event already legacy");

        // 1. EventData.linked (slot base+7, byte 22) -> false.
        bytes32 eBase = keccak256(abi.encode(eventId, uint256(EVENT_SLOT) + 1));
        bytes32 eSlot7 = bytes32(uint256(eBase) + 7);
        uint256 word = uint256(vm.load(address(diamond), eSlot7));
        vm.store(address(diamond), eSlot7, bytes32(word & ~(uint256(0xFF) << (8 * 22))));

        // 2. Per child: totalCollateral (slot base+6) = YES supply; linkedChild (slot 12 byte 5) -> false.
        uint256 reattributed;
        for (uint256 i; i < e.marketIds.length; ++i) {
            uint256 childId = e.marketIds[i];
            IMarketFacet.MarketView memory m = market.getMarket(childId);
            uint256 supply = IOutcomeToken(m.yesToken).totalSupply();
            assertEq(IOutcomeToken(m.noToken).totalSupply(), supply, "forge: child YES != NO (splitEvent used?)");

            bytes32 mBase = keccak256(abi.encode(childId, uint256(MARKET_SLOT) + 1));
            vm.store(address(diamond), bytes32(uint256(mBase) + 6), bytes32(supply));
            bytes32 mSlot12 = bytes32(uint256(mBase) + 12);
            uint256 w12 = uint256(vm.load(address(diamond), mSlot12));
            vm.store(address(diamond), mSlot12, bytes32(w12 & ~(uint256(0xFF) << (8 * 5))));
            reattributed += supply;
        }

        // 3. eventPool[eventId] -> 0 (its backing now lives per-child).
        bytes32 poolSlot = keccak256(abi.encode(eventId, uint256(EVENT_SLOT) + 3));
        assertEq(uint256(vm.load(address(diamond), poolSlot)), reattributed, "forge: pool != sum of child supplies");
        vm.store(address(diamond), poolSlot, bytes32(uint256(0)));

        // Fail-loud cross-checks through the public views (layout-drift tripwires).
        IEventFacet.EventView memory after_ = eventFacet.getEvent(eventId);
        assertFalse(after_.linked, "forge: linked flag did not clear");
        assertEq(after_.oracle, e.oracle, "forge: oracle corrupted");
        assertEq(after_.endTime, e.endTime, "forge: endTime corrupted");
        assertEq(eventFacet.eventPoolOf(eventId), 0, "forge: pool not cleared");
        for (uint256 i; i < e.marketIds.length; ++i) {
            IMarketFacet.MarketView memory m = market.getMarket(e.marketIds[i]);
            assertEq(m.totalCollateral, IOutcomeToken(m.yesToken).totalSupply(), "forge: child collateral mismatch");
            assertEq(m.eventId, eventId, "forge: child eventId corrupted");
        }
    }
}
