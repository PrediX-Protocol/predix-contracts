// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

/// @title IPrediXPaymaster — interface cho PrediXPaymaster (self-hosted verifying paymaster)
/// @notice Errors + events + admin surface. Implementation inherits BasePaymaster.
interface IPrediXPaymaster {
    event SignerChanged(address indexed oldSigner, address indexed newSigner);
    event Paused(address indexed by);
    event Unpaused(address indexed by);

    error ContractPaused();
    error InvalidSignatureLength(uint256 actual);
    error ZeroAddress();

    function signer() external view returns (address);

    function paused() external view returns (bool);

    function setSigner(address newSigner) external;

    function pause() external;

    function unpause() external;
}
