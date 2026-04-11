// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

/// @notice EN: Shared protocol data types.
/// @custom:fa نوع‌های داده مشترک پروتکل.
library EarnTypes {
    /// @notice EN: APR checkpoint used for index materialization.
    /// @custom:fa checkpoint نرخ APR برای materialize کردن index.
    struct AprVersion {
        uint64 startTimestamp;
        uint32 aprBps;
        uint160 anchorIndexRay;
    }

    /// @notice EN: Deposit position tracked by the core.
    /// @custom:fa موقعیت سپرده‌ای که توسط هسته به شکل lot پیگیری می‌شود.
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

    /// @notice EN: Pending withdrawal request for a user.
    /// @custom:fa درخواست برداشت در انتظار اجرا برای یک کاربر.
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

    /// @notice EN: Accounting state for a sponsor.
    /// @custom:fa وضعیت حسابداری یک sponsor.
    struct SponsorAccount {
        uint256 accrued;
        uint256 claimable;
        uint256 claimed;
        uint256 lastAccumulatorRay;
    }

    /// @notice EN: Sponsor rate checkpoint used for reward accrual.
    /// @custom:fa checkpoint نرخ sponsor برای محاسبه accrual پاداش.
    struct SponsorRateVersion {
        uint64 startTimestamp;
        uint32 sponsorRateBps;
        uint160 anchorIndexRay;
        uint160 anchorAccumulatorRay;
    }

    /// @notice EN: Aggregate product liabilities and liquid balances.
    /// @custom:fa مجموع بدهی‌های محصول و موجودی‌های نقد.
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
