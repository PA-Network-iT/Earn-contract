// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {PausableUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";

import {SubscriptionTestBase} from "test/shared/subscription/SubscriptionTestBase.sol";
import {SubscriptionManager} from "src/subscription/SubscriptionManager.sol";
import {
    NotSubscribed,
    SubscriptionAlreadyActive,
    SubscriptionPriceNotSet
} from "test/shared/subscription/SubscriptionErrors.sol";

/// @notice Unit tests for `SubscriptionManager.renewSubscription()`.
/// @dev Renewal only bumps `expiresAt`. It must NOT touch `startedAt`, `sponsor`, the soulbound
///      NFT, partner seats, or the EarnCore sponsor mapping. Early renewal is forbidden: callers
///      must wait until their current subscription has fully expired.
contract RenewSubscriptionTest is SubscriptionTestBase {
    event SubscriptionPurchased(
        address indexed user,
        address indexed sponsor,
        uint64 startedAt,
        uint64 expiresAt,
        uint256 pricePaid,
        bool isRenewal
    );

    function test_renewRevertsIfNeverSubscribed() public {
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(NotSubscribed.selector, alice));
        manager.renewSubscription();
    }

    function test_renewRevertsWhileStillActive() public {
        _bootstrapPartnerPass(admin, 10);
        vm.prank(alice);
        manager.buySubscription(admin);

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(SubscriptionAlreadyActive.selector, alice));
        manager.renewSubscription();
    }

    function test_renewAfterExpiryBumpsExpiresOnly() public {
        _bootstrapPartnerPass(admin, 10);

        vm.prank(alice);
        manager.buySubscription(admin);
        SubscriptionManager.Subscription memory before_ = manager.subscriptionOf(alice);

        uint256 setSponsorCallsBefore = earnCoreStub.setSponsorCalls();
        uint32 seatsBefore = passNft.seatsOf(admin);
        uint256 treasuryBefore = usdc.balanceOf(treasury);
        uint256 managerBefore = usdc.balanceOf(address(manager));

        skip(uint256(SUBSCRIPTION_DURATION) + 1);
        assertFalse(manager.hasActiveSubscription(alice));

        vm.expectEmit(true, true, false, true, address(manager));
        emit SubscriptionPurchased(
            alice,
            before_.sponsor,
            before_.startedAt,
            uint64(block.timestamp) + SUBSCRIPTION_DURATION,
            SUBSCRIPTION_PRICE,
            true
        );
        vm.prank(alice);
        manager.renewSubscription();

        assertTrue(manager.hasActiveSubscription(alice));

        SubscriptionManager.Subscription memory after_ = manager.subscriptionOf(alice);
        assertEq(after_.startedAt, before_.startedAt, "startedAt must survive renewals");
        assertEq(after_.sponsor, before_.sponsor, "sponsor must survive renewals");
        assertEq(after_.expiresAt, uint64(block.timestamp) + SUBSCRIPTION_DURATION);

        assertEq(passNft.seatsOf(admin), seatsBefore, "renewal must not consume a partner seat");
        assertEq(earnCoreStub.setSponsorCalls(), setSponsorCallsBefore, "renewal must not re-write EarnCore sponsor");
        // Renewal revenue now accumulates on the contract instead of going straight to treasury.
        assertEq(usdc.balanceOf(treasury) - treasuryBefore, 0, "treasury must not receive renewal revenue synchronously");
        assertEq(usdc.balanceOf(address(manager)) - managerBefore, SUBSCRIPTION_PRICE, "renewal revenue must land on the manager");
        assertEq(manager.totalRevenueSwept(), 0);
        assertEq(manager.pendingRevenue(), usdc.balanceOf(address(manager)));
        assertEq(subNft.balanceOf(alice), 1, "NFT must not be re-minted");
    }

    function test_renewPreservesNullSponsorAndDoesNotCallEarnCore() public {
        // admin has a genesis sub but no Pass → alice resolves to a null sponsor.
        _grantGenesisSubscription(admin);
        vm.prank(alice);
        manager.buySubscription(admin);
        assertEq(manager.subscriptionOf(alice).sponsor, address(0));

        uint256 setSponsorCallsBefore = earnCoreStub.setSponsorCalls();

        skip(uint256(SUBSCRIPTION_DURATION) + 1);

        vm.prank(alice);
        manager.renewSubscription();

        assertEq(manager.subscriptionOf(alice).sponsor, address(0));
        assertEq(earnCoreStub.userSponsor(alice), address(0));
        assertEq(earnCoreStub.setSponsorCalls(), setSponsorCallsBefore);
    }

    function test_renewDoesNotRebindToPartnerEvenIfSeatsBecomeAvailable() public {
        // Even if the partner later buys a pass, renewSubscription never re-runs the resolver.
        _grantGenesisSubscription(admin);
        vm.prank(alice);
        manager.buySubscription(admin); // null sponsor
        assertEq(manager.subscriptionOf(alice).sponsor, address(0));

        skip(uint256(SUBSCRIPTION_DURATION) + 1);

        _addTier(1e6, 5, 500);
        vm.prank(admin);
        manager.buyPackagePass(1, address(0));
        uint32 seatsBefore = passNft.seatsOf(admin);
        uint256 setSponsorCallsBefore = earnCoreStub.setSponsorCalls();

        vm.prank(alice);
        manager.renewSubscription();

        assertEq(manager.subscriptionOf(alice).sponsor, address(0), "renewal must not rebind to partner");
        assertEq(passNft.seatsOf(admin), seatsBefore, "renewal must not consume a partner seat");
        assertEq(earnCoreStub.setSponsorCalls(), setSponsorCallsBefore);
    }

    function test_renewRevertsWhenPaused() public {
        _bootstrapPartnerPass(admin, 10);
        vm.prank(alice);
        manager.buySubscription(admin);

        skip(uint256(SUBSCRIPTION_DURATION) + 1);

        vm.prank(admin);
        manager.pause();

        vm.prank(alice);
        vm.expectRevert(PausableUpgradeable.EnforcedPause.selector);
        manager.renewSubscription();
    }

    function test_renewRevertsWhenPriceZero() public {
        _bootstrapPartnerPass(admin, 10);
        vm.prank(alice);
        manager.buySubscription(admin);

        skip(uint256(SUBSCRIPTION_DURATION) + 1);

        vm.prank(admin);
        manager.setSubscriptionPrice(0);

        vm.prank(alice);
        vm.expectRevert(SubscriptionPriceNotSet.selector);
        manager.renewSubscription();
    }
}
