// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {EarnTypes} from "src/types/EarnTypes.sol";

/// @dev EN: Storage layout for `EarnCore`.
/// @custom:fa چیدمان storage قرارداد `EarnCore`.
/// @dev EN: Field order stays append-only for proxy safety.
/// @custom:fa-dev ترتیب فیلدها برای امنیت proxy فقط باید append-only تغییر کند.
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
    /// @dev User to sponsor assignment.
    mapping(address user => address sponsor) internal _userSponsors;
    /// @dev Sponsor accounting by address.
    mapping(address sponsor => EarnTypes.SponsorAccount account) internal _sponsorAccounts;
    /// @dev Sponsor rate checkpoints by sponsor.
    mapping(address sponsor => EarnTypes.SponsorRateVersion[] versions) internal _sponsorRateVersions;
    /// @dev Blacklist flag by account.
    mapping(address account => bool isBlacklisted) internal _blacklisted;
    /// @dev Blacklist timestamp by account.
    mapping(address account => uint64 blacklistedAt) internal _blacklistTimestamps;
    /// @dev EN: First blacklist accrual cap per lot, used for yield and sponsor reward cutoffs.
    /// @custom:fa اولین cap ناشی از blacklist برای هر lot که برای توقف سود کاربر و پاداش sponsor استفاده می‌شود.
    mapping(uint256 lotId => uint64 sponsorAccrualCapAt) internal _lotSponsorAccrualCaps;
    /// @dev User lot registry.
    mapping(address user => uint256[] lotIds) internal _userLotIds;
    /// @dev Sponsor lot registry.
    mapping(address sponsor => uint256[] lotIds) internal _sponsorLotIds;
    /// @dev Known sponsor list.
    address[] internal _sponsors;
    /// @dev Membership map for the sponsor list.
    mapping(address sponsor => bool known) internal _knownSponsors;
    /// @dev Active sponsored shares by sponsor.
    mapping(address sponsor => uint256 activeShares) internal _sponsorActiveShares;
    /// @dev Global weighted sponsored share exposure.
    uint256 internal _globalSponsoredWeightedSharesBps;
    /// @dev Global sponsor liability index in ray precision.
    uint256 internal _globalSponsorLiabilityIndexRay;
    /// @dev Active withdrawal request id by owner.
    mapping(address owner => uint256 requestId) internal _activeWithdrawalRequestIds;
    /// @dev Protocol max sponsor rate in basis points.
    uint256 internal _maxSponsorRateBps;
    /// @dev Principal snapshot stored per request.
    mapping(uint256 requestId => uint256 principalAssets) internal _withdrawalRequestPrincipalAssets;
    /// @dev Active shares tracked per user and sponsor.
    mapping(address user => mapping(address sponsor => uint256 activeShares)) internal _userSponsorActiveShares;
    /// @dev Sponsor list tracked per user.
    mapping(address user => address[] sponsors) internal _userTrackedSponsors;
    /// @dev Membership map for each user sponsor list.
    mapping(address user => mapping(address sponsor => bool known)) internal _userKnownSponsors;
    /// @dev Minimum deposit in asset units.
    uint256 internal _minDeposit;

    /// @dev Reserved storage slots for future upgrades.
    uint256[49] private __gap;
}
