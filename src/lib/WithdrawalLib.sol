// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {IndexLib} from "src/lib/IndexLib.sol";

/// @notice Withdrawal helpers shared by the request / cancel / execute flow.
library WithdrawalLib {
    /// @notice Cooldown between requesting and executing a withdrawal.
    /// @dev Product rule: ops get roughly one business day to source liquidity, and the user has
    ///      to come back and execute the request themselves.
    uint256 internal constant WITHDRAWAL_LOCK_PERIOD = 24 hours;

    /// @notice Snapshots the asset value of shares at a frozen index.
    /// @param shareAmount Share amount being withdrawn.
    /// @param frozenIndexRay Frozen index in ray precision.
    /// @return Asset value at the snapshot point.
    function snapshotAssetsForShares(uint256 shareAmount, uint256 frozenIndexRay) internal pure returns (uint256) {
        return IndexLib.previewAssetsForShares(shareAmount, frozenIndexRay);
    }

    /// @notice Returns the earliest execution time for a withdrawal request.
    /// @param requestedAt Request timestamp.
    /// @return Unlock timestamp.
    function executableAt(uint256 requestedAt) internal pure returns (uint64) {
        return uint64(requestedAt + WITHDRAWAL_LOCK_PERIOD);
    }

    /// @notice Splits an amount pro rata by shares.
    /// @dev Rounds down, which keeps the residual principal with the lot that stays open.
    /// @param totalAmount Total amount before the split.
    /// @param requestedShareAmount Share amount being extracted.
    /// @param totalShareAmount Total shares before the split.
    /// @return Pro rata amount.
    function splitProRata(uint256 totalAmount, uint256 requestedShareAmount, uint256 totalShareAmount)
        internal
        pure
        returns (uint256)
    {
        return (totalAmount * requestedShareAmount) / totalShareAmount;
    }
}
