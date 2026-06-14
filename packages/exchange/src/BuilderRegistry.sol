// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import {IAccessControlFacet} from "@predix/shared/interfaces/IAccessControlFacet.sol";
import {Roles} from "@predix/shared/constants/Roles.sol";
import {IBuilderRegistry} from "@predix/shared/interfaces/IBuilderRegistry.sol";

/// @title BuilderRegistry
/// @notice Config + governance for the PrediX Builder Program. Holds no funds.
/// @dev Governance gated by the diamond's ADMIN_ROLE (same pattern as PrediXExchange.onlyAdmin).
contract BuilderRegistry is IBuilderRegistry {
    uint16 public constant ABSOLUTE_MAX_TAKER_BPS = 100;
    uint16 public constant ABSOLUTE_MAX_MAKER_BPS = 50;

    address public immutable diamond;

    uint16 public maxTakerBps = 100;
    uint16 public maxMakerBps = 50;
    uint64 public rateChangeCooldown = 3 days;
    uint64 public rateChangeMinInterval = 7 days;

    mapping(bytes32 => Builder) internal _builders;

    modifier onlyAdmin() {
        if (!IAccessControlFacet(diamond).hasRole(Roles.ADMIN_ROLE, msg.sender)) {
            revert Registry_NotAdmin();
        }
        _;
    }

    constructor(address _diamond) {
        if (_diamond == address(0)) revert Registry_ZeroCode();
        diamond = _diamond;
    }

    // ---- Governance (diamond ADMIN_ROLE) ----

    /// @inheritdoc IBuilderRegistry
    function setBuilder(bytes32 code, address recipient_, uint16 takerBps_, uint16 makerBps_) external onlyAdmin {
        if (code == bytes32(0)) revert Registry_ZeroCode();
        if (recipient_ == address(0)) revert Registry_ZeroRecipient();
        if (_builders[code].exists) revert Registry_AlreadyExists();
        if (takerBps_ > maxTakerBps || makerBps_ > maxMakerBps) revert Registry_CapExceeded();

        _builders[code] = Builder({
            recipient: recipient_,
            takerBps: takerBps_,
            makerBps: makerBps_,
            pendingTakerBps: 0,
            pendingMakerBps: 0,
            rateReadyAt: 0,
            lastChangeAt: uint64(block.timestamp),
            exists: true
        });
        emit BuilderSet(code, recipient_, takerBps_, makerBps_);
    }

    /// @inheritdoc IBuilderRegistry
    function setRecipient(bytes32 code, address recipient_) external onlyAdmin {
        if (!_builders[code].exists) revert Registry_UnknownCode();
        if (recipient_ == address(0)) revert Registry_ZeroRecipient();
        _builders[code].recipient = recipient_;
        emit RecipientSet(code, recipient_);
    }

    /// @inheritdoc IBuilderRegistry
    function proposeRates(bytes32 code, uint16 takerBps_, uint16 makerBps_) external onlyAdmin {
        Builder storage b = _builders[code];
        if (!b.exists) revert Registry_UnknownCode();
        if (takerBps_ > maxTakerBps || makerBps_ > maxMakerBps) revert Registry_CapExceeded();
        if (block.timestamp < uint256(b.lastChangeAt) + rateChangeMinInterval) revert Registry_CooldownActive();

        b.pendingTakerBps = takerBps_;
        b.pendingMakerBps = makerBps_;
        b.rateReadyAt = uint64(block.timestamp + rateChangeCooldown);
        emit RatesProposed(code, takerBps_, makerBps_, b.rateReadyAt);
    }

    /// @inheritdoc IBuilderRegistry
    function applyRates(bytes32 code) external {
        Builder storage b = _builders[code];
        if (b.rateReadyAt == 0) revert Registry_NoPendingRates();
        if (block.timestamp < b.rateReadyAt) revert Registry_RateNotReady();

        b.takerBps = b.pendingTakerBps;
        b.makerBps = b.pendingMakerBps;
        b.pendingTakerBps = 0;
        b.pendingMakerBps = 0;
        b.rateReadyAt = 0;
        b.lastChangeAt = uint64(block.timestamp);
        emit RatesApplied(code, b.takerBps, b.makerBps);
    }

    /// @inheritdoc IBuilderRegistry
    function setMaxBps(uint16 maxTaker, uint16 maxMaker) external onlyAdmin {
        if (maxTaker > ABSOLUTE_MAX_TAKER_BPS || maxMaker > ABSOLUTE_MAX_MAKER_BPS) {
            revert Registry_AbsoluteCapExceeded();
        }
        maxTakerBps = maxTaker;
        maxMakerBps = maxMaker;
        emit MaxBpsSet(maxTaker, maxMaker);
    }

    // ---- Views ----

    /// @inheritdoc IBuilderRegistry
    function feeOf(bytes32 code) external view returns (uint16 takerBps, uint16 makerBps, address recipient) {
        Builder storage b = _builders[code];
        return (b.takerBps, b.makerBps, b.recipient);
    }

    /// @inheritdoc IBuilderRegistry
    function recipientOf(bytes32 code) external view returns (address) {
        return _builders[code].recipient;
    }

    /// @inheritdoc IBuilderRegistry
    function exists(bytes32 code) external view returns (bool) {
        return _builders[code].exists;
    }

    /// @inheritdoc IBuilderRegistry
    function getBuilder(bytes32 code) external view returns (Builder memory) {
        return _builders[code];
    }
}
