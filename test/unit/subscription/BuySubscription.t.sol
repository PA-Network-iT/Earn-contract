// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {PausableUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";

import {SubscriptionTestBase} from "test/shared/subscription/SubscriptionTestBase.sol";
import {SubscriptionManager} from "src/subscription/SubscriptionManager.sol";
import {
    InvalidSponsor,
    SponsorNotSubscribed,
    SelfSponsorNotAllowed,
    SubscriptionAlreadyExists,
    SubscriptionPriceNotSet
} from "test/shared/subscription/SubscriptionErrors.sol";

/// @notice Unit tests for `SubscriptionManager.buySubscription` (first-time purchases only).
///         Renewal semantics live in `RenewSubscription.t.sol`.
contract BuySubscriptionTest is SubscriptionTestBase {
    event SubscriptionPurchased(
        address indexed user,
        address indexed sponsor,
        uint64 startedAt,
        uint64 expiresAt,
        uint256 pricePaid,
        bool isRenewal
    );
    event SubscriptionRevenueToSponsor(address indexed payer, address indexed sponsor, uint256 amount);

    function test_initialStateNoActiveSubscription() public view {
        assertFalse(manager.hasActiveSubscription(alice));
        assertEq(manager.subscriptionPrice(), SUBSCRIPTION_PRICE);
        assertEq(manager.paymentToken(), address(usdc));
        assertEq(manager.earnCore(), address(earnCoreStub));
    }

    function test_genesisMintMakesUserActive() public {
        _grantGenesisSubscription(admin);

        assertTrue(manager.hasActiveSubscription(admin));
        SubscriptionManager.Subscription memory sub = manager.subscriptionOf(admin);
        assertEq(sub.sponsor, address(0));
        assertEq(sub.startedAt, uint64(block.timestamp));
        assertEq(sub.expiresAt, type(uint64).max);
    }

    function test_buySubscriptionHappyPath() public {
        _bootstrapPartnerPass(admin, 10);

        uint256 treasuryBefore = usdc.balanceOf(treasury);
        uint256 aliceBefore = usdc.balanceOf(alice);
        uint256 adminBefore = usdc.balanceOf(admin);
        uint256 managerBefore = usdc.balanceOf(address(manager));
        uint256 sweptBefore = manager.totalRevenueSwept();

        vm.expectEmit(true, true, false, true, address(manager));
        emit SubscriptionRevenueToSponsor(alice, admin, SUBSCRIPTION_PRICE);
        vm.expectEmit(true, true, false, true, address(manager));
        emit SubscriptionPurchased(
            alice,
            admin,
            uint64(block.timestamp),
            uint64(block.timestamp) + SUBSCRIPTION_DURATION,
            SUBSCRIPTION_PRICE,
            false
        );

        vm.prank(alice);
        manager.buySubscription(admin);

        assertTrue(manager.hasActiveSubscription(alice));
        SubscriptionManager.Subscription memory sub = manager.subscriptionOf(alice);
        assertEq(sub.sponsor, admin);
        assertEq(sub.startedAt, uint64(block.timestamp));
        assertEq(sub.expiresAt, uint64(block.timestamp) + SUBSCRIPTION_DURATION);

        // Revenue routes direct-to-sponsor: admin gets the full price, treasury gets nothing.
        assertEq(usdc.balanceOf(admin) - adminBefore, SUBSCRIPTION_PRICE);
        assertEq(usdc.balanceOf(treasury) - treasuryBefore, 0);
        assertEq(aliceBefore - usdc.balanceOf(alice), SUBSCRIPTION_PRICE);
        assertEq(usdc.balanceOf(address(manager)), managerBefore, "manager holds no new USDC when sponsor is live");

        assertEq(subNft.balanceOf(alice), 1);
        assertEq(subNft.ownerOf(subNft.tokenIdOf(alice)), alice);

        assertEq(earnCoreStub.userSponsor(alice), admin);
        assertEq(earnCoreStub.setSponsorCalls(), 1);

        // Direct-to-sponsor payouts bypass the contract balance, so `totalRevenueSwept` is untouched.
        assertEq(manager.totalRevenueSwept() - sweptBefore, 0);
    }

    function test_buySubscriptionNullSponsorRetainsRevenueOnContract() public {
        // admin has a genesis sub but no pass -> seats = 0 -> null fallback.
        _grantGenesisSubscription(admin);

        uint256 treasuryBefore = usdc.balanceOf(treasury);
        uint256 adminBefore = usdc.balanceOf(admin);
        uint256 managerBefore = usdc.balanceOf(address(manager));

        vm.expectEmit(true, true, false, true, address(manager));
        emit SubscriptionRevenueToSponsor(alice, address(0), SUBSCRIPTION_PRICE);

        vm.prank(alice);
        manager.buySubscription(admin);

        assertEq(manager.subscriptionOf(alice).sponsor, address(0));
        // USDC stays on the manager as collected revenue awaiting sweep.
        assertEq(usdc.balanceOf(address(manager)) - managerBefore, SUBSCRIPTION_PRICE);
        assertEq(usdc.balanceOf(treasury) - treasuryBefore, 0);
        assertEq(usdc.balanceOf(admin) - adminBefore, 0);
        assertEq(manager.totalRevenueSwept(), 0);
        assertEq(manager.pendingRevenue(), usdc.balanceOf(address(manager)));
    }

    function test_buySubscriptionRevertsOnZeroSponsor() public {
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(InvalidSponsor.selector, address(0)));
        manager.buySubscription(address(0));
    }

    function test_buySubscriptionRevertsOnSelfSponsor() public {
        vm.prank(alice);
        vm.expectRevert(SelfSponsorNotAllowed.selector);
        manager.buySubscription(alice);
    }

    function test_buySubscriptionRevertsIfSponsorNotActive() public {
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(SponsorNotSubscribed.selector, bob));
        manager.buySubscription(bob);
    }

    function test_buySubscriptionRevertsIfAlreadyHasSubscription() public {
        _bootstrapPartnerPass(admin, 10);

        vm.prank(alice);
        manager.buySubscription(admin);

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(SubscriptionAlreadyExists.selector, alice));
        manager.buySubscription(admin);
    }

    function test_buySubscriptionRevertsAfterExpiryBecauseRecordExists() public {
        // Expired subs still revert buySubscription — users must call renewSubscription instead.
        _bootstrapPartnerPass(admin, 10);

        vm.prank(alice);
        manager.buySubscription(admin);

        skip(uint256(SUBSCRIPTION_DURATION) + 1);
        assertFalse(manager.hasActiveSubscription(alice));

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(SubscriptionAlreadyExists.selector, alice));
        manager.buySubscription(admin);
    }

    function test_buySubscriptionRevertsWhenPaused() public {
        _bootstrapPartnerPass(admin, 10);
        vm.prank(admin);
        manager.pause();

        vm.prank(alice);
        vm.expectRevert(PausableUpgradeable.EnforcedPause.selector);
        manager.buySubscription(admin);
    }

    function test_buySubscriptionRevertsWhenPriceZero() public {
        _bootstrapPartnerPass(admin, 10);

        vm.prank(admin);
        manager.setSubscriptionPrice(0);

        vm.prank(alice);
        vm.expectRevert(SubscriptionPriceNotSet.selector);
        manager.buySubscription(admin);
    }
}
