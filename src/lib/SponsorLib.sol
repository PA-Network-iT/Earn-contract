// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {EarnTypes} from "src/types/EarnTypes.sol";
import {IndexLib} from "src/lib/IndexLib.sol";

/// @notice EN: Sponsor accrual helpers.
/// @custom:fa ابزارهای محاسبه accrual و پاداش sponsor.
library SponsorLib {
    using IndexLib for EarnTypes.AprVersion[];

    /// @notice Returns the sponsor accumulator at a given timestamp.
    /// @custom:fa accumulator اسپانسر را در timestamp مشخص محاسبه می‌کند.
    /// @param versions Sponsor rate checkpoints.
    /// @param aprVersions APR checkpoints.
    /// @param timestamp Timestamp used for materialization.
    /// @return Accumulator value in ray precision.
    function currentAccumulator(
        EarnTypes.SponsorRateVersion[] storage versions,
        EarnTypes.AprVersion[] storage aprVersions,
        uint256 timestamp
    ) internal view returns (uint256) {
        uint256 versionCount = versions.length;
        if (versionCount == 0) {
            return 0;
        }
        if (timestamp < uint256(versions[0].startTimestamp)) {
            return 0;
        }

        uint256 indexVersion = _versionIndexAtOrBefore(versions, timestamp);
        EarnTypes.SponsorRateVersion storage version = versions[indexVersion];
        uint256 currentIndexRay = aprVersions.currentIndex(timestamp);

        return version.anchorAccumulatorRay
            + (
                ((currentIndexRay - uint256(version.anchorIndexRay)) * uint256(version.sponsorRateBps))
                    / IndexLib.BPS_DENOMINATOR
            );
    }

    /// @notice Appends a new sponsor rate checkpoint.
    /// @custom:fa یک checkpoint جدید برای نرخ sponsor اضافه می‌کند.
    /// @param versions Sponsor rate checkpoints.
    /// @param aprVersions APR checkpoints.
    /// @param sponsorRateBps Sponsor rate in basis points.
    /// @param timestamp Start time for the new checkpoint.
    function appendRateVersion(
        EarnTypes.SponsorRateVersion[] storage versions,
        EarnTypes.AprVersion[] storage aprVersions,
        uint256 sponsorRateBps,
        uint256 timestamp
    ) internal {
        uint256 anchorAccumulatorRay = currentAccumulator(versions, aprVersions, timestamp);
        uint256 anchorIndexRay = aprVersions.currentIndex(timestamp);

        versions.push(
            EarnTypes.SponsorRateVersion({
                startTimestamp: uint64(timestamp),
                sponsorRateBps: uint32(sponsorRateBps),
                anchorIndexRay: uint160(anchorIndexRay),
                anchorAccumulatorRay: uint160(anchorAccumulatorRay)
            })
        );
    }

    /// @notice Converts an accumulator delta into assets.
    /// @custom:fa deltaی accumulator را به مقدار دارایی قابل پرداخت تبدیل می‌کند.
    /// @param principalAssets Principal or notional amount in asset units.
    /// @param accumulatorDeltaRay Accumulator delta in ray precision.
    /// @return Reward amount in asset units.
    function rewardFromAccumulatorDelta(uint256 principalAssets, uint256 accumulatorDeltaRay)
        internal
        pure
        returns (uint256)
    {
        return (principalAssets * accumulatorDeltaRay) / IndexLib.ONE_RAY;
    }

    /// @notice Computes accrued sponsor reward for a lot.
    /// @custom:fa پاداش accrued اسپانسر را برای یک lot محاسبه می‌کند.
    /// @param versions Sponsor rate checkpoints.
    /// @param aprVersions APR checkpoints.
    /// @param shareAmount Lot share amount.
    /// @param entryIndexRay Lot entry index in ray precision.
    /// @param openedAt Lot open timestamp.
    /// @param timestamp Requested accrual timestamp.
    /// @param blacklistTimestamp Optional blacklist cutoff.
    /// @param frozenTimestamp Optional withdrawal freeze cutoff.
    /// @return reward Accrued reward in asset units.
    function accruedRewardForLot(
        EarnTypes.SponsorRateVersion[] storage versions,
        EarnTypes.AprVersion[] storage aprVersions,
        uint256 shareAmount,
        uint256 entryIndexRay,
        uint256 openedAt,
        uint256 timestamp,
        uint256 blacklistTimestamp,
        uint256 frozenTimestamp
    ) internal view returns (uint256 reward) {
        uint256 effectiveTimestamp = cappedTimestamp(timestamp, blacklistTimestamp, frozenTimestamp);
        if (versions.length == 0 || effectiveTimestamp <= openedAt) {
            return 0;
        }

        for (uint256 i = 0; i < versions.length; i++) {
            reward += _segmentReward(versions, aprVersions, shareAmount, entryIndexRay, openedAt, effectiveTimestamp, i);
        }
    }

    /// @notice Applies blacklist and freeze caps to a timestamp.
    /// @custom:fa capهای blacklist و freeze را روی timestamp اعمال می‌کند.
    /// @param timestamp Requested timestamp.
    /// @param blacklistTimestamp Blacklist cutoff.
    /// @param frozenTimestamp Freeze cutoff.
    /// @return Capped timestamp.
    function cappedTimestamp(uint256 timestamp, uint256 blacklistTimestamp, uint256 frozenTimestamp)
        internal
        pure
        returns (uint256)
    {
        uint256 capped = timestamp;

        if (blacklistTimestamp != 0 && blacklistTimestamp < capped) {
            capped = blacklistTimestamp;
        }
        if (frozenTimestamp != 0 && frozenTimestamp < capped) {
            capped = frozenTimestamp;
        }

        return capped;
    }

    function _versionIndexAtOrBefore(EarnTypes.SponsorRateVersion[] storage versions, uint256 timestamp)
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

    function _segmentReward(
        EarnTypes.SponsorRateVersion[] storage versions,
        EarnTypes.AprVersion[] storage aprVersions,
        uint256 shareAmount,
        uint256 entryIndexRay,
        uint256 openedAt,
        uint256 effectiveTimestamp,
        uint256 versionIndex
    ) private view returns (uint256 reward) {
        EarnTypes.SponsorRateVersion storage version = versions[versionIndex];

        uint256 segmentStart = openedAt;
        if (uint256(version.startTimestamp) > segmentStart) {
            segmentStart = uint256(version.startTimestamp);
        }

        uint256 segmentEnd = effectiveTimestamp;
        if (versionIndex + 1 < versions.length) {
            uint256 nextStart = uint256(versions[versionIndex + 1].startTimestamp);
            if (nextStart < segmentEnd) {
                segmentEnd = nextStart;
            }
        }

        if (segmentEnd <= segmentStart) {
            return 0;
        }

        uint256 indexStartRay = segmentStart == openedAt ? entryIndexRay : aprVersions.currentIndex(segmentStart);
        uint256 indexEndRay = aprVersions.currentIndex(segmentEnd);

        if (indexEndRay <= indexStartRay) {
            return 0;
        }

        uint256 profitAssets = (shareAmount * (indexEndRay - indexStartRay)) / IndexLib.ONE_RAY;
        return (profitAssets * uint256(version.sponsorRateBps)) / IndexLib.BPS_DENOMINATOR;
    }
}
