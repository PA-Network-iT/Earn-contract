// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {EarnTypes} from "src/types/EarnTypes.sol";

/// @dev Storage layout for `EarnCore`.
/// @dev Legacy passive-earn storage was removed from this branch, so existing proxy deployments
///      require a fresh deploy or explicit migration before upgrading to this layout.
abstract contract EarnStorage {
    /// @dev Underlying asset used for deposits and withdrawals.
    address internal _asset;
    /// @dev Share token controlled by the core.
    address internal _shareToken;

    /// @dev Monotonic identifier for newly created lots.
    uint256 internal _nextLotId;
    /// @dev Treasury allocation in basis points.
    uint256 internal _treasuryRatioBps;

    /// @dev APR checkpoints used for index materialization.
    EarnTypes.AprVersion[] internal _aprVersions;
    /// @dev Aggregate protocol accounting.
    EarnTypes.ProductTotals internal _totals;

    /// @dev Lot state by lot id.
    mapping(uint256 lotId => EarnTypes.Lot lot) internal _lots;
    /// @dev Monotonic identifier for withdrawal requests.
    uint256 internal _nextRequestId;
    /// @dev Withdrawal request state by request id.
    mapping(uint256 requestId => EarnTypes.WithdrawalRequest request) internal _withdrawalRequests;
    /// @dev Pause flag for withdrawal requests.
    bool internal _requestWithdrawalPaused;
    /// @dev Pause flag for withdrawal execution.
    bool internal _executeWithdrawalPaused;
    /// @dev Blacklist flag by account.
    mapping(address account => bool isBlacklisted) internal _blacklisted;
    /// @dev Blacklist timestamp by account.
    mapping(address account => uint64 blacklistedAt) internal _blacklistTimestamps;
    /// @dev First blacklist accrual cap per lot, used for yield cutoffs.
    mapping(uint256 lotId => uint64 accrualCapAt) internal _lotAccrualCaps;
    /// @dev User lot registry.
    mapping(address user => uint256[] lotIds) internal _userLotIds;
    /// @dev Active withdrawal request id by owner.
    mapping(address owner => uint256 requestId) internal _activeWithdrawalRequestIds;
    /// @dev Principal snapshots stored per request item.
    mapping(uint256 requestId => uint256[] principalAssets) internal _withdrawalRequestPrincipalAssets;
    /// @dev Minimum deposit in asset units.
    uint256 internal _minDeposit;
    /// @dev Early withdrawal fee in basis points for lots younger than one year.
    uint256 internal _earlyWithdrawalFeeBps;

    /// @dev Treasury wallet that receives the treasury portion of deposits.
    address internal _treasuryWallet;

    /// @dev Total shares of active lots not subject to a blacklist yield cap.
    uint256 internal _totalUncappedShares;
    /// @dev Total principal of active lots not subject to a blacklist yield cap.
    uint256 internal _totalUncappedPrincipal;
    /// @dev Pre-computed yield liability for lots whose yield is frozen at a blacklist cap.
    uint256 internal _cappedYieldLiability;

    /// @dev SubscriptionManager gate address. Zero means the gate is inactive (pre-wiring).
    address internal _subscriptionManager;

    /// @dev Backend signer trusted for EIP-712 KYC authorizations.
    address internal _kycSigner;
    /// @dev Per-user nonce consumed when a KYC authorization is accepted.
    mapping(address user => uint256 nonce) internal _kycNonces;
    /// @dev Capped cumulative deposited assets used for threshold-based KYC gating.
    mapping(address user => uint256 assets) internal _cumulativeDeposited;

    /// @dev Reserved storage slots for future upgrades.
    uint256[41] private __gap;
}
