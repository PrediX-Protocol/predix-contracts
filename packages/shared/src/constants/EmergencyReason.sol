// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

/// @title EmergencyReason
/// @notice Classification of why an emergency resolve bypassed the normal oracle
///         flow. Emitted as an indexed field on emergency-resolved events so
///         off-chain monitoring can separate routine stall recovery from
///         operator action that warrants investigation.
library EmergencyReason {
    /// @dev Reason codes:
    ///      - `OracleUnreachable`: oracle was in the approved set but reverted
    ///        on `isResolved` (typical stall recovery path).
    ///      - `OracleRevoked`: admin removed the oracle from the approved set
    ///        between market creation and emergency resolution.
    ///      - `OracleUnready`: oracle was approved and responsive but had not
    ///        produced an answer by the emergency delay — operator forced the
    ///        outcome.
    enum Reason {
        OracleUnreachable,
        OracleRevoked,
        OracleUnready
    }
}
