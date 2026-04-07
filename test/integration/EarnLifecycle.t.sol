// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {EarnTestBase} from "test/shared/EarnTestBase.sol";

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

        vm.prank(alice);
        core.requestWithdrawal(lotId, 500e6);

        skip(24 hours);

        vm.prank(alice);
        uint256 assetsPaid = core.executeWithdrawal();

        assertGt(assetsPaid, 500e6);
        assertTrue(core.withdrawalRequest(alice).executed);
        assertEq(shareToken.lockedBalanceOf(alice), 0);
        assertEq(core.totals().userPrincipalLiability, 500e6);
    }
}
