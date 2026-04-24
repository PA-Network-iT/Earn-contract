// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {EarnTestBase} from "test/shared/EarnTestBase.sol";
import {
    TransfersDisabled,
    InvalidTreasuryRatio,
    ZeroSharesMinted,
    DepositBelowMinimum,
    InvalidReceiver,
    InvalidMinimumDeposit,
    LotView
} from "test/shared/interfaces/EarnSpecInterfaces.sol";

/// @notice Unit tests for deposit validation, lot creation, share minting, and pagination.
contract DepositFlowTest is EarnTestBase {
    function test_minDepositStartsAtDefaultValue() public view {
        assertEq(core.minDeposit(), 1_000_000);
    }

    function test_parameterManagerCanUpdateMinimumDeposit() public {
        vm.prank(admin);
        core.setMinDeposit(100_000);

        assertEq(core.minDeposit(), 100_000);
    }

    function test_setMinimumDepositRevertsWhenZero() public {
        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(InvalidMinimumDeposit.selector, 0));
        core.setMinDeposit(0);
    }

    function test_depositMintsSharesAgainstCurrentIndexAndCreatesNewLot() public {
        vm.prank(alice);
        uint256 lotId = core.deposit(1_000e6, alice);

        assertEq(lotId, 1);
        _assertPopulatedLot(core.lot(lotId), lotId, alice, 1_000e6);
        assertEq(shareToken.balanceOf(alice), 10_000e6);
        assertEq(core.lot(lotId).entryIndexRay, core.currentIndex());
        assertEq(core.lot(lotId).lastIndexRay, core.currentIndex());
    }

    function test_shareTokenIsNonTransferable() public {
        vm.prank(alice);
        core.deposit(1_000e6, alice);

        vm.prank(alice);
        vm.expectRevert(TransfersDisabled.selector);
        shareToken.transfer(bob, 100e6);
    }

    function test_depositAllocatesAssetsBetweenBufferAndTreasuryByRatio() public {
        vm.prank(admin);
        core.setTreasuryRatio(7_000);

        vm.prank(alice);
        core.deposit(1_000e6, alice);

        assertEq(core.availableLiquidity(), 300e6);
        assertEq(assetToken.balanceOf(treasury), 700e6);
    }

    function test_depositAfterIndexGrowthMintsFewerSharesThanAssets() public {
        vm.prank(admin);
        core.setApr(APR_20_PERCENT_BPS);

        skip(24 hours + 180 days);

        uint256 expectedIndex = _expectedLinearIndex(APR_20_PERCENT_BPS, 180 days);
        uint256 expectedShares = _expectedSharesForDeposit(1_000e6, expectedIndex);

        vm.prank(alice);
        uint256 lotId = core.deposit(1_000e6, alice);

        assertEq(core.currentIndex(), expectedIndex);
        assertEq(core.lot(lotId).entryIndexRay, expectedIndex);
        assertEq(core.lot(lotId).shareAmount, expectedShares);
        assertEq(shareToken.balanceOf(alice), expectedShares);
        assertLt(expectedShares, 10_000e6);
    }

    function test_setTreasuryRatioRevertsWhenAboveBpsDenominator() public {
        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(InvalidTreasuryRatio.selector, 10_001));
        core.setTreasuryRatio(10_001);
    }

    function test_depositRevertsWithoutFundingOrApproval() public {
        address charlie = makeAddr("charlie");

        vm.prank(charlie);
        vm.expectRevert();
        core.deposit(1_000e6, charlie);
    }

    function test_depositRevertsWhenBelowMinimumDepositAmount() public {
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(DepositBelowMinimum.selector, 999_999, 1_000_000));
        core.deposit(999_999, alice);
    }

    function test_depositUsesUpdatedMinimumDepositAmount() public {
        vm.prank(admin);
        core.setMinDeposit(100_000);

        vm.prank(alice);
        core.deposit(100_000, alice);

        assertEq(shareToken.balanceOf(alice), 1_000_000);
    }

    function test_lotsByOwnerReturnsOwnedLotsInInsertionOrder() public {
        vm.prank(alice);
        uint256 firstLotId = core.deposit(1_000e6, alice);

        vm.prank(alice);
        uint256 secondLotId = core.deposit(2_000e6, alice);

        LotView[] memory lots = core.lotsByOwner(alice, 0, 10);

        assertEq(core.ownerLotCount(alice), 2);
        assertEq(lots.length, 2);
        assertEq(lots[0].id, firstLotId);
        assertEq(lots[0].owner, alice);
        assertEq(lots[1].id, secondLotId);
        assertEq(lots[1].principalAssets, 2_000e6);
    }

    function test_lotsByOwnerSupportsPagination() public {
        vm.prank(alice);
        core.deposit(1_000e6, alice);

        vm.prank(alice);
        uint256 secondLotId = core.deposit(2_000e6, alice);

        vm.prank(alice);
        uint256 thirdLotId = core.deposit(3_000e6, alice);

        LotView[] memory lots = core.lotsByOwner(alice, 1, 5);

        assertEq(lots.length, 2);
        assertEq(lots[0].id, secondLotId);
        assertEq(lots[1].id, thirdLotId);
    }

    function test_lotsByOwnerClampsWhenLimitExceedsRemainingRange() public {
        vm.prank(alice);
        core.deposit(1_000e6, alice);

        vm.prank(alice);
        uint256 secondLotId = core.deposit(2_000e6, alice);

        vm.prank(alice);
        uint256 thirdLotId = core.deposit(3_000e6, alice);

        LotView[] memory lots = core.lotsByOwner(alice, 1, type(uint256).max);

        assertEq(lots.length, 2);
        assertEq(lots[0].id, secondLotId);
        assertEq(lots[1].id, thirdLotId);
    }

    function test_depositRevertsWhenReceiverIsZeroAddress() public {
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(InvalidReceiver.selector, address(0)));
        core.deposit(1_000e6, address(0));
    }

    function test_depositRevertsWhenIndexMakesMintedSharesZero() public {
        vm.prank(admin);
        core.setApr(10_000);

        skip(24 hours + (YEAR_IN_SECONDS * 10_000_001));

        uint256 currentIndexRay = core.currentIndex();

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(ZeroSharesMinted.selector, 1_000_000, currentIndexRay));
        core.deposit(1_000_000, alice);
    }
}
