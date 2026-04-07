// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {EarnTestBase} from "test/shared/EarnTestBase.sol";
import {
    WithdrawalLockNotElapsed,
    InsufficientLiquidity,
    RequestWithdrawalPaused,
    ExecuteWithdrawalPaused,
    ActiveWithdrawalRequest,
    Blacklisted
} from "test/shared/interfaces/EarnSpecInterfaces.sol";

contract WithdrawalFlowTest is EarnTestBase {
    function test_requestWithdrawalLocksSharesAndFreezesLotIndex() public {
        vm.prank(admin);
        core.setApr(APR_20_PERCENT_BPS);

        skip(24 hours);

        vm.prank(alice);
        uint256 lotId = core.deposit(1_000e6, alice);

        skip(180 days);
        uint256 frozenIndex = core.currentIndex();
        uint256 expectedSnapshot = _expectedAssetsForShares(1_000e6, frozenIndex);

        uint256 requestTimestamp = vm.getBlockTimestamp();
        vm.prank(alice);
        core.requestWithdrawal(lotId, 1_000e6);

        assertEq(shareToken.lockedBalanceOf(alice), 1_000e6);
        assertEq(core.lot(lotId).frozenIndexRay, frozenIndex);
        assertTrue(core.lot(lotId).isFrozen);
        assertEq(core.withdrawalRequest(alice).owner, alice);
        assertEq(core.withdrawalRequest(alice).lotId, lotId);
        assertEq(core.withdrawalRequest(alice).shareAmount, 1_000e6);
        assertEq(core.withdrawalRequest(alice).assetAmountSnapshot, expectedSnapshot);
        assertEq(core.withdrawalRequest(alice).requestedAt, requestTimestamp);
        assertEq(core.withdrawalRequest(alice).executableAt, requestTimestamp + 24 hours);
    }

    function test_executeWithdrawalOnlyWorksAfter24Hours() public {
        vm.prank(alice);
        uint256 lotId = core.deposit(1_000e6, alice);

        vm.prank(alice);
        core.requestWithdrawal(lotId, 1_000e6);

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

        vm.prank(alice);
        core.requestWithdrawal(lotId, 1_000e6);

        skip(24 hours);

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(InsufficientLiquidity.selector, 1_000e6, 300e6));
        core.executeWithdrawal();
    }

    function test_partialWithdrawalDoesNotCreateAdditionalLotIds() public {
        vm.prank(alice);
        uint256 lotId = core.deposit(1_000e6, alice);

        vm.prank(alice);
        core.requestWithdrawal(lotId, 250e6);

        assertEq(core.lot(lotId).shareAmount, 750e6);
        assertFalse(core.lot(lotId).isClosed);
        assertEq(core.withdrawalRequest(alice).lotId, lotId);
        assertEq(core.lot(2).owner, address(0));
    }

    function test_requestWithdrawalRespectsDedicatedPauseSwitch() public {
        vm.prank(alice);
        uint256 lotId = core.deposit(1_000e6, alice);

        vm.prank(admin);
        core.setWithdrawalPause(true, false);

        vm.prank(alice);
        vm.expectRevert(RequestWithdrawalPaused.selector);
        core.requestWithdrawal(lotId, 100e6);
    }

    function test_ownerCannotCreateSecondActiveWithdrawalRequest() public {
        vm.prank(alice);
        uint256 firstLotId = core.deposit(1_000e6, alice);

        vm.prank(alice);
        core.requestWithdrawal(firstLotId, 500e6);

        vm.prank(alice);
        uint256 secondLotId = core.deposit(1_000e6, alice);

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(ActiveWithdrawalRequest.selector, alice));
        core.requestWithdrawal(secondLotId, 100e6);
    }

    function test_ownerCanCreateNewWithdrawalRequestAfterPreviousExecution() public {
        vm.prank(admin);
        core.setTreasuryRatio(0);

        vm.prank(alice);
        uint256 firstLotId = core.deposit(1_000e6, alice);

        vm.prank(alice);
        core.requestWithdrawal(firstLotId, 500e6);

        skip(24 hours);

        vm.prank(alice);
        core.executeWithdrawal();

        vm.prank(alice);
        uint256 secondLotId = core.deposit(1_000e6, alice);

        vm.prank(alice);
        core.requestWithdrawal(secondLotId, 100e6);
        assertEq(core.withdrawalRequest(alice).owner, alice);
        assertEq(core.withdrawalRequest(alice).shareAmount, 100e6);
    }

    function test_cancelWithdrawalUnlocksSharesAndAllowsNewRequest() public {
        vm.prank(alice);
        uint256 lotId = core.deposit(1_000e6, alice);

        vm.prank(alice);
        core.requestWithdrawal(lotId, 1_000e6);

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
        core.requestWithdrawal(lotId, 100e6);
        assertEq(core.withdrawalRequest(alice).owner, alice);
        assertEq(core.withdrawalRequest(alice).shareAmount, 100e6);
    }

    function test_blacklistedUserCannotCancelWithdrawal() public {
        vm.prank(alice);
        uint256 lotId = core.deposit(1_000e6, alice);

        vm.prank(alice);
        core.requestWithdrawal(lotId, 500e6);

        vm.prank(admin);
        core.setBlacklist(alice, true);

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(Blacklisted.selector, alice));
        core.cancelWithdrawal();
    }

    function test_cancelPartialWithdrawalRestoresOriginalLotWithoutFragmentation() public {
        vm.prank(alice);
        uint256 lotId = core.deposit(1_000e6, alice);

        vm.prank(alice);
        core.requestWithdrawal(lotId, 250e6);

        vm.prank(alice);
        core.cancelWithdrawal();

        assertTrue(core.withdrawalRequest(alice).cancelled);
        assertEq(shareToken.lockedBalanceOf(alice), 0);
        assertFalse(core.lot(lotId).isFrozen);
        assertEq(core.lot(lotId).frozenAt, 0);
        assertEq(core.lot(lotId).frozenIndexRay, 0);
        assertEq(core.totals().frozenWithdrawalLiability, 0);
        assertEq(core.totals().userPrincipalLiability, 1_000e6);
        assertEq(core.lot(lotId).shareAmount, 1_000e6);
        assertEq(core.lot(lotId).principalAssets, 1_000e6);
        assertEq(core.lot(2).owner, address(0));
    }

    function test_executeWithdrawalRespectsDedicatedPauseSwitch() public {
        vm.prank(alice);
        uint256 lotId = core.deposit(1_000e6, alice);

        vm.prank(alice);
        core.requestWithdrawal(lotId, 100e6);

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

        vm.prank(alice);
        core.requestWithdrawal(lotId, 1_000e6);

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
