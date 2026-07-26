// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

/// @notice Role identifiers used by the EARN protocol.
/// @dev Role names and hashes are unchanged from the previous deployment so existing ops runbooks,
///      multisig transaction batches, and monitoring keep working.
///
///      Separation of duties enforced by these roles:
///      - `DEFAULT_ADMIN_ROLE` wires contracts and manages the role graph. It can start (but not
///        finish, within the same day) a treasury wallet rotation.
///      - `UPGRADER_ROLE` schedules and executes implementation changes, both subject to the
///        24h upgrade timelock in `DelayedUUPSUpgradeable`.
///      - Operational roles below cannot upgrade, cannot move the treasury wallet, and cannot
///        grant themselves additional roles.
///
///      Known residual risk: OpenZeppelin `AccessControl` has no two-step handover for
///      `DEFAULT_ADMIN_ROLE` — `grantRole`/`revokeRole` take effect immediately, and the rewrite
///      deliberately does not fork AccessControl to add one. The two money-critical consequences of
///      an admin compromise are already neutralised by timelocks (implementation swaps and treasury
///      wallet rotation both need 24h and are publicly visible while pending). The residual exposure
///      is limited to wiring calls (`setShareToken` is one-shot, `setSubscriptionManager`,
///      `setKycSigner`) and to the role graph itself, so `DEFAULT_ADMIN_ROLE` MUST be held by a
///      multisig or governance timelock in production, never by a single hot EOA.
abstract contract EarnRoles {
    /// @notice Manages protocol parameters (APR, ratios, limits, fees).
    bytes32 public constant PARAMETER_MANAGER_ROLE = keccak256("PARAMETER_MANAGER_ROLE");
    /// @notice Manages treasury side operations (buffer replenishment, treasury transfers).
    bytes32 public constant TREASURY_MANAGER_ROLE = keccak256("TREASURY_MANAGER_ROLE");
    /// @notice Manages blacklist and compliance actions.
    bytes32 public constant COMPLIANCE_ROLE = keccak256("COMPLIANCE_ROLE");
    /// @notice Reports treasury assets into accounting.
    bytes32 public constant REPORTER_ROLE = keccak256("REPORTER_ROLE");
    /// @notice Pauses withdrawal entrypoints.
    bytes32 public constant PAUSER_ROLE = keccak256("PAUSER_ROLE");
    /// @notice Schedules and executes UUPS upgrades (always behind the upgrade timelock).
    bytes32 public constant UPGRADER_ROLE = keccak256("UPGRADER_ROLE");
}
