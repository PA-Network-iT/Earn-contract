// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {EarnTestBase} from "test/shared/EarnTestBase.sol";
import {Blacklisted} from "test/shared/interfaces/EarnSpecInterfaces.sol";

contract ComplianceTest is EarnTestBase {
    function test_blacklistedUserCannotDeposit() public {
        vm.prank(admin);
        core.setBlacklist(alice, true);

        assertTrue(core.isBlacklisted(alice));

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(Blacklisted.selector, alice));
        core.deposit(1_000e6, alice);
    }

    function test_blacklistedUserCannotRequestWithdrawal() public {
        vm.prank(alice);
        uint256 lotId = core.deposit(1_000e6, alice);

        vm.prank(admin);
        core.setBlacklist(alice, true);

        assertTrue(core.isBlacklisted(alice));

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(Blacklisted.selector, alice));
        core.requestWithdrawal(lotId, 100e6);
    }

    function test_blacklistAfterRequestBlocksExecuteWithdrawal() public {
        vm.prank(alice);
        uint256 lotId = core.deposit(1_000e6, alice);

        vm.prank(alice);
        core.requestWithdrawal(lotId, 500e6);

        vm.prank(admin);
        core.setBlacklist(alice, true);

        assertTrue(core.isBlacklisted(alice));

        skip(24 hours);

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(Blacklisted.selector, alice));
        core.executeWithdrawal();
    }

    function test_blacklistedAccountCurrentIndexFreezesAtBlacklistTimestamp() public {
        vm.prank(admin);
        core.setApr(APR_20_PERCENT_BPS);

        skip(24 hours + 30 days);
        uint256 indexAtBlacklist = core.currentIndex();

        vm.prank(admin);
        core.setBlacklist(alice, true);

        skip(30 days);

        assertEq(core.currentIndex(alice), indexAtBlacklist);
        assertGt(core.currentIndex(), indexAtBlacklist);
    }

    function test_sponsorAccrualStopsAtBlacklistTimestamp() public {
        vm.startPrank(admin);
        core.setSponsor(alice, sponsor);
        core.setSponsorRate(sponsor, 1_000);
        core.setApr(APR_20_PERCENT_BPS);
        vm.stopPrank();

        skip(24 hours);

        vm.prank(alice);
        core.deposit(1_000e6, alice);

        skip(30 days);

        vm.prank(admin);
        core.setBlacklist(alice, true);

        uint256 accruedAtBlacklist = core.sponsorAccount(sponsor).accrued;
        assertGt(accruedAtBlacklist, 0);

        skip(180 days);

        assertApproxEqAbs(core.sponsorAccount(sponsor).accrued, accruedAtBlacklist, 1);
    }

    function test_unblacklistingDoesNotRetroactivelyResumeSponsorAccrualForExistingLot() public {
        vm.startPrank(admin);
        core.setSponsor(alice, sponsor);
        core.setSponsorRate(sponsor, 1_000);
        core.setApr(APR_20_PERCENT_BPS);
        vm.stopPrank();

        skip(24 hours);

        vm.prank(alice);
        core.deposit(1_000e6, alice);

        skip(30 days);

        vm.prank(admin);
        core.setBlacklist(alice, true);

        uint256 accruedAtBlacklist = core.sponsorAccount(sponsor).accrued;

        skip(30 days);

        vm.prank(admin);
        core.setBlacklist(alice, false);

        skip(30 days);

        assertApproxEqAbs(core.sponsorAccount(sponsor).accrued, accruedAtBlacklist, 1);
    }

    function test_newLotOpenedAfterUnblacklistCanAccrueSponsorReward() public {
        vm.startPrank(admin);
        core.setSponsor(alice, sponsor);
        core.setSponsorRate(sponsor, 1_000);
        core.setApr(APR_20_PERCENT_BPS);
        vm.stopPrank();

        skip(24 hours);

        vm.prank(alice);
        core.deposit(1_000e6, alice);

        skip(30 days);

        vm.prank(admin);
        core.setBlacklist(alice, true);

        uint256 accruedAtBlacklist = core.sponsorAccount(sponsor).accrued;

        skip(30 days);

        vm.prank(admin);
        core.setBlacklist(alice, false);

        uint256 newLotStartIndex = core.currentIndex();

        vm.prank(alice);
        uint256 newLotId = core.deposit(1_000e6, alice);

        uint256 elapsedAfterUnblacklist = 30 days;
        skip(elapsedAfterUnblacklist);

        uint256 newLotProfit = _expectedAssetsForShares(core.lot(newLotId).shareAmount, core.currentIndex())
            - _expectedAssetsForShares(core.lot(newLotId).shareAmount, newLotStartIndex);
        uint256 expectedNewLotReward = (newLotProfit * 1_000) / 10_000;

        assertApproxEqAbs(core.sponsorAccount(sponsor).accrued, accruedAtBlacklist + expectedNewLotReward, 1);
    }

    function test_partialWithdrawalAfterUnblacklistDoesNotRestoreAccrualOnSplitLot() public {
        vm.startPrank(admin);
        core.setSponsor(alice, sponsor);
        core.setSponsorRate(sponsor, 1_000);
        core.setApr(APR_20_PERCENT_BPS);
        vm.stopPrank();

        skip(24 hours);

        vm.prank(alice);
        uint256 lotId = core.deposit(1_000e6, alice);

        skip(30 days);

        vm.prank(admin);
        core.setBlacklist(alice, true);

        uint256 accruedAtBlacklist = core.sponsorAccount(sponsor).accrued;

        skip(30 days);

        vm.prank(admin);
        core.setBlacklist(alice, false);

        vm.prank(alice);
        core.requestWithdrawal(lotId, 500e6);

        skip(30 days);

        assertApproxEqAbs(core.sponsorAccount(sponsor).accrued, accruedAtBlacklist, 1);
    }

    function test_blacklistedSponsorCannotClaimReward() public {
        vm.startPrank(admin);
        core.setSponsor(alice, sponsor);
        core.setSponsorRate(sponsor, 1_000);
        core.setApr(APR_20_PERCENT_BPS);
        vm.stopPrank();

        skip(24 hours);

        vm.prank(alice);
        core.deposit(1_000e6, alice);

        skip(180 days);

        vm.prank(admin);
        core.fundSponsorBudget(sponsor, 50e6);

        vm.prank(admin);
        core.setBlacklist(sponsor, true);

        assertTrue(core.isBlacklisted(sponsor));

        vm.prank(sponsor);
        vm.expectRevert(abi.encodeWithSelector(Blacklisted.selector, sponsor));
        core.claimSponsorReward(1e6);
    }
}
