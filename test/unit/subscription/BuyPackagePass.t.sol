// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {PausableUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";

import {SubscriptionTestBase} from "test/shared/subscription/SubscriptionTestBase.sol";
import {SubscriptionManager} from "src/subscription/SubscriptionManager.sol";
import {
    InvalidTier,
    TierInactive,
    PassAlreadyExists,
    SponsorNotSubscribed,
    SelfSponsorNotAllowed
} from "test/shared/subscription/SubscriptionErrors.sol";

/// @notice Unit tests for `SubscriptionManager.buyPackagePass`.
/// @dev Pass purchase no longer requires a prior subscription — it implicitly grants a 20-year
///      one (`PASS_SUBSCRIPTION_DURATION`). Existing subscriptions are extended (never shortened),
///      and sponsor / startedAt / SubscriptionNFT are preserved per I-2 / I-2a.
contract BuyPackagePassTest is SubscriptionTestBase {
    event KycAuthorizationConsumed(address indexed user, uint8 indexed scope, uint256 nonce, uint64 expiresAt);
    event PackagePassPurchased(address indexed user, uint16 indexed tierId, uint32 seats, uint256 pricePaid);
    event PackagePassGranted(address indexed user, uint16 indexed tierId, uint32 seats);
    event SubscriptionPurchased(
        address indexed user,
        address indexed sponsor,
        uint64 startedAt,
        uint64 expiresAt,
        uint256 pricePaid,
        bool isRenewal
    );

    uint16 internal tier1;
    uint16 internal tier2;

    function setUp() public override {
        super.setUp();
        tier1 = _addTier(200e6, 5);
        tier2 = _addTier(500e6, 15);
        _grantGenesisSubscription(admin);
    }

    function test_buyPackagePassHappyPath() public {
        // alice arrives with no subscription at all — pass purchase alone must succeed.
        assertFalse(manager.hasActiveSubscription(alice));

        uint256 treasuryBefore = usdc.balanceOf(treasury);
        uint256 aliceBefore = usdc.balanceOf(alice);
        uint64 expectedExpiresAt = uint64(block.timestamp) + manager.PASS_SUBSCRIPTION_DURATION();

        vm.expectEmit(true, true, false, true, address(manager));
        emit KycAuthorizationConsumed(alice, TEST_KYC_SCOPE_PACKAGE_PASS, 0, uint64(block.timestamp + 1 hours));
        vm.expectEmit(true, true, false, true, address(manager));
        emit SubscriptionPurchased(alice, address(0), uint64(block.timestamp), expectedExpiresAt, 0, false);
        vm.expectEmit(true, true, false, true, address(manager));
        emit PackagePassPurchased(alice, tier1, 5, 200e6);

        _buyPackagePass(alice, tier1, address(0));

        SubscriptionManager.Pass memory p = manager.passOf(alice);
        assertEq(p.tierId, tier1);
        assertEq(p.seats, 5);
        assertEq(p.purchasedAt, uint64(block.timestamp));

        // Pass purchase bundles a 20y subscription with sponsor = 0x0.
        assertTrue(manager.hasActiveSubscription(alice));
        SubscriptionManager.Subscription memory sub = manager.subscriptionOf(alice);
        assertEq(sub.sponsor, address(0));
        assertEq(sub.startedAt, uint64(block.timestamp));
        assertEq(sub.expiresAt, expectedExpiresAt);

        // SubscriptionNFT minted once as part of the pass purchase.
        assertEq(subNft.balanceOf(alice), 1);
        assertEq(subNft.ownerOf(subNft.tokenIdOf(alice)), alice);

        // Treasury receives nothing synchronously — pass revenue stays on the manager awaiting sweep.
        assertEq(usdc.balanceOf(treasury) - treasuryBefore, 0);
        assertEq(aliceBefore - usdc.balanceOf(alice), 200e6);
        // Only the pass price — alice never called buySubscription.
        assertEq(usdc.balanceOf(address(manager)), 200e6);

        assertEq(passNft.ownerOf(passNft.tokenIdOf(alice)), alice);
        assertEq(passNft.tierOf(alice), tier1);
        assertEq(passNft.seatsOf(alice), 5);

        assertEq(manager.totalRevenueSwept(), 0);
        assertEq(manager.pendingRevenue(), 200e6);
    }

    function test_adminGrantPackagePassHappyPath() public {
        assertFalse(manager.hasActiveSubscription(bob));

        uint64 expectedExpiresAt = uint64(block.timestamp) + manager.PASS_SUBSCRIPTION_DURATION();

        vm.expectEmit(true, true, false, true, address(manager));
        emit SubscriptionPurchased(bob, address(0), uint64(block.timestamp), expectedExpiresAt, 0, false);
        vm.expectEmit(true, true, false, true, address(manager));
        emit PackagePassGranted(bob, tier1, 5);

        vm.prank(admin);
        manager.adminGrantPackagePass(bob, tier1);

        SubscriptionManager.Pass memory p = manager.passOf(bob);
        assertEq(p.tierId, tier1);
        assertEq(p.seats, 5);
        assertEq(p.consumedSeats, 0);
        assertEq(p.purchasedAt, uint64(block.timestamp));

        SubscriptionManager.Subscription memory sub = manager.subscriptionOf(bob);
        assertEq(sub.sponsor, address(0));
        assertEq(sub.startedAt, uint64(block.timestamp));
        assertEq(sub.expiresAt, expectedExpiresAt);

        assertEq(passNft.ownerOf(passNft.tokenIdOf(bob)), bob);
        assertEq(passNft.tierOf(bob), tier1);
        assertEq(passNft.seatsOf(bob), 5);
        assertEq(subNft.ownerOf(subNft.tokenIdOf(bob)), bob);
        assertEq(usdc.balanceOf(address(manager)), 0);
        assertEq(manager.pendingRevenue(), 0);
    }

    function test_adminGrantPackagePassPreservesExistingLongerSubscription() public {
        _grantGenesisSubscription(bob);

        vm.expectEmit(true, true, false, true, address(manager));
        emit PackagePassGranted(bob, tier1, 5);

        vm.prank(admin);
        manager.adminGrantPackagePass(bob, tier1);

        assertEq(manager.subscriptionOf(bob).expiresAt, type(uint64).max);
        assertEq(subNft.balanceOf(bob), 1);
        assertEq(passNft.tierOf(bob), tier1);
    }

    function test_adminGrantPackagePassRevertsIfPassAlreadyExists() public {
        vm.prank(admin);
        manager.adminGrantPackagePass(bob, tier1);

        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(PassAlreadyExists.selector, bob));
        manager.adminGrantPackagePass(bob, tier2);
    }

    function test_adminGrantPackagePassRevertsOnInactiveTier() public {
        vm.prank(admin);
        manager.removeTier(tier1);

        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(TierInactive.selector, tier1));
        manager.adminGrantPackagePass(bob, tier1);
    }

    function test_buyPassFirstTimeGrants20YearSubscriptionWithNullSponsor() public {
        uint64 t0 = uint64(block.timestamp);
        uint64 passDur = manager.PASS_SUBSCRIPTION_DURATION();
        assertEq(passDur, uint64(20 * 365 days));

        _buyPackagePass(bob, tier1, address(0));

        SubscriptionManager.Subscription memory sub = manager.subscriptionOf(bob);
        assertEq(sub.startedAt, t0);
        assertEq(sub.expiresAt, t0 + passDur);
        assertEq(sub.sponsor, address(0));
    }

    function test_buyPassExtendsExistingShorterSubscriptionTo20Years() public {
        // _bootstrapPartnerPass: admin gets genesis sub + tier T; alice then buys a sub via admin.
        // alice's sub is 365 days and sponsor == admin.
        uint16 partnerTier = _bootstrapPartnerPass(admin, 10);
        vm.prank(alice);
        manager.buySubscription(admin);

        SubscriptionManager.Subscription memory before_ = manager.subscriptionOf(alice);
        assertEq(before_.sponsor, admin);
        uint64 originalStartedAt = before_.startedAt;
        uint64 originalExpiresAt = before_.expiresAt; // = t + 365d

        uint64 passDur = manager.PASS_SUBSCRIPTION_DURATION();
        uint64 expectedExpires = uint64(block.timestamp) + passDur;

        // isRenewal = true because alice already had a record.
        vm.expectEmit(true, true, false, true, address(manager));
        emit SubscriptionPurchased(alice, admin, originalStartedAt, expectedExpires, 0, true);
        _buyPackagePass(alice, tier1, address(0));

        SubscriptionManager.Subscription memory after_ = manager.subscriptionOf(alice);
        assertEq(after_.startedAt, originalStartedAt, "startedAt immutable");
        assertEq(after_.sponsor, admin, "sponsor immutable");
        assertGt(after_.expiresAt, originalExpiresAt, "expiresAt must extend");
        assertEq(after_.expiresAt, expectedExpires);

        // NFT is NOT re-minted — alice already had one from buySubscription.
        assertEq(subNft.balanceOf(alice), 1);
        // keeps compiler from eliding the return value of _bootstrapPartnerPass.
        assertGt(partnerTier, 0);
    }

    function test_buyPassDoesNotShortenGenesisOrLongerSubscription() public {
        // admin has the genesis sub at type(uint64).max. Pass purchase must not shorten it.
        uint64 maxTs = type(uint64).max;
        assertEq(manager.subscriptionOf(admin).expiresAt, maxTs);

        // No SubscriptionPurchased event should fire — existing already covers the target window.
        // (We can't easily assert "no emit" without `recordLogs`; assert state instead.)
        _buyPackagePass(admin, tier1, address(0));

        assertEq(manager.subscriptionOf(admin).expiresAt, maxTs, "genesis expiresAt must stay untouched");
        assertEq(manager.subscriptionOf(admin).sponsor, address(0));
        // admin still has exactly one SubscriptionNFT from the genesis mint.
        assertEq(subNft.balanceOf(admin), 1);
    }

    function test_buyPassRevertsOnUnknownTier() public {
        bytes memory authorization = _kycAuthorizationForManager(alice);
        vm.expectRevert(abi.encodeWithSelector(InvalidTier.selector, uint16(99)));
        vm.prank(alice);
        manager.buyPackagePass(99, address(0), authorization);
    }

    function test_buyPassRevertsOnInactiveTier() public {
        vm.prank(admin);
        manager.removeTier(tier1);

        bytes memory authorization = _kycAuthorizationForManager(alice);
        vm.expectRevert(abi.encodeWithSelector(TierInactive.selector, tier1));
        vm.prank(alice);
        manager.buyPackagePass(tier1, address(0), authorization);
    }

    function test_buyPassRevertsIfPassAlreadyExists() public {
        _buyPackagePass(alice, tier1, address(0));

        bytes memory authorization = _kycAuthorizationForManager(alice);
        vm.expectRevert(abi.encodeWithSelector(PassAlreadyExists.selector, alice));
        vm.prank(alice);
        manager.buyPackagePass(tier2, address(0), authorization);
    }

    function test_buyPassRevertsWhenPaused() public {
        vm.prank(admin);
        manager.pause();

        bytes memory authorization = _kycAuthorizationForManager(alice);
        vm.expectRevert(PausableUpgradeable.EnforcedPause.selector);
        vm.prank(alice);
        manager.buyPackagePass(tier1, address(0), authorization);
    }

    // ========================================================================
    // partner-arg semantics for first-time sponsor binding
    // ========================================================================

    /// @dev Partner with available seats: resolver consumes a seat, sub.sponsor = partner.
    function test_buyPassFirstTimeWithPartnerSeats_bindsSponsor() public {
        _bootstrapPartnerPass(admin, 3);
        uint32 adminSeatsBefore = passNft.seatsOf(admin);

        _buyPackagePass(bob, tier1, admin);

        SubscriptionManager.Subscription memory sub = manager.subscriptionOf(bob);
        assertEq(sub.sponsor, admin, "sub sponsor = admin (seat consumed)");

        assertEq(passNft.seatsOf(admin), adminSeatsBefore - 1, "admin seat consumed");
    }

    /// @dev Partner without seats: sub.sponsor falls back to 0x0.
    function test_buyPassFirstTimeWithPartnerNoSeats_nullSponsor() public {
        // admin has genesis sub but NO pass -> zero seats for sponsorship resolution.
        assertEq(passNft.tierOf(admin), 0);

        _buyPackagePass(bob, tier1, admin);

        SubscriptionManager.Subscription memory sub = manager.subscriptionOf(bob);
        assertEq(sub.sponsor, address(0), "null-fallback on sub sponsor");
    }

    /// @dev partner == 0x0: sponsor stays empty.
    function test_buyPassFirstTimeWithZeroPartner_noSponsor() public {
        _buyPackagePass(bob, tier1, address(0));

        assertEq(manager.subscriptionOf(bob).sponsor, address(0));
    }

    function test_buyPassRevertsWhenPartnerIsSelf() public {
        bytes memory authorization = _kycAuthorizationForManager(bob);
        vm.expectRevert(SelfSponsorNotAllowed.selector);
        vm.prank(bob);
        manager.buyPackagePass(tier1, bob, authorization);
    }

    function test_buyPassRevertsWhenPartnerHasNoSubscription() public {
        // `carol` is a fresh wallet — no subscription.
        address carol = makeAddr("carol");
        bytes memory authorization = _kycAuthorizationForManager(bob);
        vm.expectRevert(abi.encodeWithSelector(SponsorNotSubscribed.selector, carol));
        vm.prank(bob);
        manager.buyPackagePass(tier1, carol, authorization);
    }

    /// @dev Existing subscriber: pass purchase preserves the original sponsor and does not
    ///      re-run the sponsor resolver, even if a non-zero partner is supplied.
    function test_buyPassWithPartnerForExistingSubscriberPreservesSponsor() public {
        _bootstrapPartnerPass(admin, 5);
        vm.prank(alice);
        manager.buySubscription(admin);

        address eve = makeAddr("eve");

        _buyPackagePass(alice, tier1, eve);

        assertEq(manager.subscriptionOf(alice).sponsor, admin, "sponsor unchanged");
    }

    /// @dev Resolver is NOT re-run for existing subscribers — no extra seat consumed beyond the
    ///      one burned in buySubscription.
    function test_buyPassDoesNotConsumeExtraSeatForExistingSubscriber() public {
        _bootstrapPartnerPass(admin, 5);
        vm.prank(alice);
        manager.buySubscription(admin);

        _buyPackagePass(alice, tier1, admin);

        assertEq(passNft.seatsOf(admin), 4);
    }
}
