// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

/// @notice Shared protocol data types.
/// @dev Field order is part of the external ABI (structs are returned by `lot`, `lotsByOwner`,
///      `withdrawalRequest`, and `totals`). Do not reorder without updating the frontend decoders.
library EarnTypes {
    /// @notice APR checkpoint used for index materialization.
    /// @param startTimestamp Moment from which `aprBps` applies.
    /// @param aprBps Annual rate in basis points active from `startTimestamp`.
    /// @param anchorIndexRay Index value at `startTimestamp`, in ray precision.
    struct AprVersion {
        uint64 startTimestamp;
        uint32 aprBps;
        uint160 anchorIndexRay;
    }

    /// @notice Deposit position tracked by the core.
    /// @param id Lot identifier.
    /// @param owner Lot owner.
    /// @param principalAssets Deposited principal still attributed to this lot.
    /// @param shareAmount Share balance backing this lot.
    /// @param entryIndexRay Index at deposit time.
    /// @param lastIndexRay Index at the last state-changing interaction.
    /// @param frozenIndexRay Index frozen by a pending full-lot withdrawal request.
    /// @param openedAt Deposit timestamp; drives the early withdrawal fee window.
    /// @param frozenAt Timestamp at which the lot was frozen by a withdrawal request.
    /// @param isFrozen True while a full-lot withdrawal request is pending.
    /// @param isClosed True once the lot has been fully withdrawn or force-closed.
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
    /// @param id Request identifier.
    /// @param owner Requesting account.
    /// @param lotIds Lots included in the request.
    /// @param shareAmounts Share amount withdrawn per lot, index-aligned with `lotIds`.
    /// @param assetAmountSnapshot Gross asset value frozen at request time.
    /// @param feeAmountSnapshot Early withdrawal fee frozen at request time.
    /// @param requestedAt Request timestamp.
    /// @param executableAt Earliest execution timestamp (request + 24h).
    /// @param executed True once settled.
    /// @param cancelled True once cancelled.
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
    /// @param userPrincipalLiability Sum of open lot principal.
    /// @param userYieldLiability Materialized yield owed to users.
    /// @param frozenWithdrawalLiability Net assets promised to pending withdrawal requests.
    /// @param treasuryReportedAssets Off-contract treasury assets reported by ops.
    struct ProductTotals {
        uint256 userPrincipalLiability;
        uint256 userYieldLiability;
        uint256 frozenWithdrawalLiability;
        uint256 treasuryReportedAssets;
    }
}
