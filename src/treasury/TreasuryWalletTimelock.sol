// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

/// @dev Reverts when a treasury wallet candidate is zero.
error InvalidTreasuryWallet(address treasuryWallet);
/// @dev Reverts when accepting or cancelling while no proposal exists.
error NoPendingTreasuryWallet();
/// @dev Reverts when the proposal timelock has not elapsed yet.
error TreasuryWalletDelayNotElapsed(uint256 executableAt, uint256 currentTime);
/// @dev Reverts when the accepted address does not match the pending proposal.
error UnexpectedTreasuryWallet(address expected, address pending);
/// @dev Reverts on the deprecated single-step setter.
error TreasuryWalletChangeIsTwoStep();

/// @notice Two-step, timelocked treasury wallet rotation.
/// @dev The treasury wallet receives protocol revenue, so a single compromised admin key must not
///      be able to redirect it inside one transaction. Rotation is therefore split into
///      `propose` (starts the delay, emits a public event) and `accept` (installs the wallet once
///      `TREASURY_WALLET_CHANGE_DELAY` has elapsed). A pending proposal can be cancelled at any
///      time.
///
///      The pending proposal lives in a dedicated namespaced slot so inheriting contracts keep
///      their own sequential storage layout. The active wallet itself stays in the inheriting
///      contract's storage, reachable through `treasuryWallet()` / `_writeTreasuryWallet`.
abstract contract TreasuryWalletTimelock {
    /// @notice Minimum waiting time between proposing and accepting a treasury wallet.
    uint256 public constant TREASURY_WALLET_CHANGE_DELAY = 24 hours;

    /// @notice Pending treasury wallet rotation.
    /// @param wallet Proposed wallet, zero when nothing is pending.
    /// @param proposedAt Timestamp of the proposal.
    /// @param executableAt Earliest timestamp at which the proposal may be accepted.
    struct PendingTreasuryWallet {
        address wallet;
        uint64 proposedAt;
        uint64 executableAt;
    }

    /// @dev Namespaced storage slot: `keccak256("pait.storage.TreasuryWalletTimelock.v1")`.
    bytes32 private constant _PENDING_TREASURY_WALLET_SLOT = keccak256("pait.storage.TreasuryWalletTimelock.v1");

    event TreasuryWalletProposed(address indexed newTreasuryWallet, uint256 proposedAt, uint256 executableAt);
    event TreasuryWalletProposalCancelled(address indexed cancelledTreasuryWallet);
    event TreasuryWalletUpdated(address indexed newTreasuryWallet);

    /// @notice Returns the active treasury wallet.
    function treasuryWallet() public view virtual returns (address);

    /// @notice Returns the pending treasury wallet rotation.
    /// @return wallet Proposed wallet, zero when nothing is pending.
    /// @return proposedAt Timestamp of the proposal.
    /// @return executableAt Earliest timestamp at which the proposal may be accepted.
    function pendingTreasuryWallet() external view returns (address wallet, uint64 proposedAt, uint64 executableAt) {
        PendingTreasuryWallet storage pending = _pendingTreasuryWalletStorage();
        return (pending.wallet, pending.proposedAt, pending.executableAt);
    }

    /// @dev Writes the active treasury wallet into the inheriting contract's storage.
    function _writeTreasuryWallet(address newTreasuryWallet) internal virtual;

    /// @dev Sets the treasury wallet during initialization, bypassing the timelock exactly once.
    function _initializeTreasuryWallet(address newTreasuryWallet) internal {
        if (newTreasuryWallet == address(0)) {
            revert InvalidTreasuryWallet(newTreasuryWallet);
        }
        _writeTreasuryWallet(newTreasuryWallet);
        emit TreasuryWalletUpdated(newTreasuryWallet);
    }

    /// @dev Starts the rotation timelock. Re-proposing overwrites the previous entry and restarts
    ///      the full delay.
    function _proposeTreasuryWallet(address newTreasuryWallet) internal {
        if (newTreasuryWallet == address(0)) {
            revert InvalidTreasuryWallet(newTreasuryWallet);
        }

        uint64 proposedAt = uint64(block.timestamp);
        uint64 executableAt = uint64(block.timestamp + TREASURY_WALLET_CHANGE_DELAY);

        PendingTreasuryWallet storage pending = _pendingTreasuryWalletStorage();
        pending.wallet = newTreasuryWallet;
        pending.proposedAt = proposedAt;
        pending.executableAt = executableAt;

        emit TreasuryWalletProposed(newTreasuryWallet, proposedAt, executableAt);
    }

    /// @dev Installs the pending wallet once the delay elapsed.
    /// @param expectedTreasuryWallet Address the caller believes is pending; guards against
    ///        accepting a proposal that was replaced after the caller signed.
    function _acceptTreasuryWallet(address expectedTreasuryWallet) internal {
        PendingTreasuryWallet storage pending = _pendingTreasuryWalletStorage();
        address wallet = pending.wallet;

        if (wallet == address(0)) {
            revert NoPendingTreasuryWallet();
        }
        if (wallet != expectedTreasuryWallet) {
            revert UnexpectedTreasuryWallet(expectedTreasuryWallet, wallet);
        }
        if (block.timestamp < pending.executableAt) {
            revert TreasuryWalletDelayNotElapsed(pending.executableAt, block.timestamp);
        }

        _clearPendingTreasuryWallet(pending);
        _writeTreasuryWallet(wallet);
        emit TreasuryWalletUpdated(wallet);
    }

    /// @dev Drops the pending rotation.
    function _cancelTreasuryWalletProposal() internal {
        PendingTreasuryWallet storage pending = _pendingTreasuryWalletStorage();
        address wallet = pending.wallet;
        if (wallet == address(0)) {
            revert NoPendingTreasuryWallet();
        }

        _clearPendingTreasuryWallet(pending);
        emit TreasuryWalletProposalCancelled(wallet);
    }

    function _clearPendingTreasuryWallet(PendingTreasuryWallet storage pending) private {
        pending.wallet = address(0);
        pending.proposedAt = 0;
        pending.executableAt = 0;
    }

    function _pendingTreasuryWalletStorage() private pure returns (PendingTreasuryWallet storage pending) {
        bytes32 slot = _PENDING_TREASURY_WALLET_SLOT;
        // solhint-disable-next-line no-inline-assembly
        assembly {
            pending.slot := slot
        }
    }
}
