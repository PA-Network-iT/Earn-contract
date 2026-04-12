// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

/// @notice Shared protocol data types.
library EarnTypes {
    /// @notice APR checkpoint used for index materialization.
    struct AprVersion {
        uint64 startTimestamp;
        uint32 aprBps;
        uint160 anchorIndexRay;
    }

    /// @notice Deposit position tracked by the core.
    /// @dev Field order is storage-packing aware (9 slots instead of 10).
    ///      Slot 7: owner(20) + openedAt(8) + isFrozen(1) + isClosed(1) = 30 bytes.
    ///      Slot 8: sponsor(20) + frozenAt(8) = 28 bytes.
    struct Lot {
        uint256 id;
        address owner;
        uint256 principalAssets;
        uint256 shareAmount;
        uint256 entryIndexRay;
        uint256 lastIndexRay;
        uint256 frozenIndexRay;
        uint256 lastSponsorAccumulatorRay;
        uint64 openedAt;
        uint64 frozenAt;
        bool isFrozen;
        bool isClosed;
        address sponsor;
    }

    /// @notice Pending withdrawal request for a user.
    struct WithdrawalRequest {
        uint256 id;
        address owner;
        uint256 lotId;
        uint256 shareAmount;
        uint256 assetAmountSnapshot;
        uint64 requestedAt;
        uint64 executableAt;
        bool executed;
        bool cancelled;
    }

    /// @notice Accounting state for a sponsor.
    struct SponsorAccount {
        uint256 accrued;
        uint256 claimable;
        uint256 claimed;
        uint256 lastAccumulatorRay;
    }

    /// @notice Sponsor rate checkpoint used for reward accrual.
    struct SponsorRateVersion {
        uint64 startTimestamp;
        uint32 sponsorRateBps;
        uint160 anchorIndexRay;
        uint160 anchorAccumulatorRay;
    }

    /// @notice Aggregate product liabilities and liquid balances.
    struct ProductTotals {
        uint256 userPrincipalLiability;
        uint256 userYieldLiability;
        uint256 frozenWithdrawalLiability;
        uint256 sponsorRewardLiability;
        uint256 sponsorRewardClaimable;
        uint256 bufferAssets;
        uint256 treasuryReportedAssets;
    }
}
