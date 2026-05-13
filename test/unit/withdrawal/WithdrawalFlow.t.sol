// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {EarnTestBase} from "test/shared/EarnTestBase.sol";
import {
    WithdrawalLockNotElapsed,
    InsufficientLiquidity,
    RequestWithdrawalPaused,
    ExecuteWithdrawalPaused,
    ActiveWithdrawalRequest,
    Blacklisted,
    ZeroWithdrawalShares,
    InvalidWithdrawalLot,
    InvalidWithdrawalBatchSize,
    InvalidEarlyWithdrawalFee,
    WithdrawalLotInputView
} from "test/shared/interfaces/EarnSpecInterfaces.sol";

/// @notice Unit tests for withdrawal request, cancel, execution, locks, pauses, and liquidity failures.
contract WithdrawalFlowTest is EarnTestBase {
    function test_youngLotWithdrawalPaysNetAfterEarlyWithdrawalFee() public {
        vm.prank(admin);
        core.setTreasuryRatio(0);
        vm.prank(admin);
        core.setEarlyWithdrawalFeeBps(1_000);

        vm.prank(alice);
        uint256 lotId = core.deposit(1_000e6, alice);
        uint256 shares = shareToken.balanceOf(alice);

        vm.prank(alice);
        core.requestWithdrawal(_singleWithdrawal(lotId, shares / 2));

        assertEq(core.withdrawalRequest(alice).assetAmountSnapshot, 500e6);
        assertEq(core.withdrawalRequest(alice).feeAmountSnapshot, 50e6);
        assertEq(core.totals().frozenWithdrawalLiability, 450e6);

        uint256 aliceAssetsBefore = assetToken.balanceOf(alice);

        skip(24 hours);

        vm.prank(alice);
        uint256 assetsPaid = core.executeWithdrawal();

        assertEq(assetsPaid, 450e6);
        assertEq(assetToken.balanceOf(alice), aliceAssetsBefore + 450e6);
        assertEq(assetToken.balanceOf(address(core)), 550e6);
        assertEq(core.totals().frozenWithdrawalLiability, 0);
    }

    function test_youngLotWithdrawalUsesNetAmountForLiquidityCheck() public {
        vm.prank(admin);
        core.setTreasuryRatio(1_000);
        vm.prank(admin);
        core.setEarlyWithdrawalFeeBps(1_000);

        vm.prank(alice);
        uint256 lotId = core.deposit(1_000e6, alice);
        uint256 shares = shareToken.balanceOf(alice);

        vm.prank(alice);
        core.requestWithdrawal(_singleWithdrawal(lotId, shares));

        assertEq(core.withdrawalRequest(alice).assetAmountSnapshot, 1_000e6);
        assertEq(core.withdrawalRequest(alice).feeAmountSnapshot, 100e6);
        assertEq(core.availableLiquidity(), 900e6);

        skip(24 hours);

        vm.prank(alice);
        uint256 assetsPaid = core.executeWithdrawal();

        assertEq(assetsPaid, 900e6);
        assertEq(core.availableLiquidity(), 0);
    }

    function test_matureLotWithdrawalPaysFullSnapshotWithoutFee() public {
        vm.prank(admin);
        core.setTreasuryRatio(0);
        vm.prank(admin);
        core.setEarlyWithdrawalFeeBps(1_000);

        vm.prank(alice);
        uint256 lotId = core.deposit(1_000e6, alice);
        uint256 shares = shareToken.balanceOf(alice);

        skip(365 days);

        vm.prank(alice);
        core.requestWithdrawal(_singleWithdrawal(lotId, shares / 2));

        assertEq(core.withdrawalRequest(alice).assetAmountSnapshot, 500e6);
        assertEq(core.withdrawalRequest(alice).feeAmountSnapshot, 0);

        uint256 aliceAssetsBefore = assetToken.balanceOf(alice);

        skip(24 hours);

        vm.prank(alice);
        uint256 assetsPaid = core.executeWithdrawal();

        assertEq(assetsPaid, 500e6);
        assertEq(assetToken.balanceOf(alice), aliceAssetsBefore + 500e6);
    }

    function test_batchWithdrawalChargesFeeOnlyForYoungLotItems() public {
        vm.prank(admin);
        core.setTreasuryRatio(0);
        vm.prank(admin);
        core.setEarlyWithdrawalFeeBps(1_000);

        uint256 matureLotId = _deposit(alice, 1_000e6, alice);
        uint256 matureShares = shareToken.balanceOf(alice);

        skip(365 days);

        uint256 youngLotId = _deposit(alice, 1_000e6, alice);
        uint256 youngShares = shareToken.balanceOf(alice) - matureShares;

        WithdrawalLotInputView[] memory withdrawals = new WithdrawalLotInputView[](2);
        withdrawals[0] = WithdrawalLotInputView({lotId: matureLotId, shareAmount: matureShares / 2});
        withdrawals[1] = WithdrawalLotInputView({lotId: youngLotId, shareAmount: youngShares / 2});

        vm.prank(alice);
        core.requestWithdrawal(withdrawals);

        assertEq(core.withdrawalRequest(alice).assetAmountSnapshot, 1_000e6);
        assertEq(core.withdrawalRequest(alice).feeAmountSnapshot, 50e6);

        skip(24 hours);

        vm.prank(alice);
        uint256 assetsPaid = core.executeWithdrawal();

        assertEq(assetsPaid, 950e6);
    }

    function test_withdrawalFeeSnapshotDoesNotChangeAfterAdminFeeUpdate() public {
        vm.prank(admin);
        core.setTreasuryRatio(0);
        vm.prank(admin);
        core.setEarlyWithdrawalFeeBps(1_000);

        vm.prank(alice);
        uint256 lotId = core.deposit(1_000e6, alice);
        uint256 shares = shareToken.balanceOf(alice);

        vm.prank(alice);
        core.requestWithdrawal(_singleWithdrawal(lotId, shares / 2));

        vm.prank(admin);
        core.setEarlyWithdrawalFeeBps(5_000);

        skip(24 hours);

        vm.prank(alice);
        uint256 assetsPaid = core.executeWithdrawal();

        assertEq(assetsPaid, 450e6);
    }

    function test_setEarlyWithdrawalFeeRejectsAboveBpsDenominator() public {
        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(InvalidEarlyWithdrawalFee.selector, uint256(10_001)));
        core.setEarlyWithdrawalFeeBps(10_001);
    }

    function test_requestWithdrawalBatchLocksSharesAndTracksLots() public {
        uint256 firstLotId = _deposit(alice, 1_000e6, alice);
        uint256 secondLotId = _deposit(alice, 2_000e6, alice);

        WithdrawalLotInputView[] memory withdrawals = new WithdrawalLotInputView[](2);
        withdrawals[0] = WithdrawalLotInputView({lotId: firstLotId, shareAmount: 4_000e6});
        withdrawals[1] = WithdrawalLotInputView({lotId: secondLotId, shareAmount: 20_000e6});

        uint256 frozenIndex = core.currentIndex();
        uint256 expectedSnapshot = _expectedAssetsForShares(24_000e6, frozenIndex);

        vm.prank(alice);
        core.requestWithdrawal(withdrawals);

        assertEq(shareToken.lockedBalanceOf(alice), 24_000e6);
        assertEq(core.lot(firstLotId).shareAmount, 6_000e6);
        assertTrue(core.lot(secondLotId).isFrozen);

        assertEq(core.withdrawalRequest(alice).owner, alice);
        assertEq(core.withdrawalRequest(alice).lotIds.length, 2);
        assertEq(core.withdrawalRequest(alice).lotIds[0], firstLotId);
        assertEq(core.withdrawalRequest(alice).lotIds[1], secondLotId);
        assertEq(core.withdrawalRequest(alice).shareAmounts[0], 4_000e6);
        assertEq(core.withdrawalRequest(alice).shareAmounts[1], 20_000e6);
        assertEq(core.withdrawalRequest(alice).assetAmountSnapshot, expectedSnapshot);
    }

    function test_cancelWithdrawalBatchRestoresAllLots() public {
        uint256 firstLotId = _deposit(alice, 1_000e6, alice);
        uint256 secondLotId = _deposit(alice, 2_000e6, alice);

        WithdrawalLotInputView[] memory withdrawals = new WithdrawalLotInputView[](2);
        withdrawals[0] = WithdrawalLotInputView({lotId: firstLotId, shareAmount: 4_000e6});
        withdrawals[1] = WithdrawalLotInputView({lotId: secondLotId, shareAmount: 20_000e6});

        vm.prank(alice);
        core.requestWithdrawal(withdrawals);

        vm.prank(alice);
        core.cancelWithdrawal();

        assertTrue(core.withdrawalRequest(alice).cancelled);
        assertEq(shareToken.lockedBalanceOf(alice), 0);
        assertEq(core.lot(firstLotId).shareAmount, 10_000e6);
        assertEq(core.lot(firstLotId).principalAssets, 1_000e6);
        assertFalse(core.lot(secondLotId).isFrozen);
        assertEq(core.lot(secondLotId).shareAmount, 20_000e6);
        assertEq(core.lot(secondLotId).principalAssets, 2_000e6);
    }

    function test_cancelYoungLotWithdrawalUnwindsNetFrozenLiability() public {
        vm.prank(admin);
        core.setEarlyWithdrawalFeeBps(1_000);

        vm.prank(alice);
        uint256 lotId = core.deposit(1_000e6, alice);
        uint256 shares = shareToken.balanceOf(alice);

        vm.prank(alice);
        core.requestWithdrawal(_singleWithdrawal(lotId, shares));

        assertEq(core.withdrawalRequest(alice).assetAmountSnapshot, 1_000e6);
        assertEq(core.withdrawalRequest(alice).feeAmountSnapshot, 100e6);
        assertEq(core.totals().frozenWithdrawalLiability, 900e6);

        vm.prank(alice);
        core.cancelWithdrawal();

        assertTrue(core.withdrawalRequest(alice).cancelled);
        assertEq(core.totals().frozenWithdrawalLiability, 0);
        assertEq(core.totals().userPrincipalLiability, 1_000e6);
        assertEq(shareToken.lockedBalanceOf(alice), 0);
    }

    function test_executeWithdrawalBatchPaysAggregateSnapshotAndClosesFullLots() public {
        vm.prank(admin);
        core.setTreasuryRatio(0);

        uint256 firstLotId = _deposit(alice, 1_000e6, alice);
        uint256 secondLotId = _deposit(alice, 2_000e6, alice);

        WithdrawalLotInputView[] memory withdrawals = new WithdrawalLotInputView[](2);
        withdrawals[0] = WithdrawalLotInputView({lotId: firstLotId, shareAmount: 4_000e6});
        withdrawals[1] = WithdrawalLotInputView({lotId: secondLotId, shareAmount: 20_000e6});

        vm.prank(alice);
        core.requestWithdrawal(withdrawals);

        uint256 aliceAssetsBefore = assetToken.balanceOf(alice);
        uint256 expectedSnapshot = core.withdrawalRequest(alice).assetAmountSnapshot;

        skip(24 hours);

        vm.prank(alice);
        uint256 assetsPaid = core.executeWithdrawal();

        assertEq(assetsPaid, expectedSnapshot);
        assertEq(assetToken.balanceOf(alice), aliceAssetsBefore + expectedSnapshot);
        assertEq(shareToken.lockedBalanceOf(alice), 0);
        assertFalse(core.lot(firstLotId).isClosed);
        assertTrue(core.lot(secondLotId).isClosed);
        assertFalse(core.lot(secondLotId).isFrozen);
        assertTrue(core.withdrawalRequest(alice).executed);
    }

    function test_requestWithdrawalBatchRejectsDuplicateLotEntries() public {
        vm.prank(alice);
        uint256 lotId = core.deposit(1_000e6, alice);

        WithdrawalLotInputView[] memory withdrawals = new WithdrawalLotInputView[](2);
        withdrawals[0] = WithdrawalLotInputView({lotId: lotId, shareAmount: 1_000e6});
        withdrawals[1] = WithdrawalLotInputView({lotId: lotId, shareAmount: 1_000e6});

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(InvalidWithdrawalLot.selector, lotId));
        core.requestWithdrawal(withdrawals);
    }

    function test_requestWithdrawalBatchRejectsZeroShares() public {
        vm.prank(alice);
        uint256 lotId = core.deposit(1_000e6, alice);

        WithdrawalLotInputView[] memory withdrawals = new WithdrawalLotInputView[](1);
        withdrawals[0] = WithdrawalLotInputView({lotId: lotId, shareAmount: 0});

        vm.prank(alice);
        vm.expectRevert(ZeroWithdrawalShares.selector);
        core.requestWithdrawal(withdrawals);
    }

    function test_requestWithdrawalBatchRejectsEmptyArray() public {
        WithdrawalLotInputView[] memory withdrawals = new WithdrawalLotInputView[](0);

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(InvalidWithdrawalBatchSize.selector, uint256(0)));
        core.requestWithdrawal(withdrawals);
    }

    function test_requestWithdrawalBatchRejectsOversizedArray() public {
        WithdrawalLotInputView[] memory withdrawals = new WithdrawalLotInputView[](51);

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(InvalidWithdrawalBatchSize.selector, uint256(51)));
        core.requestWithdrawal(withdrawals);
    }

    function test_requestWithdrawalLocksSharesAndFreezesLotIndex() public {
        vm.prank(admin);
        core.setApr(APR_20_PERCENT_BPS);

        skip(24 hours);

        vm.prank(alice);
        uint256 lotId = core.deposit(1_000e6, alice);

        uint256 shares = shareToken.balanceOf(alice);

        skip(180 days);
        uint256 frozenIndex = core.currentIndex();
        uint256 expectedSnapshot = _expectedAssetsForShares(shares, frozenIndex);

        uint256 requestTimestamp = vm.getBlockTimestamp();
        vm.prank(alice);
        core.requestWithdrawal(_singleWithdrawal(lotId, shares));

        assertEq(shareToken.lockedBalanceOf(alice), shares);
        assertEq(core.lot(lotId).frozenIndexRay, frozenIndex);
        assertTrue(core.lot(lotId).isFrozen);
        assertEq(core.withdrawalRequest(alice).owner, alice);
        assertEq(core.withdrawalRequest(alice).lotIds[0], lotId);
        assertEq(core.withdrawalRequest(alice).shareAmounts[0], shares);
        assertEq(core.withdrawalRequest(alice).assetAmountSnapshot, expectedSnapshot);
        assertEq(core.withdrawalRequest(alice).requestedAt, requestTimestamp);
        assertEq(core.withdrawalRequest(alice).executableAt, requestTimestamp + 24 hours);
    }

    function test_executeWithdrawalOnlyWorksAfter24Hours() public {
        vm.prank(alice);
        uint256 lotId = core.deposit(1_000e6, alice);
        uint256 shares = shareToken.balanceOf(alice);

        vm.prank(alice);
        core.requestWithdrawal(_singleWithdrawal(lotId, shares));

        uint256 currentTimestamp = vm.getBlockTimestamp();
        vm.prank(alice);
        vm.expectRevert(
            abi.encodeWithSelector(WithdrawalLockNotElapsed.selector, currentTimestamp + 24 hours, currentTimestamp)
        );
        core.executeWithdrawal();
    }

    function test_executeWithdrawalRevertsWhenLiquidityIsInsufficient() public {
        vm.prank(admin);
        core.setTreasuryRatio(7_000);

        vm.prank(alice);
        uint256 lotId = core.deposit(1_000e6, alice);
        uint256 shares = shareToken.balanceOf(alice);

        vm.prank(alice);
        core.requestWithdrawal(_singleWithdrawal(lotId, shares));

        skip(24 hours);

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(InsufficientLiquidity.selector, 1_000e6, 300e6));
        core.executeWithdrawal();
    }

    function test_partialWithdrawalDoesNotCreateAdditionalLotIds() public {
        vm.prank(alice);
        uint256 lotId = core.deposit(1_000e6, alice);

        vm.prank(alice);
        core.requestWithdrawal(_singleWithdrawal(lotId, 2_500e6));

        assertEq(core.lot(lotId).shareAmount, 7_500e6);
        assertFalse(core.lot(lotId).isClosed);
        assertEq(core.withdrawalRequest(alice).lotIds[0], lotId);
        assertEq(core.lot(2).owner, address(0));
    }

    function test_requestWithdrawalRespectsDedicatedPauseSwitch() public {
        vm.prank(alice);
        uint256 lotId = core.deposit(1_000e6, alice);

        vm.prank(admin);
        core.setWithdrawalPause(true, false);

        vm.prank(alice);
        vm.expectRevert(RequestWithdrawalPaused.selector);
        core.requestWithdrawal(_singleWithdrawal(lotId, 1_000e6));
    }

    function test_ownerCannotCreateSecondActiveWithdrawalRequest() public {
        uint256 firstLotId = _deposit(alice, 1_000e6, alice);

        vm.prank(alice);
        core.requestWithdrawal(_singleWithdrawal(firstLotId, 5_000e6));

        uint256 secondLotId = _deposit(alice, 1_000e6, alice);

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(ActiveWithdrawalRequest.selector, alice));
        core.requestWithdrawal(_singleWithdrawal(secondLotId, 1_000e6));
    }

    function test_ownerCanCreateNewWithdrawalRequestAfterPreviousExecution() public {
        vm.prank(admin);
        core.setTreasuryRatio(0);

        uint256 firstLotId = _deposit(alice, 1_000e6, alice);

        vm.prank(alice);
        core.requestWithdrawal(_singleWithdrawal(firstLotId, 5_000e6));

        skip(24 hours);

        vm.prank(alice);
        core.executeWithdrawal();

        uint256 secondLotId = _deposit(alice, 1_000e6, alice);

        vm.prank(alice);
        core.requestWithdrawal(_singleWithdrawal(secondLotId, 1_000e6));
        assertEq(core.withdrawalRequest(alice).owner, alice);
        assertEq(core.withdrawalRequest(alice).shareAmounts[0], 1_000e6);
    }

    function test_cancelWithdrawalUnlocksSharesAndAllowsNewRequest() public {
        vm.prank(alice);
        uint256 lotId = core.deposit(1_000e6, alice);
        uint256 shares = shareToken.balanceOf(alice);

        vm.prank(alice);
        core.requestWithdrawal(_singleWithdrawal(lotId, shares));

        vm.prank(alice);
        core.cancelWithdrawal();

        assertTrue(core.withdrawalRequest(alice).cancelled);
        assertEq(shareToken.lockedBalanceOf(alice), 0);
        assertFalse(core.lot(lotId).isFrozen);
        assertEq(core.lot(lotId).frozenAt, 0);
        assertEq(core.lot(lotId).frozenIndexRay, 0);
        assertEq(core.totals().frozenWithdrawalLiability, 0);
        assertEq(core.totals().userPrincipalLiability, 1_000e6);

        vm.prank(alice);
        core.requestWithdrawal(_singleWithdrawal(lotId, 1_000e6));
        assertEq(core.withdrawalRequest(alice).owner, alice);
        assertEq(core.withdrawalRequest(alice).shareAmounts[0], 1_000e6);
    }

    function test_blacklistedUserCannotCancelWithdrawal() public {
        vm.prank(alice);
        uint256 lotId = core.deposit(1_000e6, alice);

        vm.prank(alice);
        core.requestWithdrawal(_singleWithdrawal(lotId, 500e6));

        vm.prank(admin);
        core.setBlacklist(alice, true);

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(Blacklisted.selector, alice));
        core.cancelWithdrawal();
    }

    function test_cancelPartialWithdrawalRestoresOriginalLotWithoutFragmentation() public {
        vm.prank(alice);
        uint256 lotId = core.deposit(1_000e6, alice);
        uint256 shares = shareToken.balanceOf(alice);

        vm.prank(alice);
        core.requestWithdrawal(_singleWithdrawal(lotId, 2_500e6));

        vm.prank(alice);
        core.cancelWithdrawal();

        assertTrue(core.withdrawalRequest(alice).cancelled);
        assertEq(shareToken.lockedBalanceOf(alice), 0);
        assertFalse(core.lot(lotId).isFrozen);
        assertEq(core.lot(lotId).frozenAt, 0);
        assertEq(core.lot(lotId).frozenIndexRay, 0);
        assertEq(core.totals().frozenWithdrawalLiability, 0);
        assertEq(core.totals().userPrincipalLiability, 1_000e6);
        assertEq(core.lot(lotId).shareAmount, shares);
        assertEq(core.lot(lotId).principalAssets, 1_000e6);
        assertEq(core.lot(2).owner, address(0));
    }

    function test_executeWithdrawalRespectsDedicatedPauseSwitch() public {
        vm.prank(alice);
        uint256 lotId = core.deposit(1_000e6, alice);

        vm.prank(alice);
        core.requestWithdrawal(_singleWithdrawal(lotId, 1_000e6));

        skip(24 hours);

        vm.prank(admin);
        core.setWithdrawalPause(false, true);

        vm.prank(alice);
        vm.expectRevert(ExecuteWithdrawalPaused.selector);
        core.executeWithdrawal();
    }

    function test_executeWithdrawalTransfersAssetsAndBurnsLockedSharesOnSuccess() public {
        vm.prank(admin);
        core.setTreasuryRatio(0);

        vm.prank(alice);
        uint256 lotId = core.deposit(1_000e6, alice);
        uint256 shares = shareToken.balanceOf(alice);

        vm.prank(alice);
        core.requestWithdrawal(_singleWithdrawal(lotId, shares));

        uint256 aliceAssetsBefore = assetToken.balanceOf(alice);

        skip(24 hours);

        vm.prank(alice);
        uint256 assetsPaid = core.executeWithdrawal();

        assertEq(assetsPaid, core.withdrawalRequest(alice).assetAmountSnapshot);
        assertEq(assetToken.balanceOf(alice), aliceAssetsBefore + assetsPaid);
        assertEq(shareToken.lockedBalanceOf(alice), 0);
        assertEq(shareToken.balanceOf(alice), 0);
        assertTrue(core.withdrawalRequest(alice).executed);
        assertEq(core.totals().frozenWithdrawalLiability, 0);
        assertEq(core.totals().userPrincipalLiability, 0);
    }
}
