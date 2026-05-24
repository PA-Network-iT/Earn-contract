// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {SubscriptionTestBase} from "test/shared/subscription/SubscriptionTestBase.sol";
import {SubscriptionManager, InvalidTreasuryWallet} from "src/subscription/SubscriptionManager.sol";

/// @notice Verifies the v2 treasury migration on an already-initialized proxy.
contract SubscriptionManagerTreasuryUpgradeTest is SubscriptionTestBase {
    event TreasuryWalletUpdated(address indexed newTreasuryWallet);

    function test_upgradeCanRebindTreasuryWallet() public {
        address newTreasury = makeAddr("newTreasury");
        SubscriptionManager newImpl = new SubscriptionManager();

        vm.expectEmit(true, false, false, true, address(manager));
        emit TreasuryWalletUpdated(newTreasury);

        vm.prank(admin);
        manager.upgradeToAndCall(
            address(newImpl), abi.encodeCall(SubscriptionManager.initializeTreasuryWallet, (newTreasury))
        );

        assertEq(manager.treasuryWallet(), newTreasury);

        // Admin has only a genesis sub (no pass) -> seats == 0 -> null sponsor fallback
        // routes revenue to treasury, exercising the rebound treasury wallet.
        _grantGenesisSubscription(admin);
        uint256 treasuryBefore = usdc.balanceOf(newTreasury);
        vm.prank(alice);
        manager.buySubscription(admin);
        assertEq(usdc.balanceOf(newTreasury) - treasuryBefore, SUBSCRIPTION_PRICE);
    }

    function test_initializeTreasuryWalletRejectsZero() public {
        SubscriptionManager newImpl = new SubscriptionManager();

        vm.prank(admin);
        manager.upgradeToAndCall(address(newImpl), "");

        vm.expectRevert(abi.encodeWithSelector(InvalidTreasuryWallet.selector, address(0)));
        vm.prank(admin);
        manager.initializeTreasuryWallet(address(0));
    }
}
