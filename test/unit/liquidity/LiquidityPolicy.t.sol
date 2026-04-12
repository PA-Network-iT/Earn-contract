// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {EarnTestBase} from "test/shared/EarnTestBase.sol";
import {InsufficientLiquidity} from "test/shared/interfaces/EarnSpecInterfaces.sol";

/// @notice Unit tests for treasury transfers, buffer replenishment, and withdrawal liquidity constraints.
contract LiquidityPolicyTest is EarnTestBase {
    function test_transferToTreasuryDecrementsTreasuryReportedAssetsAfterTransfer() public {
        vm.prank(admin);
        core.setTreasuryRatio(7_000);

        vm.prank(alice);
        core.deposit(1_000e6, alice);

        uint256 contractBalanceBefore = assetToken.balanceOf(address(core));
        uint256 adminBalanceBefore = assetToken.balanceOf(admin);

        vm.prank(admin);
        core.transferToTreasury(admin, 700e6);

        assertEq(assetToken.balanceOf(address(core)), contractBalanceBefore - 700e6);
        assertEq(assetToken.balanceOf(admin), adminBalanceBefore + 700e6);
        assertEq(core.totals().bufferAssets, 300e6);
        assertEq(core.totals().treasuryReportedAssets, 0);
    }

    function test_replenishBufferTransfersTreasuryAssetsBackIntoImmediateLiquidity() public {
        vm.prank(admin);
        core.setTreasuryRatio(7_000);

        vm.prank(alice);
        core.deposit(1_000e6, alice);

        vm.prank(admin);
        core.transferToTreasury(admin, 700e6);

        vm.prank(admin);
        core.replenishBuffer(700e6);

        assertEq(core.totals().bufferAssets, 1_000e6);
        assertEq(core.totals().treasuryReportedAssets, 0);
    }

    function test_replenishBufferEnablesPreviouslyUnderliquidWithdrawalExecution() public {
        vm.prank(admin);
        core.setTreasuryRatio(7_000);

        vm.prank(alice);
        uint256 lotId = core.deposit(1_000e6, alice);

        vm.prank(alice);
        core.requestWithdrawal(lotId, 1_000e6);

        vm.prank(admin);
        core.transferToTreasury(admin, 700e6);

        vm.prank(admin);
        core.replenishBuffer(700e6);

        skip(24 hours);

        vm.prank(alice);
        uint256 paid = core.executeWithdrawal();

        assertEq(paid, 1_000e6);
    }

    function test_replenishBufferCanInjectFreshLiquidityForAccruedYield() public {
        vm.prank(admin);
        core.setApr(APR_20_PERCENT_BPS);

        skip(24 hours);

        vm.prank(alice);
        uint256 lotId = core.deposit(1_000e6, alice);

        skip(180 days);

        vm.prank(alice);
        core.requestWithdrawal(lotId, 1_000e6);

        uint256 requiredTopUp = core.withdrawalRequest(alice).assetAmountSnapshot - core.totals().bufferAssets;

        vm.prank(admin);
        core.replenishBuffer(requiredTopUp);

        skip(24 hours);

        vm.prank(alice);
        uint256 paid = core.executeWithdrawal();

        assertEq(paid, core.withdrawalRequest(alice).assetAmountSnapshot);
        assertEq(core.totals().bufferAssets, 0);
    }

    function test_executeWithdrawalUsesAvailableBufferLiquidity() public {
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

    function test_treasuryReportedAssetsCountTowardSolvencyNotImmediateBuffer() public {
        vm.prank(admin);
        core.reportTreasuryAssets(5_000e6);

        assertEq(core.totals().treasuryReportedAssets, 5_000e6);
        assertEq(core.totals().bufferAssets, 0);
    }
}
