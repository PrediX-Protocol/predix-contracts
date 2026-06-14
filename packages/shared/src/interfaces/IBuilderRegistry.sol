// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

/// @title IBuilderRegistry
/// @notice Config + governance for the PrediX Builder Program. Holds no funds.
///         The Exchange reads (takerBps, makerBps, recipient); the Router reads (takerBps).
interface IBuilderRegistry {
    struct Builder {
        address recipient;
        uint16 takerBps;
        uint16 makerBps;
        uint16 pendingTakerBps;
        uint16 pendingMakerBps;
        uint64 rateReadyAt;
        uint64 lastChangeAt;
        bool exists;
    }

    // ---- Errors ----
    error Registry_NotAdmin();
    error Registry_ZeroCode();
    error Registry_ZeroRecipient();
    error Registry_AlreadyExists();
    error Registry_UnknownCode();
    error Registry_CapExceeded();
    error Registry_CooldownActive();
    error Registry_NoPendingRates();
    error Registry_RateNotReady();
    error Registry_AbsoluteCapExceeded();

    // ---- Events ----
    event BuilderSet(bytes32 indexed code, address recipient, uint16 takerBps, uint16 makerBps);
    event RecipientSet(bytes32 indexed code, address recipient);
    event RatesProposed(bytes32 indexed code, uint16 takerBps, uint16 makerBps, uint64 rateReadyAt);
    event RatesApplied(bytes32 indexed code, uint16 takerBps, uint16 makerBps);
    event MaxBpsSet(uint16 maxTaker, uint16 maxMaker);

    // ---- Governance (diamond ADMIN_ROLE) ----
    function setBuilder(bytes32 code, address recipient, uint16 takerBps, uint16 makerBps) external;
    function setRecipient(bytes32 code, address recipient) external;
    function proposeRates(bytes32 code, uint16 takerBps, uint16 makerBps) external;
    function applyRates(bytes32 code) external;
    function setMaxBps(uint16 maxTaker, uint16 maxMaker) external;

    // ---- Views ----
    function feeOf(bytes32 code) external view returns (uint16 takerBps, uint16 makerBps, address recipient);
    function recipientOf(bytes32 code) external view returns (address);
    function exists(bytes32 code) external view returns (bool);
    function getBuilder(bytes32 code) external view returns (Builder memory);
}
