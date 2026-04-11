// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

/// @notice EN: Role identifiers used by the EARN protocol.
/// @custom:fa شناسه نقش‌های دسترسی مورد استفاده در پروتکل EARN.
abstract contract EarnRoles {
    /// @notice EN: Manages protocol parameters.
    /// @custom:fa پارامترهای پروتکل را مدیریت می‌کند.
    bytes32 public constant PARAMETER_MANAGER_ROLE = keccak256("PARAMETER_MANAGER_ROLE");
    /// @notice EN: Manages treasury side operations.
    /// @custom:fa عملیات مربوط به خزانه را مدیریت می‌کند.
    bytes32 public constant TREASURY_MANAGER_ROLE = keccak256("TREASURY_MANAGER_ROLE");
    /// @notice EN: Manages blacklist and compliance actions.
    /// @custom:fa عملیات compliance و blacklist را مدیریت می‌کند.
    bytes32 public constant COMPLIANCE_ROLE = keccak256("COMPLIANCE_ROLE");
    /// @notice EN: Reports treasury assets into accounting.
    /// @custom:fa دارایی‌های خزانه را در حسابداری پروتکل گزارش می‌کند.
    bytes32 public constant REPORTER_ROLE = keccak256("REPORTER_ROLE");
    /// @notice EN: Pauses withdrawal entrypoints.
    /// @custom:fa entrypointهای برداشت را pause می‌کند.
    bytes32 public constant PAUSER_ROLE = keccak256("PAUSER_ROLE");
    /// @notice EN: Authorizes UUPS upgrades.
    /// @custom:fa upgradeهای UUPS را مجاز می‌کند.
    bytes32 public constant UPGRADER_ROLE = keccak256("UPGRADER_ROLE");
}
