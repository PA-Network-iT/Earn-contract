// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {EarnTestBase} from "test/shared/EarnTestBase.sol";

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
}
