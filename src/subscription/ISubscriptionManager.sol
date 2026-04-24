// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

/// @notice Minimal read-only interface consumed by EarnCore to gate user actions.
interface ISubscriptionManager {
    /// @notice Returns whether the given user has an unexpired subscription.
    /// @param user Account to check.
    /// @return active True when `_subscriptions[user].expiresAt > block.timestamp`.
    function hasActiveSubscription(address user) external view returns (bool active);
}
