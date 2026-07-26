// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";

/// @dev Reverts when the implementation address is zero or has no bytecode.
error UpgradeImplementationInvalid(address implementation);
/// @dev Reverts when `upgradeToAndCall` targets an implementation that was never scheduled.
error UpgradeNotScheduled(address implementation);
/// @dev Reverts when the timelock has not elapsed yet.
error UpgradeDelayNotElapsed(uint256 executableAt, uint256 currentTime);
/// @dev Reverts when cancelling while nothing is scheduled.
error NoScheduledUpgrade();

/// @notice UUPS base that forces every implementation change through a public timelock.
/// @dev Two-step flow:
///      1. `scheduleUpgrade(newImplementation)` records the target and starts the delay.
///      2. After `UPGRADE_DELAY` the same authority calls `upgradeToAndCall(newImplementation, data)`.
///
///      `_authorizeUpgrade` consumes the schedule, so every upgrade needs its own scheduling
///      transaction. A caller holding the upgrade authority can never swap the implementation
///      inside a single block, which gives users and monitoring at least `UPGRADE_DELAY` to react
///      to a malicious or mistaken upgrade.
///
///      Storage lives in a dedicated namespaced slot (ERC-7201 style) so inheriting contracts keep
///      their own sequential layout untouched and this base can be added to any of them without
///      shifting slots.
abstract contract DelayedUUPSUpgradeable is Initializable, UUPSUpgradeable {
    /// @notice Minimum waiting time between scheduling and executing an implementation change.
    uint256 public constant UPGRADE_DELAY = 24 hours;

    /// @notice Pending implementation change.
    /// @param implementation Scheduled implementation, zero when nothing is pending.
    /// @param scheduledAt Timestamp of the scheduling transaction.
    /// @param executableAt Earliest timestamp at which `upgradeToAndCall` may run.
    struct ScheduledUpgrade {
        address implementation;
        uint64 scheduledAt;
        uint64 executableAt;
    }

    /// @dev Namespaced storage slot: `keccak256("pait.storage.DelayedUUPSUpgradeable.v1")`.
    bytes32 private constant _SCHEDULED_UPGRADE_SLOT = keccak256("pait.storage.DelayedUUPSUpgradeable.v1");

    event UpgradeScheduled(address indexed implementation, uint256 scheduledAt, uint256 executableAt);
    event UpgradeCancelled(address indexed implementation);
    event UpgradeExecuted(address indexed implementation);

    /// @dev Initializes the UUPS base. Callable only from an initializer of the inheriting contract.
    // solhint-disable-next-line func-name-mixedcase
    function __DelayedUUPS_init() internal onlyInitializing {
        __UUPSUpgradeable_init();
    }

    /// @notice Returns the currently scheduled implementation change.
    /// @return implementation Scheduled implementation, zero when nothing is pending.
    /// @return scheduledAt Timestamp of the scheduling transaction.
    /// @return executableAt Earliest timestamp at which the upgrade may execute.
    function scheduledUpgrade()
        external
        view
        returns (address implementation, uint64 scheduledAt, uint64 executableAt)
    {
        ScheduledUpgrade storage pending = _scheduledUpgradeStorage();
        return (pending.implementation, pending.scheduledAt, pending.executableAt);
    }

    /// @notice Starts the timelock for `newImplementation`.
    /// @dev Re-scheduling overwrites any previous entry and restarts the full delay, so a
    ///      mis-typed target can be corrected without waiting for the original window.
    /// @param newImplementation Implementation contract that will be installed after the delay.
    function scheduleUpgrade(address newImplementation) external onlyProxy {
        _checkUpgradeAuthority(msg.sender);
        if (newImplementation == address(0) || newImplementation.code.length == 0) {
            revert UpgradeImplementationInvalid(newImplementation);
        }

        uint64 scheduledAt = uint64(block.timestamp);
        uint64 executableAt = uint64(block.timestamp + UPGRADE_DELAY);

        ScheduledUpgrade storage pending = _scheduledUpgradeStorage();
        pending.implementation = newImplementation;
        pending.scheduledAt = scheduledAt;
        pending.executableAt = executableAt;

        emit UpgradeScheduled(newImplementation, scheduledAt, executableAt);
    }

    /// @notice Drops the pending implementation change.
    function cancelScheduledUpgrade() external onlyProxy {
        _checkUpgradeAuthority(msg.sender);

        ScheduledUpgrade storage pending = _scheduledUpgradeStorage();
        address implementation = pending.implementation;
        if (implementation == address(0)) {
            revert NoScheduledUpgrade();
        }

        _clearScheduledUpgrade(pending);
        emit UpgradeCancelled(implementation);
    }

    /// @dev Authorizes an upgrade only when it matches a schedule whose delay has elapsed.
    ///      The schedule is consumed here, so a replay needs a fresh `scheduleUpgrade`.
    function _authorizeUpgrade(address newImplementation) internal override {
        _checkUpgradeAuthority(msg.sender);

        ScheduledUpgrade storage pending = _scheduledUpgradeStorage();
        if (pending.implementation == address(0) || pending.implementation != newImplementation) {
            revert UpgradeNotScheduled(newImplementation);
        }
        if (block.timestamp < pending.executableAt) {
            revert UpgradeDelayNotElapsed(pending.executableAt, block.timestamp);
        }

        _clearScheduledUpgrade(pending);
        emit UpgradeExecuted(newImplementation);
    }

    /// @dev Reverts when `account` may not schedule, cancel, or execute upgrades.
    function _checkUpgradeAuthority(address account) internal view virtual;

    function _clearScheduledUpgrade(ScheduledUpgrade storage pending) private {
        pending.implementation = address(0);
        pending.scheduledAt = 0;
        pending.executableAt = 0;
    }

    function _scheduledUpgradeStorage() private pure returns (ScheduledUpgrade storage pending) {
        bytes32 slot = _SCHEDULED_UPGRADE_SLOT;
        // solhint-disable-next-line no-inline-assembly
        assembly {
            pending.slot := slot
        }
    }
}
