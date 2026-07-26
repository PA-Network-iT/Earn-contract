// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

/// @notice Ops-facing view of the two-step treasury wallet rotation implemented by
///         `TreasuryWalletTimelock`.
/// @dev Implemented by `EarnCore` and `SubscriptionManager`.
interface ITreasuryWalletTimelock {
    /// @notice Minimum waiting time between proposing and accepting a treasury wallet.
    // solhint-disable-next-line func-name-mixedcase
    function TREASURY_WALLET_CHANGE_DELAY() external view returns (uint256);

    /// @notice Returns the active treasury wallet.
    function treasuryWallet() external view returns (address);

    /// @notice Returns the pending treasury wallet rotation.
    function pendingTreasuryWallet() external view returns (address wallet, uint64 proposedAt, uint64 executableAt);

    /// @notice Starts a treasury wallet rotation.
    function proposeTreasuryWallet(address newTreasuryWallet) external;

    /// @notice Installs a previously proposed treasury wallet once the delay elapsed.
    function acceptTreasuryWallet(address expectedTreasuryWallet) external;

    /// @notice Drops the pending treasury wallet rotation.
    function cancelTreasuryWalletProposal() external;
}
