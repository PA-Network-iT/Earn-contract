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
    struct Lot {
        uint256 id;
        address owner;
        uint256 principalAssets;
        uint256 shareAmount;
        uint256 entryIndexRay;
        uint256 lastIndexRay;
        uint256 frozenIndexRay;
        uint64 openedAt;
        uint64 frozenAt;
        bool isFrozen;
        bool isClosed;
    }

    /// @notice Lot slice requested as part of a batch withdrawal.
    struct WithdrawalLotInput {
        uint256 lotId;
        uint256 shareAmount;
    }

    /// @notice Pending withdrawal request for a user.
    struct WithdrawalRequest {
        uint256 id;
        address owner;
        uint256[] lotIds;
        uint256[] shareAmounts;
        uint256 assetAmountSnapshot;
        uint256 feeAmountSnapshot;
        uint64 requestedAt;
        uint64 executableAt;
        bool executed;
        bool cancelled;
    }

    /// @notice Aggregate product liabilities and liquid balances.
    struct ProductTotals {
        uint256 userPrincipalLiability;
        uint256 userYieldLiability;
        uint256 frozenWithdrawalLiability;
        uint256 treasuryReportedAssets;
    }
}
