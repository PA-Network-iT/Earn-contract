// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {EarnTestBase} from "test/shared/EarnTestBase.sol";
import {InsufficientLiquidity} from "test/shared/interfaces/EarnSpecInterfaces.sol";

/// @notice Unit tests for treasury transfers, buffer replenishment, and withdrawal liquidity constraints.
contract LiquidityPolicyTest is EarnTestBase {
    function test_depositSendsTreasuryShareDirectlyToWallet() public {
        vm.prank(admin);
        core.setTreasuryRatio(7_000);

        uint256 treasuryBalBefore = assetToken.balanceOf(treasury);

        vm.prank(alice);
        core.deposit(1_000e6, alice);

        assertEq(core.availableLiquidity(), 300e6);
        assertEq(assetToken.balanceOf(treasury), treasuryBalBefore + 700e6);
        assertEq(core.totals().treasuryReportedAssets, 0);
    }

    function test_replenishBufferInjectsLiquidityIntoContract() public {
        vm.prank(admin);
        core.setTreasuryRatio(7_000);

        vm.prank(alice);
        core.deposit(1_000e6, alice);

        assertEq(core.availableLiquidity(), 300e6);

        vm.prank(admin);
        core.replenishBuffer(700e6);

        assertEq(core.availableLiquidity(), 1_000e6);
    }

    function test_replenishBufferEnablesPreviouslyUnderliquidWithdrawalExecution() public {
        vm.prank(admin);
        core.setTreasuryRatio(7_000);

        vm.prank(alice);
        uint256 lotId = core.deposit(1_000e6, alice);
        uint256 shares = shareToken.balanceOf(alice);

        vm.prank(alice);
        core.requestWithdrawal(lotId, shares);

        skip(24 hours);

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(InsufficientLiquidity.selector, 1_000e6, 300e6));
        core.executeWithdrawal();

        vm.prank(admin);
        core.replenishBuffer(700e6);

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
        uint256 shares = shareToken.balanceOf(alice);

        skip(180 days);

        vm.prank(alice);
        core.requestWithdrawal(lotId, shares);

        uint256 requiredTopUp = core.withdrawalRequest(alice).assetAmountSnapshot - core.availableLiquidity();

        vm.prank(admin);
        core.replenishBuffer(requiredTopUp);

        skip(24 hours);

        vm.prank(alice);
        uint256 paid = core.executeWithdrawal();

        assertEq(paid, core.withdrawalRequest(alice).assetAmountSnapshot);
        assertEq(core.availableLiquidity(), 0);
    }

    function test_executeWithdrawalUsesAvailableBufferLiquidity() public {
        vm.prank(admin);
        core.setTreasuryRatio(7_000);

        vm.prank(alice);
        uint256 lotId = core.deposit(1_000e6, alice);
        uint256 shares = shareToken.balanceOf(alice);

        vm.prank(alice);
        core.requestWithdrawal(lotId, shares);

        skip(24 hours);

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(InsufficientLiquidity.selector, 1_000e6, 300e6));
        core.executeWithdrawal();
    }

    function test_reportTreasuryAssetsIsExternalAccounting() public {
        vm.prank(admin);
        core.reportTreasuryAssets(5_000e6);

        assertEq(core.totals().treasuryReportedAssets, 5_000e6);
        assertEq(core.availableLiquidity(), 0);
    }
}
