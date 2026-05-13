// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {EarnTestBase} from "test/shared/EarnTestBase.sol";
import {Blacklisted, WithdrawalLotInputView} from "test/shared/interfaces/EarnSpecInterfaces.sol";

/// @notice Unit tests for blacklist restrictions and historical accrual caps.
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
        core.requestWithdrawal(_singleWithdrawal(lotId, 100e6));
    }

    function test_blacklistAfterRequestBlocksExecuteWithdrawal() public {
        vm.prank(alice);
        uint256 lotId = core.deposit(1_000e6, alice);

        vm.prank(alice);
        core.requestWithdrawal(_singleWithdrawal(lotId, 500e6));

        vm.prank(admin);
        core.setBlacklist(alice, true);

        assertTrue(core.isBlacklisted(alice));

        skip(24 hours);

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(Blacklisted.selector, alice));
        core.executeWithdrawal();
    }

    function test_forceWithdrawBlacklistedCancelsBatchContainingTargetLot() public {
        vm.prank(admin);
        core.setTreasuryRatio(0);

        uint256 firstLotId = _deposit(alice, 1_000e6, alice);
        uint256 secondLotId = _deposit(alice, 2_000e6, alice);

        WithdrawalLotInputView[] memory withdrawals = new WithdrawalLotInputView[](2);
        withdrawals[0] = WithdrawalLotInputView({lotId: firstLotId, shareAmount: 4_000e6});
        withdrawals[1] = WithdrawalLotInputView({lotId: secondLotId, shareAmount: 20_000e6});

        vm.prank(alice);
        core.requestWithdrawal(withdrawals);

        vm.prank(admin);
        core.setBlacklist(alice, true);

        vm.prank(admin);
        uint256 assetsPaid = core.forceWithdrawBlacklisted(alice, secondLotId);

        assertEq(assetsPaid, 2_000e6);
        assertTrue(core.withdrawalRequest(alice).cancelled);
        assertEq(shareToken.lockedBalanceOf(alice), 0);
        assertEq(shareToken.balanceOf(alice), 10_000e6);
        assertEq(core.lot(firstLotId).shareAmount, 10_000e6);
        assertEq(core.lot(firstLotId).principalAssets, 1_000e6);
        assertTrue(core.lot(secondLotId).isClosed);
    }

    function test_forceWithdrawBlacklistedCancelsBatchWhenTargetLotWasPartial() public {
        vm.prank(admin);
        core.setTreasuryRatio(0);

        uint256 firstLotId = _deposit(alice, 1_000e6, alice);
        uint256 secondLotId = _deposit(alice, 2_000e6, alice);

        WithdrawalLotInputView[] memory withdrawals = new WithdrawalLotInputView[](2);
        withdrawals[0] = WithdrawalLotInputView({lotId: firstLotId, shareAmount: 4_000e6});
        withdrawals[1] = WithdrawalLotInputView({lotId: secondLotId, shareAmount: 20_000e6});

        vm.prank(alice);
        core.requestWithdrawal(withdrawals);

        vm.prank(admin);
        core.setBlacklist(alice, true);

        vm.prank(admin);
        uint256 assetsPaid = core.forceWithdrawBlacklisted(alice, firstLotId);

        assertEq(assetsPaid, 1_000e6);
        assertTrue(core.withdrawalRequest(alice).cancelled);
        assertEq(shareToken.lockedBalanceOf(alice), 0);
        assertEq(shareToken.balanceOf(alice), 20_000e6);
        assertTrue(core.lot(firstLotId).isClosed);
        assertFalse(core.lot(secondLotId).isClosed);
        assertEq(core.lot(secondLotId).shareAmount, 20_000e6);
        assertEq(core.lot(secondLotId).principalAssets, 2_000e6);
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

    function test_reblacklistingCreatesNewYieldCapAtCurrentTimestamp() public {
        vm.prank(admin);
        core.setApr(APR_20_PERCENT_BPS);

        skip(24 hours);

        vm.prank(alice);
        core.deposit(1_000e6, alice);

        skip(90 days);

        vm.prank(admin);
        core.setBlacklist(alice, true);

        uint256 liabilityAtFirstBlacklist = core.totals().userYieldLiability;
        assertGt(liabilityAtFirstBlacklist, 0);

        vm.prank(admin);
        core.setBlacklist(alice, false);

        skip(180 days);

        vm.prank(admin);
        core.setBlacklist(alice, true);

        uint256 liabilityAtSecondBlacklist = core.totals().userYieldLiability;
        assertGt(liabilityAtSecondBlacklist, liabilityAtFirstBlacklist);
    }
}
