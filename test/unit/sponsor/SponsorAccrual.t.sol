// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {EarnTestBase} from "test/shared/EarnTestBase.sol";
import {SponsorRewardNotClaimable, InvalidSponsorRate, LotView} from "test/shared/interfaces/EarnSpecInterfaces.sol";

/// @notice EN: Unit tests for sponsor assignment, rate changes, accrual, funding, and claiming.
/// @custom:fa تست‌های واحد برای انتساب sponsor، تغییر نرخ، accrual، تامین بودجه و claim پاداش.
contract SponsorAccrualTest is EarnTestBase {
    function test_sponsorRateRevertsAboveDefaultConfiguredMaximum() public {
        assertEq(core.maxSponsorRateBps(), 2_000);

        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(InvalidSponsorRate.selector, 2_001));
        core.setSponsorRate(sponsor, 2_001);
    }

    function test_parameterManagerCanAdjustSponsorRateMaximumWithinHardSafetyCeiling() public {
        vm.prank(admin);
        core.setMaxSponsorRate(1_500);

        assertEq(core.maxSponsorRateBps(), 1_500);

        vm.prank(admin);
        core.setSponsorRate(sponsor, 1_500);
    }

    function test_parameterManagerCannotRaiseSponsorRateMaximumAboveHardSafetyCeiling() public {
        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(InvalidSponsorRate.selector, 2_001));
        core.setMaxSponsorRate(2_001);
    }

    function test_sponsorAssignmentComesFromPreRecordedUserConfig() public {
        vm.prank(admin);
        core.setSponsor(alice, sponsor);

        vm.prank(alice);
        uint256 lotId = core.deposit(1_000e6, alice);

        assertEq(core.lot(lotId).sponsor, sponsor);
    }

    function test_lotsBySponsorReturnsLotsLinkedToSponsor() public {
        vm.prank(admin);
        core.setSponsor(alice, sponsor);

        vm.prank(alice);
        uint256 aliceLotId = core.deposit(1_000e6, alice);

        vm.prank(bob);
        core.deposit(1_000e6, bob);

        LotView[] memory lots = core.lotsBySponsor(sponsor, 0, 10);

        assertEq(core.sponsorLotCount(sponsor), 1);
        assertEq(lots.length, 1);
        assertEq(lots[0].id, aliceLotId);
        assertEq(lots[0].owner, alice);
        assertEq(lots[0].sponsor, sponsor);
    }

    function test_lotsBySponsorSupportsPagination() public {
        vm.prank(admin);
        core.setSponsor(alice, sponsor);

        vm.startPrank(alice);
        core.deposit(1_000e6, alice);
        uint256 secondLotId = core.deposit(2_000e6, alice);
        vm.stopPrank();

        LotView[] memory lots = core.lotsBySponsor(sponsor, 1, 10);

        assertEq(lots.length, 1);
        assertEq(lots[0].id, secondLotId);
        assertEq(lots[0].sponsor, sponsor);
    }

    function test_sponsorRewardAccruesOnProfitNotPrincipal() public {
        vm.startPrank(admin);
        core.setSponsor(alice, sponsor);
        core.setSponsorRate(sponsor, 1_500);
        core.setApr(APR_20_PERCENT_BPS);
        vm.stopPrank();

        skip(24 hours);

        vm.prank(alice);
        core.deposit(1_000e6, alice);

        uint256 elapsed = 180 days;
        skip(elapsed);

        uint256 expectedReward = _expectedSponsorReward(1_000e6, APR_20_PERCENT_BPS, 1_500, elapsed);
        assertEq(core.sponsorAccount(sponsor).accrued, expectedReward);
        assertEq(core.totals().sponsorRewardLiability, expectedReward);
    }

    function test_sponsorRewardForLateDepositUsesShareCheckpointNotPrincipal() public {
        vm.startPrank(admin);
        core.setSponsor(alice, sponsor);
        core.setSponsorRate(sponsor, 1_500);
        core.setApr(APR_20_PERCENT_BPS);
        vm.stopPrank();

        skip(24 hours + 180 days);
        uint256 depositIndex = core.currentIndex();

        vm.prank(alice);
        uint256 lotId = core.deposit(1_000e6, alice);

        uint256 elapsed = 180 days;
        skip(elapsed);

        uint256 currentValue = _expectedAssetsForShares(core.lot(lotId).shareAmount, core.currentIndex());
        uint256 depositedValue = _expectedAssetsForShares(core.lot(lotId).shareAmount, depositIndex);
        uint256 expectedReward = ((currentValue - depositedValue) * 1_500) / 10_000;

        assertEq(core.sponsorAccount(sponsor).accrued, expectedReward);
    }

    function test_sponsorRateChangeAppliesOnlyGoingForward() public {
        vm.startPrank(admin);
        core.setSponsor(alice, sponsor);
        core.setSponsorRate(sponsor, 1_000);
        core.setApr(APR_20_PERCENT_BPS);
        vm.stopPrank();

        skip(24 hours);

        vm.prank(alice);
        core.deposit(1_000e6, alice);

        uint256 firstElapsed = 90 days;
        skip(firstElapsed);

        vm.prank(admin);
        core.setSponsorRate(sponsor, 2_000);

        uint256 secondElapsed = 90 days;
        skip(secondElapsed);

        uint256 expectedReward =
            _expectedPiecewiseSponsorReward(1_000e6, APR_20_PERCENT_BPS, 1_000, firstElapsed, 2_000, secondElapsed);
        assertEq(core.sponsorAccount(sponsor).accrued, expectedReward);
    }

    function test_cancelPartialWithdrawalDoesNotOverRestoreSponsorExposure() public {
        vm.startPrank(admin);
        core.setSponsor(alice, sponsor);
        core.setSponsorRate(sponsor, 1_000);
        core.setApr(APR_20_PERCENT_BPS);
        vm.stopPrank();

        skip(24 hours);

        vm.prank(alice);
        uint256 lotId = core.deposit(1_000e6, alice);

        skip(30 days);

        vm.prank(alice);
        core.requestWithdrawal(lotId, 250e6);

        skip(30 days);

        vm.prank(alice);
        core.cancelWithdrawal();

        skip(30 days);

        uint256 expectedReward = _expectedSponsorReward(1_000e6, APR_20_PERCENT_BPS, 1_000, 30 days)
            + _expectedSponsorReward(750e6, APR_20_PERCENT_BPS, 1_000, 30 days)
            + _expectedSponsorReward(1_000e6, APR_20_PERCENT_BPS, 1_000, 30 days);
        assertApproxEqAbs(core.sponsorAccount(sponsor).accrued, expectedReward, 1);
    }

    function test_sponsorAccrualSpansSponsorRateAndAprVersionBoundaries() public {
        vm.startPrank(admin);
        core.setSponsor(alice, sponsor);
        core.setSponsorRate(sponsor, 1_000);
        core.setApr(APR_20_PERCENT_BPS);
        vm.stopPrank();

        skip(24 hours);

        vm.prank(alice);
        uint256 lotId = core.deposit(1_000e6, alice);

        skip(90 days);
        uint256 firstCheckpointIndex = core.currentIndex();

        vm.prank(admin);
        core.setSponsorRate(sponsor, 2_000);

        skip(90 days);
        uint256 secondCheckpointIndex = core.currentIndex();

        vm.prank(admin);
        core.setApr(APR_10_PERCENT_BPS);

        skip(24 hours);
        uint256 delayedAprCheckpointIndex = core.currentIndex();

        skip(90 days);
        uint256 finalIndex = core.currentIndex();
        uint256 shareAmount = core.lot(lotId).shareAmount;

        uint256 firstPeriodProfit = _expectedAssetsForShares(shareAmount, firstCheckpointIndex)
            - _expectedAssetsForShares(shareAmount, ONE_RAY);
        uint256 secondPeriodProfit = _expectedAssetsForShares(shareAmount, secondCheckpointIndex)
            - _expectedAssetsForShares(shareAmount, firstCheckpointIndex);
        uint256 delayedChangeProfit = _expectedAssetsForShares(shareAmount, delayedAprCheckpointIndex)
            - _expectedAssetsForShares(shareAmount, secondCheckpointIndex);
        uint256 postAprChangeProfit = _expectedAssetsForShares(shareAmount, finalIndex)
            - _expectedAssetsForShares(shareAmount, delayedAprCheckpointIndex);

        uint256 expectedReward = (firstPeriodProfit * 1_000) / 10_000 + (secondPeriodProfit * 2_000) / 10_000
            + (delayedChangeProfit * 2_000) / 10_000 + (postAprChangeProfit * 2_000) / 10_000;

        assertEq(core.sponsorAccount(sponsor).accrued, expectedReward);
    }

    function test_unfundedSponsorRewardIsAccruedButNotClaimable() public {
        vm.prank(sponsor);
        vm.expectRevert(abi.encodeWithSelector(SponsorRewardNotClaimable.selector, 0, 1e6));
        core.claimSponsorReward(1e6);
    }

    function test_fundedSponsorRewardBecomesClaimableAfterBudgetFunding() public {
        vm.startPrank(admin);
        core.setSponsor(alice, sponsor);
        core.setSponsorRate(sponsor, 1_500);
        core.setApr(APR_20_PERCENT_BPS);
        vm.stopPrank();

        skip(24 hours);

        vm.prank(alice);
        core.deposit(1_000e6, alice);

        uint256 elapsed = 180 days;
        skip(elapsed);

        uint256 expectedAccrued = _expectedSponsorReward(1_000e6, APR_20_PERCENT_BPS, 1_500, elapsed);
        assertEq(core.sponsorAccount(sponsor).accrued, expectedAccrued);

        vm.prank(admin);
        core.fundSponsorBudget(sponsor, expectedAccrued);

        assertEq(core.sponsorAccount(sponsor).claimable, expectedAccrued);
    }

    function test_claimSponsorRewardPaysFromClaimableBudgetAndUpdatesTotals() public {
        vm.startPrank(admin);
        core.setSponsor(alice, sponsor);
        core.setSponsorRate(sponsor, 1_500);
        core.setApr(APR_20_PERCENT_BPS);
        vm.stopPrank();

        skip(24 hours);

        vm.prank(alice);
        core.deposit(1_000e6, alice);

        uint256 elapsed = 180 days;
        skip(elapsed);

        uint256 expectedAccrued = _expectedSponsorReward(1_000e6, APR_20_PERCENT_BPS, 1_500, elapsed);

        vm.prank(admin);
        core.fundSponsorBudget(sponsor, expectedAccrued);

        uint256 sponsorAssetsBefore = assetToken.balanceOf(sponsor);

        vm.prank(sponsor);
        uint256 paidAmount = core.claimSponsorReward(1e6);

        assertEq(paidAmount, 1e6);
        assertEq(assetToken.balanceOf(sponsor), sponsorAssetsBefore + 1e6);
        assertEq(core.sponsorAccount(sponsor).claimed, 1e6);
        assertEq(core.sponsorAccount(sponsor).claimable, expectedAccrued - 1e6);
        assertEq(core.totals().sponsorRewardClaimable, expectedAccrued - 1e6);
        assertEq(core.totals().sponsorRewardLiability, expectedAccrued - 1e6);
    }

    function test_fundingOneSponsorDoesNotAllocateClaimableToAnother() public {
        address secondSponsor = makeAddr("secondSponsor");

        vm.startPrank(admin);
        core.setSponsor(alice, sponsor);
        core.setSponsor(bob, secondSponsor);
        core.setSponsorRate(sponsor, 1_000);
        core.setSponsorRate(secondSponsor, 2_000);
        core.setApr(APR_20_PERCENT_BPS);
        vm.stopPrank();

        skip(24 hours);

        vm.prank(alice);
        core.deposit(1_000e6, alice);
        vm.prank(bob);
        core.deposit(1_000e6, bob);

        skip(180 days);

        uint256 expectedFirstSponsorAccrued = _expectedSponsorReward(1_000e6, APR_20_PERCENT_BPS, 1_000, 180 days);

        vm.prank(admin);
        core.fundSponsorBudget(sponsor, expectedFirstSponsorAccrued);

        assertEq(core.sponsorAccount(sponsor).claimable, expectedFirstSponsorAccrued);
        assertEq(core.sponsorAccount(secondSponsor).claimable, 0);
    }
}
