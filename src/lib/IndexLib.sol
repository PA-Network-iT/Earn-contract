// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {EarnTypes} from "src/types/EarnTypes.sol";

/// @notice Index math for the EARN product.
/// @dev The protocol tracks value with a monotonically increasing index in ray precision (1e27).
///      Growth is *simple* (linear) inside each APR checkpoint: an anchor index is stored when a
///      checkpoint starts, and the index grows linearly with elapsed time until the next
///      checkpoint takes over. This keeps the math exact, cheap, and auditable, and it matches the
///      product promise of a flat target APR.
library IndexLib {
    /// @dev Ray precision used by every index value.
    uint256 internal constant ONE_RAY = 1e27;
    /// @dev Basis point denominator.
    uint256 internal constant BPS_DENOMINATOR = 10_000;
    /// @dev Seconds in one accrual year.
    uint256 internal constant YEAR_IN_SECONDS = 365 days;

    /// @notice Returns the protocol index at a given timestamp.
    /// @param versions APR checkpoints ordered by start time.
    /// @param timestamp Timestamp used for materialization.
    /// @return Index in ray precision.
    function currentIndex(EarnTypes.AprVersion[] storage versions, uint256 timestamp) internal view returns (uint256) {
        if (versions.length == 0) {
            return ONE_RAY;
        }

        EarnTypes.AprVersion storage version = versions[_versionIndexAtOrBefore(versions, timestamp)];
        return materializeIndex(version.anchorIndexRay, version.aprBps, timestamp - version.startTimestamp);
    }

    /// @notice Materializes an index from an anchor point.
    /// @param anchorIndexRay Index value at the anchor timestamp.
    /// @param aprBps Annual rate in basis points.
    /// @param elapsed Elapsed time in seconds since the anchor.
    /// @return Materialized index in ray precision.
    function materializeIndex(uint256 anchorIndexRay, uint256 aprBps, uint256 elapsed) internal pure returns (uint256) {
        return anchorIndexRay + ((anchorIndexRay * aprBps * elapsed) / (YEAR_IN_SECONDS * BPS_DENOMINATOR));
    }

    /// @notice Appends a new APR checkpoint anchored at the index value it will start from.
    /// @param versions APR checkpoints ordered by start time.
    /// @param aprBps Annual rate in basis points.
    /// @param timestamp Start time for the new checkpoint.
    function appendAprVersion(EarnTypes.AprVersion[] storage versions, uint256 aprBps, uint256 timestamp) internal {
        uint256 anchorIndexRay = currentIndex(versions, timestamp);
        versions.push(
            EarnTypes.AprVersion({
                startTimestamp: uint64(timestamp),
                aprBps: uint32(aprBps),
                anchorIndexRay: uint160(anchorIndexRay)
            })
        );
    }

    /// @notice Converts assets into shares at a given index.
    /// @param assets Asset amount in token decimals.
    /// @param indexRay Index in ray precision.
    /// @return Share amount.
    function previewSharesForDeposit(uint256 assets, uint256 indexRay) internal pure returns (uint256) {
        return (assets * ONE_RAY) / indexRay;
    }

    /// @notice Converts shares into assets at a given index.
    /// @param shares Share amount.
    /// @param indexRay Index in ray precision.
    /// @return Asset amount in token decimals.
    function previewAssetsForShares(uint256 shares, uint256 indexRay) internal pure returns (uint256) {
        return (shares * indexRay) / ONE_RAY;
    }

    /// @dev Returns the position of the latest checkpoint starting at or before `timestamp`.
    ///      Checkpoints are appended in chronological order and their count stays small (one per
    ///      APR change), so the linear scan is cheaper than a binary search in practice.
    function _versionIndexAtOrBefore(EarnTypes.AprVersion[] storage versions, uint256 timestamp)
        private
        view
        returns (uint256)
    {
        uint256 index = versions.length - 1;

        while (index > 0 && uint256(versions[index].startTimestamp) > timestamp) {
            index -= 1;
        }

        return index;
    }
}
