// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {EarnTestBase} from "test/shared/EarnTestBase.sol";

/// @notice Unit tests for principal, live yield, and frozen withdrawal liability accounting.
contract SolvencyAccountingTest is EarnTestBase {
    function test_totalsTrackLiveUserYieldLiabilityAfterIndexGrowth() public {
        vm.prank(admin);
        core.setApr(APR_20_PERCENT_BPS);

        skip(24 hours);

        vm.prank(alice);
        core.deposit(1_000e6, alice);

        uint256 elapsed = 180 days;
        skip(elapsed);

        assertEq(core.totals().userPrincipalLiability, 1_000e6);
        assertEq(core.totals().userYieldLiability, _expectedProfit(1_000e6, APR_20_PERCENT_BPS, elapsed));
    }

    function test_requestWithdrawalMovesSnapshotIntoFrozenLiability() public {
        vm.prank(admin);
        core.setApr(APR_20_PERCENT_BPS);

        skip(24 hours);

        vm.prank(alice);
        uint256 lotId = core.deposit(1_000e6, alice);

        skip(180 days);
        uint256 expectedSnapshot = _expectedAssetsForShares(500e6, core.currentIndex());

        vm.prank(alice);
        core.requestWithdrawal(lotId, 500e6);

        uint256 expectedRemainingYield = _expectedAssetsForShares(500e6, core.currentIndex()) - 500e6;

        assertEq(core.totals().userPrincipalLiability, 500e6);
        assertEq(core.totals().userYieldLiability, expectedRemainingYield);
        assertEq(core.totals().frozenWithdrawalLiability, expectedSnapshot);
    }

    function test_frozenWithdrawalLiabilityStopsGrowingAfterRequestSnapshot() public {
        vm.prank(alice);
        uint256 lotId = core.deposit(1_000e6, alice);

        vm.prank(alice);
        core.requestWithdrawal(lotId, 500e6);

        uint256 frozenLiability = core.totals().frozenWithdrawalLiability;
        assertGt(frozenLiability, 0);

        skip(180 days);

        assertEq(core.totals().frozenWithdrawalLiability, frozenLiability);
    }

    function test_yieldLiabilityTracksMultipleLotsIncrementally() public {
        vm.prank(admin);
        core.setApr(APR_20_PERCENT_BPS);

        skip(24 hours);

        vm.prank(alice);
        core.deposit(1_000e6, alice);
        vm.prank(bob);
        core.deposit(2_000e6, bob);

        uint256 elapsed = 180 days;
        skip(elapsed);

        uint256 expectedAliceYield = _expectedProfit(1_000e6, APR_20_PERCENT_BPS, elapsed);
        uint256 expectedBobYield = _expectedProfit(2_000e6, APR_20_PERCENT_BPS, elapsed);
        assertApproxEqAbs(core.totals().userYieldLiability, expectedAliceYield + expectedBobYield, 2);
    }

    function test_blacklistedLotYieldCapIsPreservedInTotals() public {
        vm.prank(admin);
        core.setApr(APR_20_PERCENT_BPS);

        skip(24 hours);

        vm.prank(alice);
        core.deposit(1_000e6, alice);

        skip(90 days);

        vm.prank(admin);
        core.setBlacklist(alice, true);

        uint256 cappedLiability = core.totals().userYieldLiability;
        assertGt(cappedLiability, 0);

        skip(180 days);

        assertApproxEqAbs(core.totals().userYieldLiability, cappedLiability, 1);
    }

    function test_cancelWithdrawalRestoresYieldTrackingForUncappedLot() public {
        vm.prank(admin);
        core.setApr(APR_20_PERCENT_BPS);

        skip(24 hours);

        vm.prank(alice);
        uint256 lotId = core.deposit(1_000e6, alice);

        skip(30 days);

        vm.prank(alice);
        core.requestWithdrawal(lotId, 1_000e6);

        assertEq(core.totals().userYieldLiability, 0);

        vm.prank(alice);
        core.cancelWithdrawal();

        skip(30 days);

        uint256 expectedYield = _expectedProfit(1_000e6, APR_20_PERCENT_BPS, 60 days);
        assertApproxEqAbs(core.totals().userYieldLiability, expectedYield, 1);
    }

    function test_cancelWithdrawalOnRehabilitatedLotRestoresUncappedYield() public {
        vm.prank(admin);
        core.setApr(APR_20_PERCENT_BPS);

        skip(24 hours);

        vm.prank(alice);
        uint256 lotId = core.deposit(1_000e6, alice);

        skip(30 days);

        vm.prank(alice);
        core.requestWithdrawal(lotId, 1_000e6);

        vm.prank(admin);
        core.setBlacklist(alice, true);

        assertEq(core.totals().userYieldLiability, 0);

        vm.prank(admin);
        core.setBlacklist(alice, false);

        vm.prank(alice);
        core.cancelWithdrawal();

        uint256 liabilityAfterCancel = core.totals().userYieldLiability;
        assertGt(liabilityAfterCancel, 0);

        skip(180 days);

        assertGt(core.totals().userYieldLiability, liabilityAfterCancel);
    }

    function test_partialWithdrawalReducesYieldLiabilityProportionally() public {
        vm.prank(admin);
        core.setApr(APR_20_PERCENT_BPS);

        skip(24 hours);

        vm.prank(alice);
        uint256 lotId = core.deposit(1_000e6, alice);

        skip(180 days);

        vm.prank(alice);
        core.requestWithdrawal(lotId, 500e6);

        uint256 expectedRemainingYield = _expectedProfit(500e6, APR_20_PERCENT_BPS, 180 days);
        assertApproxEqAbs(core.totals().userYieldLiability, expectedRemainingYield, 1);
    }
}
