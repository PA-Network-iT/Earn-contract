// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

/// @notice Ops-facing view of the timelocked UUPS upgrade flow implemented by
///         `DelayedUUPSUpgradeable`.
/// @dev Implemented by `EarnCore`, `SubscriptionManager`, `SubscriptionNFT`, and `PackagePassNFT`.
interface IDelayedUpgradeable {
    /// @notice Minimum waiting time between scheduling and executing an implementation change.
    // solhint-disable-next-line func-name-mixedcase
    function UPGRADE_DELAY() external view returns (uint256);

    /// @notice Returns the pending implementation change.
    function scheduledUpgrade()
        external
        view
        returns (address implementation, uint64 scheduledAt, uint64 executableAt);

    /// @notice Starts the timelock for `newImplementation`.
    function scheduleUpgrade(address newImplementation) external;

    /// @notice Drops the pending implementation change.
    function cancelScheduledUpgrade() external;

    /// @notice Installs a scheduled implementation once its delay elapsed.
    function upgradeToAndCall(address newImplementation, bytes calldata data) external payable;
}
