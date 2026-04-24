// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";

import {SubscriptionTestBase} from "test/shared/subscription/SubscriptionTestBase.sol";
import {SubscriptionManager} from "src/subscription/SubscriptionManager.sol";
import {MockUSDC} from "test/shared/mocks/MockUSDC.sol";
import {ZeroAddress, InvalidAmount} from "test/shared/subscription/SubscriptionErrors.sol";

/// @notice Unit tests for `SubscriptionManager.sweep`.
/// @dev Sweep is the ops off-ramp for revenue accrued on the contract from
///      `renewSubscription`, `buyPackagePass`, `upgradePackagePass`, and null-fallback
///      `buySubscription` flows. It also doubles as a rescue for accidentally transferred ERC-20s.
contract SweepTest is SubscriptionTestBase {
    event RevenueSwept(address indexed caller, address indexed token, address indexed to, uint256 amount);

    function setUp() public override {
        super.setUp();
        _grantGenesisSubscription(admin);
        // alice has no pass -> null fallback; 100e6 USDC lands on the manager as collected revenue.
        vm.prank(alice);
        manager.buySubscription(admin);
    }

    function test_sweepPaymentTokenTransfersAndBumpsCounter() public {
        assertEq(usdc.balanceOf(address(manager)), 100e6);
        assertEq(manager.totalRevenueSwept(), 0);

        uint256 treasuryBefore = usdc.balanceOf(treasury);

        vm.expectEmit(true, true, true, true, address(manager));
        emit RevenueSwept(admin, address(usdc), treasury, 60e6);

        vm.prank(admin);
        manager.sweep(address(usdc), treasury, 60e6);

        assertEq(usdc.balanceOf(address(manager)), 40e6);
        assertEq(usdc.balanceOf(treasury) - treasuryBefore, 60e6);
        assertEq(manager.totalRevenueSwept(), 60e6);
        assertEq(manager.pendingRevenue(), 40e6);
    }

    function test_sweepCanSplitAcrossMultipleCalls() public {
        uint256 treasuryBefore = usdc.balanceOf(treasury);
        uint256 bobBefore = usdc.balanceOf(bob);

        vm.startPrank(admin);
        manager.sweep(address(usdc), treasury, 30e6);
        manager.sweep(address(usdc), treasury, 20e6);
        manager.sweep(address(usdc), bob, 50e6);
        vm.stopPrank();

        assertEq(manager.totalRevenueSwept(), 100e6);
        assertEq(usdc.balanceOf(address(manager)), 0);
        assertEq(manager.pendingRevenue(), 0);
        assertEq(usdc.balanceOf(treasury) - treasuryBefore, 50e6);
        assertEq(usdc.balanceOf(bob) - bobBefore, 50e6);
    }

    function test_sweepForeignTokenRescuesWithoutBumpingCounter() public {
        MockUSDC stray = new MockUSDC();
        stray.mint(address(manager), 42e6);

        vm.expectEmit(true, true, true, true, address(manager));
        emit RevenueSwept(admin, address(stray), treasury, 42e6);

        vm.prank(admin);
        manager.sweep(address(stray), treasury, 42e6);

        // Foreign tokens are rescued but do NOT bump the protocol-revenue counter.
        assertEq(manager.totalRevenueSwept(), 0);
        assertEq(stray.balanceOf(address(manager)), 0);
        assertEq(stray.balanceOf(treasury), 42e6);
        // Payment-token balance is untouched.
        assertEq(usdc.balanceOf(address(manager)), 100e6);
    }

    function test_sweepRevertsOnZeroToken() public {
        vm.prank(admin);
        vm.expectRevert(ZeroAddress.selector);
        manager.sweep(address(0), treasury, 1);
    }

    function test_sweepRevertsOnZeroRecipient() public {
        vm.prank(admin);
        vm.expectRevert(ZeroAddress.selector);
        manager.sweep(address(usdc), address(0), 1);
    }

    function test_sweepRevertsOnZeroAmount() public {
        vm.prank(admin);
        vm.expectRevert(InvalidAmount.selector);
        manager.sweep(address(usdc), treasury, 0);
    }

    function test_sweepRevertsWithoutTreasuryRole() public {
        // Hoist the role constant out of the prank scope — evaluating it inside `vm.expectRevert`
        // args would consume the prank before `sweep` is called.
        bytes32 role = manager.TREASURY_MANAGER_ROLE();
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, alice, role)
        );
        vm.prank(alice);
        manager.sweep(address(usdc), treasury, 1);
    }

    function test_sweepWorksWhilePaused() public {
        vm.prank(admin);
        manager.pause();

        // Sweep is intentionally not gated by `whenNotPaused` so that ops can always retrieve funds.
        vm.prank(admin);
        manager.sweep(address(usdc), treasury, 100e6);

        assertEq(usdc.balanceOf(treasury), 100e6);
        assertEq(manager.totalRevenueSwept(), 100e6);
    }

    function test_sweepRevertsIfContractBalanceIsInsufficient() public {
        vm.prank(admin);
        vm.expectRevert(); // ERC20 transfer failure from insufficient balance surfaces as a revert.
        manager.sweep(address(usdc), treasury, 200e6);
    }
}
