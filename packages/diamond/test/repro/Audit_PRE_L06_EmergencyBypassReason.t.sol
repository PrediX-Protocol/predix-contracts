// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import {IMarketFacet} from "@predix/shared/interfaces/IMarketFacet.sol";
import {IEventFacet} from "@predix/shared/interfaces/IEventFacet.sol";
import {IOracle} from "@predix/shared/interfaces/IOracle.sol";
import {IEventOracle} from "@predix/shared/interfaces/IEventOracle.sol";
import {EmergencyReason} from "@predix/shared/constants/EmergencyReason.sol";
import {Roles} from "@predix/shared/constants/Roles.sol";
import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";

import {EventFixture} from "../utils/EventFixture.sol";

/// @dev Minimal oracle that always reverts on isResolved — used to exercise
///      the `OracleUnreachable` path on both market and event emergency flows.
contract RevertingOracle is IOracle, IEventOracle, IERC165 {
    error AlwaysReverts();

    // Advertises IEventOracle so it clears createEvent's capability gate; the
    // resolution calls still revert, modeling an oracle that breaks AFTER an
    // event is bound to it (the realistic OracleUnreachable path).
    function supportsInterface(bytes4 interfaceId) external pure override returns (bool) {
        return interfaceId == type(IEventOracle).interfaceId || interfaceId == type(IERC165).interfaceId;
    }

    function isResolved(uint256) external pure returns (bool) {
        revert AlwaysReverts();
    }

    function outcome(uint256) external pure returns (bool) {
        revert AlwaysReverts();
    }

    function isEventResolved(uint256) external pure returns (bool) {
        revert AlwaysReverts();
    }

    function eventOutcome(uint256) external pure returns (uint256) {
        revert AlwaysReverts();
    }
}

/// @title Audit_PRE_L06_EmergencyBypassReason
/// @notice Fix-lock for PRE-L06: the `MarketEmergencyResolved` and
///         `EventEmergencyResolved` events now carry an `EmergencyReason.Reason`
///         field that classifies why the oracle was bypassed. Off-chain
///         monitoring can distinguish routine stall recovery
///         (`OracleUnreachable`) from operator-applied bypass when the oracle
///         was revoked (`OracleRevoked`) or merely silent past the delay
///         (`OracleUnready`).
contract Audit_PRE_L06_EmergencyBypassReason is EventFixture {
    uint256 internal id;
    uint256 internal endTime;
    uint256 internal emergencyTime;
    address internal operator;

    function setUp() public override {
        super.setUp();
        operator = makeAddr("operator");
        vm.prank(admin);
        accessControl.grantRole(Roles.OPERATOR_ROLE, operator);

        endTime = block.timestamp + 7 days;
        emergencyTime = endTime + 7 days; // EMERGENCY_DELAY
        id = _createMarket(endTime);
    }

    /// @dev Reason = OracleUnready: the approved oracle is responsive but has
    ///      not produced an answer by the emergency delay. Operator can still
    ///      force the outcome.
    function test_Market_EmergencyResolve_OracleUnready_EmitsCorrectReason() public {
        vm.warp(emergencyTime + 1);

        vm.expectEmit(true, false, true, true);
        emit IMarketFacet.MarketEmergencyResolved(id, true, operator, EmergencyReason.Reason.OracleUnready);

        vm.prank(operator);
        market.emergencyResolve(id, true);
    }

    /// @dev Reason = OracleRevoked: admin removed the oracle from the approved
    ///      set between market creation and emergency resolution.
    function test_Market_EmergencyResolve_OracleRevoked_EmitsCorrectReason() public {
        vm.warp(emergencyTime + 1);

        vm.prank(admin);
        market.revokeOracle(address(oracle));

        vm.expectEmit(true, false, true, true);
        emit IMarketFacet.MarketEmergencyResolved(id, false, operator, EmergencyReason.Reason.OracleRevoked);

        vm.prank(operator);
        market.emergencyResolve(id, false);
    }

    /// @dev Reason = OracleUnreachable: the approved oracle reverts on every
    ///      call. Classic stall recovery — the most common emergency path.
    function test_Market_EmergencyResolve_OracleUnreachable_EmitsCorrectReason() public {
        RevertingOracle bad = new RevertingOracle();
        vm.prank(admin);
        market.approveOracle(address(bad));

        vm.prank(alice);
        uint256 badId = market.createMarket("revert oracle market", endTime, address(bad));

        vm.warp(emergencyTime + 1);

        vm.expectEmit(true, false, true, true);
        emit IMarketFacet.MarketEmergencyResolved(badId, true, operator, EmergencyReason.Reason.OracleUnreachable);

        vm.prank(operator);
        market.emergencyResolve(badId, true);
    }

    // ============ Event variants ============

    function test_Event_EmergencyResolveEvent_OracleUnready_EmitsCorrectReason() public {
        vm.prank(alice);
        (uint256 eventId,) = eventFacet.createEvent(
            "test event", _defaultQuestions(3), endTime, address(eventOracle)
        );
        vm.warp(emergencyTime + 1);

        vm.expectEmit(true, false, true, true);
        emit IEventFacet.EventEmergencyResolved(eventId, 1, operator, EmergencyReason.Reason.OracleUnready);

        vm.prank(operator);
        eventFacet.emergencyResolveEvent(eventId, 1);
    }

    function test_Event_EmergencyResolveEvent_OracleRevoked_EmitsCorrectReason() public {
        vm.prank(alice);
        (uint256 eventId,) = eventFacet.createEvent(
            "test event", _defaultQuestions(3), endTime, address(eventOracle)
        );

        vm.warp(emergencyTime + 1);

        vm.prank(admin);
        market.revokeOracle(address(eventOracle));

        vm.expectEmit(true, false, true, true);
        emit IEventFacet.EventEmergencyResolved(eventId, 2, operator, EmergencyReason.Reason.OracleRevoked);

        vm.prank(operator);
        eventFacet.emergencyResolveEvent(eventId, 2);
    }

    function test_Event_EmergencyResolveEvent_OracleUnreachable_EmitsCorrectReason() public {
        RevertingOracle bad = new RevertingOracle();
        vm.prank(admin);
        market.approveOracle(address(bad));

        vm.prank(alice);
        (uint256 eventId,) = eventFacet.createEvent(
            "bad event", _defaultQuestions(3), endTime, address(bad)
        );

        vm.warp(emergencyTime + 1);

        vm.expectEmit(true, false, true, true);
        emit IEventFacet.EventEmergencyResolved(eventId, 0, operator, EmergencyReason.Reason.OracleUnreachable);

        vm.prank(operator);
        eventFacet.emergencyResolveEvent(eventId, 0);
    }
}
