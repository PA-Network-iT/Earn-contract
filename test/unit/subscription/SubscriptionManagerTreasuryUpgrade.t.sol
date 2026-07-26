// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {SubscriptionTestBase} from "test/shared/subscription/SubscriptionTestBase.sol";
import {SubscriptionManager, UnauthorizedUpgrade} from "src/subscription/SubscriptionManager.sol";
import {
    InvalidTreasuryWallet,
    NoPendingTreasuryWallet,
    TreasuryWalletChangeIsTwoStep,
    TreasuryWalletDelayNotElapsed,
    UnexpectedTreasuryWallet
} from "src/treasury/TreasuryWalletTimelock.sol";
import {UpgradeDelayNotElapsed, UpgradeNotScheduled} from "src/upgrade/DelayedUUPSUpgradeable.sol";

/// @notice Verifies that the two security timelocks on SubscriptionManager hold: the treasury
///         wallet can only rotate through propose + accept, and implementations can only change
///         through schedule + wait + execute.
contract SubscriptionManagerTreasuryUpgradeTest is SubscriptionTestBase {
    event TreasuryWalletProposed(address indexed newTreasuryWallet, uint256 proposedAt, uint256 executableAt);
    event TreasuryWalletProposalCancelled(address indexed cancelledTreasuryWallet);
    event TreasuryWalletUpdated(address indexed newTreasuryWallet);

    address internal newTreasury = makeAddr("newTreasury");

    // ===== Treasury wallet rotation =====

    function test_proposeDoesNotChangeActiveTreasuryWallet() public {
        uint64 expectedExecutableAt = uint64(block.timestamp + manager.TREASURY_WALLET_CHANGE_DELAY());

        vm.expectEmit(true, false, false, true, address(manager));
        emit TreasuryWalletProposed(newTreasury, block.timestamp, expectedExecutableAt);

        vm.prank(admin);
        manager.proposeTreasuryWallet(newTreasury);

        assertEq(manager.treasuryWallet(), treasury);

        (address pending, uint64 proposedAt, uint64 executableAt) = manager.pendingTreasuryWallet();
        assertEq(pending, newTreasury);
        assertEq(proposedAt, uint64(block.timestamp));
        assertEq(executableAt, expectedExecutableAt);
    }

    function test_acceptRevertsBeforeDelayElapsed() public {
        vm.prank(admin);
        manager.proposeTreasuryWallet(newTreasury);

        (,, uint64 executableAt) = manager.pendingTreasuryWallet();
        vm.warp(executableAt - 1);

        vm.prank(admin);
        vm.expectRevert(
            abi.encodeWithSelector(TreasuryWalletDelayNotElapsed.selector, executableAt, block.timestamp)
        );
        manager.acceptTreasuryWallet(newTreasury);
    }

    function test_acceptRevertsOnUnexpectedPendingWallet() public {
        address decoy = makeAddr("decoy");

        vm.prank(admin);
        manager.proposeTreasuryWallet(newTreasury);

        (,, uint64 executableAt) = manager.pendingTreasuryWallet();
        vm.warp(executableAt);

        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(UnexpectedTreasuryWallet.selector, decoy, newTreasury));
        manager.acceptTreasuryWallet(decoy);
    }

    function test_acceptRevertsWithoutProposal() public {
        vm.prank(admin);
        vm.expectRevert(NoPendingTreasuryWallet.selector);
        manager.acceptTreasuryWallet(newTreasury);
    }

    function test_proposeRejectsZeroWallet() public {
        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(InvalidTreasuryWallet.selector, address(0)));
        manager.proposeTreasuryWallet(address(0));
    }

    function test_cancelDropsProposal() public {
        vm.prank(admin);
        manager.proposeTreasuryWallet(newTreasury);

        vm.expectEmit(true, false, false, false, address(manager));
        emit TreasuryWalletProposalCancelled(newTreasury);

        vm.prank(admin);
        manager.cancelTreasuryWalletProposal();

        (address pending,,) = manager.pendingTreasuryWallet();
        assertEq(pending, address(0));

        vm.warp(block.timestamp + 30 days);
        vm.prank(admin);
        vm.expectRevert(NoPendingTreasuryWallet.selector);
        manager.acceptTreasuryWallet(newTreasury);
    }

    function test_acceptedWalletReceivesRevenue() public {
        vm.prank(admin);
        manager.proposeTreasuryWallet(newTreasury);

        (,, uint64 executableAt) = manager.pendingTreasuryWallet();
        vm.warp(executableAt);

        vm.expectEmit(true, false, false, false, address(manager));
        emit TreasuryWalletUpdated(newTreasury);

        vm.prank(admin);
        manager.acceptTreasuryWallet(newTreasury);
        assertEq(manager.treasuryWallet(), newTreasury);

        // Admin holds only a genesis sub (no pass) -> seats == 0 -> null sponsor fallback routes
        // revenue to the treasury, exercising the rotated wallet.
        _grantGenesisSubscription(admin);
        uint256 treasuryBefore = usdc.balanceOf(newTreasury);
        vm.prank(alice);
        manager.buySubscription(admin);
        assertEq(usdc.balanceOf(newTreasury) - treasuryBefore, SUBSCRIPTION_PRICE);
    }

    function test_deprecatedSetTreasuryWalletAlwaysReverts() public {
        vm.prank(admin);
        vm.expectRevert(TreasuryWalletChangeIsTwoStep.selector);
        manager.setTreasuryWallet(newTreasury);
    }

    // ===== Upgrade timelock =====

    function test_upgradeRequiresScheduleAndDelay() public {
        SubscriptionManager newImpl = new SubscriptionManager();

        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(UpgradeNotScheduled.selector, address(newImpl)));
        manager.upgradeToAndCall(address(newImpl), "");

        vm.prank(admin);
        manager.scheduleUpgrade(address(newImpl));

        (,, uint64 executableAt) = manager.scheduledUpgrade();
        vm.warp(executableAt - 1);

        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(UpgradeDelayNotElapsed.selector, executableAt, block.timestamp));
        manager.upgradeToAndCall(address(newImpl), "");

        vm.warp(executableAt);
        vm.prank(admin);
        manager.upgradeToAndCall(address(newImpl), "");

        // Storage survived the upgrade and the schedule was consumed.
        assertEq(manager.treasuryWallet(), treasury);
        (address scheduled,,) = manager.scheduledUpgrade();
        assertEq(scheduled, address(0));
    }

    function test_onlyUpgraderCanScheduleUpgrade() public {
        SubscriptionManager newImpl = new SubscriptionManager();

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(UnauthorizedUpgrade.selector, alice));
        manager.scheduleUpgrade(address(newImpl));
    }
}
