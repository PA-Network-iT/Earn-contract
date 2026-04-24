// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {EarnTestBase} from "test/shared/EarnTestBase.sol";

/// @notice Integration tests covering a representative deposit, APR update, withdrawal request, and execution flow.
contract EarnLifecycleTest is EarnTestBase {
    function test_fullLifecycleDepositAprChangeRequestAndExecuteWithdrawal() public {
        vm.startPrank(admin);
        core.setApr(APR_20_PERCENT_BPS);
        core.setTreasuryRatio(0);
        vm.stopPrank();

        skip(24 hours);

        vm.prank(alice);
        uint256 lotId = core.deposit(1_000e6, alice);

        skip(90 days);

        vm.prank(admin);
        core.setApr(APR_10_PERCENT_BPS);

        uint256 halfShares = shareToken.balanceOf(alice) / 2;
        vm.prank(alice);
        core.requestWithdrawal(lotId, halfShares);

        skip(24 hours);

        vm.prank(alice);
        uint256 assetsPaid = core.executeWithdrawal();

        assertGt(assetsPaid, 500e6);
        assertTrue(core.withdrawalRequest(alice).executed);
        assertEq(shareToken.lockedBalanceOf(alice), 0);
        assertEq(core.totals().userPrincipalLiability, 500e6);
    }
}
