// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {EarnTestBase} from "test/shared/EarnTestBase.sol";
import {InvalidApr, PendingAprUpdate} from "test/shared/interfaces/EarnSpecInterfaces.sol";

/// @notice EN: Unit tests for APR checkpoints and linear index materialization across time.
/// @custom:fa تست‌های واحد برای checkpointهای APR و materialize شدن خطی index در طول زمان.
contract IndexCheckpointingTest is EarnTestBase {
    function test_currentIndexStartsAtOneRay() public view {
        assertEq(core.currentIndex(), ONE_RAY);
    }

    function test_indexGrowsLinearlyForAprPeriods() public {
        vm.prank(admin);
        core.setApr(APR_20_PERCENT_BPS);

        skip(24 hours + 180 days);

        assertEq(core.currentIndex(), _expectedLinearIndex(APR_20_PERCENT_BPS, 180 days));
    }

    function test_aprChangeMaterializesCurrentIndexBeforeNewVersionStarts() public {
        vm.prank(admin);
        core.setApr(APR_20_PERCENT_BPS);

        skip(24 hours + 90 days);
        uint256 checkpointedIndex = _expectedLinearIndex(APR_20_PERCENT_BPS, 90 days);

        vm.prank(admin);
        core.setApr(APR_10_PERCENT_BPS);

        assertEq(core.currentIndex(), checkpointedIndex);
    }

    function test_indexContinuesFromMaterializedAnchorAfterAprChange() public {
        vm.prank(admin);
        core.setApr(APR_20_PERCENT_BPS);

        skip(24 hours + 90 days);

        vm.prank(admin);
        core.setApr(APR_10_PERCENT_BPS);

        skip(24 hours);
        uint256 delayedActivationIndex = core.currentIndex();
        assertEq(delayedActivationIndex, _expectedLinearIndex(APR_20_PERCENT_BPS, 91 days));

        skip(89 days);
        assertEq(
            core.currentIndex(), _expectedLinearIndexFromAnchor(delayedActivationIndex, APR_10_PERCENT_BPS, 89 days)
        );
    }

    function test_setAprRevertsWhenAprExceedsSupportedRange() public {
        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(InvalidApr.selector, 10_001));
        core.setApr(10_001);
    }

    function test_indexUsesSingleDivisionForMaterializationPrecision() public {
        uint256 aprBps = 3_333;
        uint256 elapsed = 1_234_567;

        vm.prank(admin);
        core.setApr(aprBps);

        skip(24 hours + elapsed);

        uint256 expected = ONE_RAY + ((ONE_RAY * aprBps * elapsed) / (YEAR_IN_SECONDS * 10_000));
        assertEq(core.currentIndex(), expected);
    }

    function test_setAprIsScheduledAndDoesNotChangeIndexBeforeDelay() public {
        vm.prank(admin);
        core.setApr(APR_20_PERCENT_BPS);

        skip(12 hours);
        assertEq(core.currentIndex(), ONE_RAY);

        skip(12 hours + 90 days);
        assertEq(core.currentIndex(), _expectedLinearIndex(APR_20_PERCENT_BPS, 90 days));
    }

    function test_setAprRevertsWhenAnotherAprUpdateIsStillPending() public {
        vm.prank(admin);
        core.setApr(APR_20_PERCENT_BPS);

        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(PendingAprUpdate.selector, INDEX_START_TIMESTAMP + 24 hours));
        core.setApr(APR_10_PERCENT_BPS);
    }
}
