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
    SelfSponsorNotAllowed,
    ReferrerMismatch
} from "test/shared/subscription/SubscriptionErrors.sol";

/// @notice Unit tests for `SubscriptionManager.buyPackagePass`.
/// @dev Pass purchase no longer requires a prior subscription — it implicitly grants a 20-year
///      one (`PASS_SUBSCRIPTION_DURATION`). Existing subscriptions are extended (never shortened),
///      and sponsor / startedAt / SubscriptionNFT are preserved per I-2 / I-2a.
contract BuyPackagePassTest is SubscriptionTestBase {
    event PackagePassPurchased(
        address indexed user,
        uint16 indexed tierId,
        uint32 seats,
        uint256 pricePaid,
        uint256 sponsorRateBps
    );
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
        tier1 = _addTier(200e6, 5, 1_000);
        tier2 = _addTier(500e6, 15, 1_500);
        _grantGenesisSubscription(admin);
    }

    function test_buyPackagePassHappyPath() public {
        // alice arrives with no subscription at all — pass purchase alone must succeed.
        assertFalse(manager.hasActiveSubscription(alice));

        uint256 treasuryBefore = usdc.balanceOf(treasury);
        uint256 aliceBefore = usdc.balanceOf(alice);
        uint64 expectedExpiresAt = uint64(block.timestamp) + manager.PASS_SUBSCRIPTION_DURATION();

        vm.expectEmit(true, true, false, true, address(manager));
        emit SubscriptionPurchased(alice, address(0), uint64(block.timestamp), expectedExpiresAt, 0, false);
        vm.expectEmit(true, true, false, true, address(manager));
        emit PackagePassPurchased(alice, tier1, 5, 200e6, 1_000);

        vm.prank(alice);
        manager.buyPackagePass(tier1, address(0));

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

        assertEq(earnCoreStub.sponsorRateBps(alice), 1_000);
        assertEq(earnCoreStub.setSponsorRateCalls(), 1);

        assertEq(manager.totalRevenueSwept(), 0);
        assertEq(manager.pendingRevenue(), 200e6);
    }

    function test_buyPassFirstTimeGrants20YearSubscriptionWithNullSponsor() public {
        uint64 t0 = uint64(block.timestamp);
        uint64 passDur = manager.PASS_SUBSCRIPTION_DURATION();
        assertEq(passDur, uint64(20 * 365 days));

        vm.prank(bob);
        manager.buyPackagePass(tier1, address(0));

        SubscriptionManager.Subscription memory sub = manager.subscriptionOf(bob);
        assertEq(sub.startedAt, t0);
        assertEq(sub.expiresAt, t0 + passDur);
        assertEq(sub.sponsor, address(0));
        // EarnCore setSponsor was NOT called for bob — sponsor binding is only through buySubscription.
        assertEq(earnCoreStub.setSponsorCalls(), 0);
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
        vm.prank(alice);
        manager.buyPackagePass(tier1, address(0));

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
        vm.prank(admin);
        manager.buyPackagePass(tier1, address(0));

        assertEq(manager.subscriptionOf(admin).expiresAt, maxTs, "genesis expiresAt must stay untouched");
        assertEq(manager.subscriptionOf(admin).sponsor, address(0));
        // admin still has exactly one SubscriptionNFT from the genesis mint.
        assertEq(subNft.balanceOf(admin), 1);
    }

    function test_buyPassRevertsOnUnknownTier() public {
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(InvalidTier.selector, uint16(99)));
        manager.buyPackagePass(99, address(0));
    }

    function test_buyPassRevertsOnInactiveTier() public {
        vm.prank(admin);
        manager.removeTier(tier1);

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(TierInactive.selector, tier1));
        manager.buyPackagePass(tier1, address(0));
    }

    function test_buyPassRevertsIfPassAlreadyExists() public {
        vm.prank(alice);
        manager.buyPackagePass(tier1, address(0));

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(PassAlreadyExists.selector, alice));
        manager.buyPackagePass(tier2, address(0));
    }

    function test_buyPassRevertsWhenPaused() public {
        vm.prank(admin);
        manager.pause();

        vm.prank(alice);
        vm.expectRevert(PausableUpgradeable.EnforcedPause.selector);
        manager.buyPackagePass(tier1, address(0));
    }

    // ========================================================================
    // partner-arg semantics (decoupled sub-sponsor vs. referral chain)
    // ========================================================================

    /// @dev Partner with available seats: resolver consumes a seat, sub.sponsor = partner,
    ///      `_referrers[buyer] = partner`, EarnCore mirror updated.
    function test_buyPassFirstTimeWithPartnerSeats_bindsSponsorAndReferrer() public {
        _bootstrapPartnerPass(admin, 3);
        uint32 adminSeatsBefore = passNft.seatsOf(admin);

        vm.prank(bob);
        manager.buyPackagePass(tier1, admin);

        SubscriptionManager.Subscription memory sub = manager.subscriptionOf(bob);
        assertEq(sub.sponsor, admin, "sub sponsor = admin (seat consumed)");
        assertEq(manager.referrerOf(bob), admin, "referrer = admin");

        assertEq(passNft.seatsOf(admin), adminSeatsBefore - 1, "admin seat consumed");

        assertEq(earnCoreStub.userSponsor(bob), admin);
        assertEq(earnCoreStub.setSponsorCalls(), 1);
    }

    /// @dev Partner without seats: sub.sponsor falls back to 0x0, but `_referrers[buyer] = partner`
    ///      is still recorded — future pass / upgrade events by buyer still credit L1/L2 referral
    ///      bonuses to that partner chain.
    function test_buyPassFirstTimeWithPartnerNoSeats_nullSponsorButReferrerRecorded() public {
        // admin has genesis sub but NO pass -> zero seats for sponsorship resolution.
        assertEq(passNft.tierOf(admin), 0);

        vm.prank(bob);
        manager.buyPackagePass(tier1, admin);

        SubscriptionManager.Subscription memory sub = manager.subscriptionOf(bob);
        assertEq(sub.sponsor, address(0), "null-fallback on sub sponsor");
        assertEq(manager.referrerOf(bob), admin, "referrer still recorded");

        // EarnCore still mirrored with address(0) to keep sub-sponsor state consistent.
        assertEq(earnCoreStub.userSponsor(bob), address(0));
        assertEq(earnCoreStub.setSponsorCalls(), 1);
    }

    /// @dev partner == 0x0 (no referral link at all): both sponsor and referrer stay empty,
    ///      no EarnCore mirror call is made.
    function test_buyPassFirstTimeWithZeroPartner_noReferrerNoSponsorCall() public {
        vm.prank(bob);
        manager.buyPackagePass(tier1, address(0));

        assertEq(manager.subscriptionOf(bob).sponsor, address(0));
        assertEq(manager.referrerOf(bob), address(0));
        assertEq(earnCoreStub.setSponsorCalls(), 0, "no setSponsor on pass-first w/o partner");
    }

    function test_buyPassRevertsWhenPartnerIsSelf() public {
        vm.prank(bob);
        vm.expectRevert(SelfSponsorNotAllowed.selector);
        manager.buyPackagePass(tier1, bob);
    }

    function test_buyPassRevertsWhenPartnerHasNoSubscription() public {
        // `carol` is a fresh wallet — no subscription.
        address carol = makeAddr("carol");
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(SponsorNotSubscribed.selector, carol));
        manager.buyPackagePass(tier1, carol);
    }

    /// @dev Existing subscriber: `partner` must be 0x0 or equal to the stored `_referrers[user]`.
    function test_buyPassRevertsOnReferrerMismatchForExistingSubscriber() public {
        _bootstrapPartnerPass(admin, 5);
        // alice subscribes via admin → _referrers[alice] = admin.
        vm.prank(alice);
        manager.buySubscription(admin);

        address eve = makeAddr("eve");

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(ReferrerMismatch.selector, alice, admin, eve));
        manager.buyPackagePass(tier1, eve);
    }

    /// @dev Existing subscriber can re-pass the same referrer without revert (idempotent UI call).
    function test_buyPassAcceptsMatchingReferrerForExistingSubscriber() public {
        _bootstrapPartnerPass(admin, 5);
        vm.prank(alice);
        manager.buySubscription(admin);

        vm.prank(alice);
        manager.buyPackagePass(tier1, admin);

        assertEq(manager.referrerOf(alice), admin, "referrer unchanged");
        // Resolver is NOT re-run for existing subscribers — no extra seat consumed beyond the one
        // burned in buySubscription.
        assertEq(passNft.seatsOf(admin), 4);
    }
}
