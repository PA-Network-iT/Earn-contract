// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

/// @notice Role identifiers used by the EARN protocol.
abstract contract EarnRoles {
    /// @notice Manages protocol parameters.
    bytes32 public constant PARAMETER_MANAGER_ROLE = keccak256("PARAMETER_MANAGER_ROLE");
    /// @notice Manages treasury side operations.
    bytes32 public constant TREASURY_MANAGER_ROLE = keccak256("TREASURY_MANAGER_ROLE");
    /// @notice Manages blacklist and compliance actions.
    bytes32 public constant COMPLIANCE_ROLE = keccak256("COMPLIANCE_ROLE");
    /// @notice Reports treasury assets into accounting.
    bytes32 public constant REPORTER_ROLE = keccak256("REPORTER_ROLE");
    /// @notice Pauses withdrawal entrypoints.
    bytes32 public constant PAUSER_ROLE = keccak256("PAUSER_ROLE");
    /// @notice Authorizes UUPS upgrades.
    bytes32 public constant UPGRADER_ROLE = keccak256("UPGRADER_ROLE");
}
