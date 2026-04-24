// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {SubscriptionTestBase} from "test/shared/subscription/SubscriptionTestBase.sol";
import {SubscriptionManager} from "src/subscription/SubscriptionManager.sol";

/// @notice Focused coverage for the pass-sales Referral Bonus flow — the part driven by the
///         decoupled `_referrers` mapping rather than `subscription.sponsor`.
/// @dev Scenarios exercised:
///         * L1 / L2 payout from a pass purchase when the whole chain has Pass tiers configured.
///         * Null-fallback decoupling: buyer's sub-sponsor falls back to 0x0 because the partner
///           had no seats, but the referral-chain still credits that partner on future pass /
///           upgrade events (per user directive from Apr 2026 — see spec §7.2 "Decoupled
///           referral chain").
///         * Silent no-ops when beneficiary has no Pass / config is inactive.
///         * Upgrade path uses delta as bonus base.
contract ReferralBonusTest is SubscriptionTestBase {
    event ReferralBonusPaid(
        address indexed beneficiary,
        address indexed buyer,
        uint16 beneficiaryTierId,
        uint8 referralDepth,
        uint16 percentageBps,
        uint256 bonusBase,
        uint256 amount,
        bool isUpgrade
    );

    uint16 internal tier1;

    function setUp() public override {
        super.setUp();
        // Cheap reusable tier — acts both as purchasable tier and as "partner has a pass" marker
        // so that `_referralBonusConfig[tier1]` gates apply when the beneficiary owns tier1.
        tier1 = _addTier(200e6, 5, 1_000);
        _grantGenesisSubscription(admin);
        // Enable referral bonus rules on tier1: 20% / 10%.
        vm.prank(admin);
        manager.setReferralBonusConfig(tier1, 2_000, 1_000, true);
    }

    /// @dev Canonical two-line payout via PASS-FIRST path for the buyer (carol), avoiding the
    ///      sub-price side-payment that `buySubscription` would direct to the sponsor.
    ///      Tree: admin -> bob -> carol. carol buys tier1 pass with partner=bob. Expected:
    ///        L1 = bob → 20% * 200e6 = 40e6
    ///        L2 = admin → 10% * 200e6 = 20e6
    function test_buyPass_paysL1AndL2FromReferrers() public {
        vm.prank(admin);
        manager.buyPackagePass(tier1, address(0));

        // bob onboards via admin (sub-price 100e6 → admin) and buys a tier1 pass (partner=admin
        // matches recorded referrer). After this bob has seats available to sponsor carol.
        vm.prank(bob);
        manager.buySubscription(admin);
        vm.prank(bob);
        manager.buyPackagePass(tier1, admin);

        uint256 bobBefore = usdc.balanceOf(bob);
        uint256 adminBefore = usdc.balanceOf(admin);

        vm.expectEmit(true, true, false, true, address(manager));
        emit ReferralBonusPaid(bob, carol, tier1, 1, 2_000, 200e6, 40e6, false);
        vm.expectEmit(true, true, false, true, address(manager));
        emit ReferralBonusPaid(admin, carol, tier1, 2, 1_000, 200e6, 20e6, false);

        // carol goes pass-first through bob → sub.sponsor = bob (seat consumed),
        // _referrers[carol] = bob, no separate sub-price transfer.
        vm.prank(carol);
        manager.buyPackagePass(tier1, bob);

        assertEq(usdc.balanceOf(bob) - bobBefore, 40e6, "L1 (bob) gets 20%");
        assertEq(usdc.balanceOf(admin) - adminBefore, 20e6, "L2 (admin) gets 10%");

        // Cumulative lifetime totals: admin also got L1 when bob bought his own pass earlier
        // (admin was bob's referrer). That 40e6 is from bob's pass purchase, not carol's.
        (uint256 bobL1, uint256 bobL2) = manager.referralBonusPaidTo(bob);
        (uint256 adminL1, uint256 adminL2) = manager.referralBonusPaidTo(admin);
        assertEq(bobL1, 40e6, "bob L1 from carol's pass");
        assertEq(bobL2, 0);
        assertEq(adminL1, 40e6, "admin L1 from bob's pass (earlier) - lifetime cumulative");
        assertEq(adminL2, 20e6, "admin L2 from carol's pass");
        // Total across the whole fixture: bob(L1)40 + admin(L1)40 + admin(L2)20 = 100e6.
        assertEq(manager.totalReferralBonusPaid(), 100e6);
    }

    /// @dev Decoupled-chain scenario: carol buys pass-first with partner=bob.
    ///      At that moment bob has NO seats → sub.sponsor falls back to 0x0 (null fallback).
    ///      But _referrers[carol] = bob is still recorded. Later, when carol ever buys another
    ///      pass / upgrade, L1 = bob would be credited. We simulate this via `upgradePackagePass`.
    function test_buyPassPassFirst_withPartnerNoSeats_stillCreditsL1OnFutureUpgrade() public {
        // admin owns tier1 pass → referral-bonus config eligibility for admin as L2.
        vm.prank(admin);
        manager.buyPackagePass(tier1, address(0));

        // bob onboards via admin BUT admin has no seats anymore (tier1 seats = 5, and we'll
        // burn them below before carol arrives). Simpler setup: bob hasn't bought a pass yet
        // so passless bob means carol's partner=bob → null fallback.
        vm.prank(bob);
        manager.buySubscription(admin);
        // bob did NOT buy a pass → bob has no tier → `_referralBonusConfig[0]` is inactive
        // (no rule for tierId=0), so bob cannot yet receive referral bonuses for depth=1.
        // We intentionally DON'T give bob a pass to verify the silent-no-op path.

        // carol pass-first path through bob.
        vm.prank(carol);
        manager.buyPackagePass(tier1, bob);

        // Sub-sponsor fallback to 0x0 because bob has no seats.
        assertEq(manager.subscriptionOf(carol).sponsor, address(0));
        // But referral-chain recorded.
        assertEq(manager.referrerOf(carol), bob);

        // bob (no Pass → L1 config inactive) is silently skipped. BUT the chain continues: L2 is
        // _referrers[bob] = admin, admin owns tier1 → admin is paid 10% on carol's pass.
        // This matches the user directive "выплата бонуса должна быть передана спонсору первой
        // и второй линии" — L2 is not punished for L1's ineligibility.
        (uint256 bobL1, ) = manager.referralBonusPaidTo(bob);
        (, uint256 adminL2) = manager.referralBonusPaidTo(admin);
        assertEq(bobL1, 0, "bob (no pass) skipped silently at L1");
        assertEq(adminL2, 20e6, "admin (L2) paid 10% of 200e6 = 20 USDC");
        assertEq(manager.totalReferralBonusPaid(), 20e6);

        // Now bob finally buys a Pass (partner=admin preserves bob's existing referrer=admin).
        vm.prank(bob);
        manager.buyPackagePass(tier1, admin);

        // carol upgrades → bonus on delta = tier2 - tier1.
        uint16 tier2 = _addTier(500e6, 15, 1_500);
        vm.prank(admin);
        manager.setReferralBonusConfig(tier2, 2_000, 1_000, true);

        uint256 bobBefore = usdc.balanceOf(bob);
        uint256 adminBefore = usdc.balanceOf(admin);

        vm.prank(carol);
        manager.upgradePackagePass(tier2);

        // delta = 500 - 200 = 300. L1 bob 20% = 60, L2 admin 10% = 30.
        // Beneficiary tier rate is looked up by beneficiary's CURRENT tier — bob on tier1 (20/10),
        // admin on tier1 (20/10). So depth=2 for admin uses 10%.
        assertEq(usdc.balanceOf(bob) - bobBefore, 60e6, "L1 bob credited retroactively via _referrers");
        assertEq(usdc.balanceOf(admin) - adminBefore, 30e6, "L2 admin credited");
    }

    /// @dev Buyer with no referrer at all (partner=0x0 on pass-first): no L1, no L2, no payout,
    ///      but also no revert. Used to validate the early-return in `_payReferralBonuses`.
    function test_buyPassWithZeroPartner_paysNoReferralBonus() public {
        // admin has tier1 pass as potential L1 — not reachable because buyer has no referrer.
        vm.prank(admin);
        manager.buyPackagePass(tier1, address(0));

        uint256 adminBefore = usdc.balanceOf(admin);
        vm.prank(bob);
        manager.buyPackagePass(tier1, address(0));

        assertEq(usdc.balanceOf(admin) - adminBefore, 0);
        assertEq(manager.totalReferralBonusPaid(), 0);
    }

    /// @dev Config.active = false → silently skips that leg (spec §5.5).
    function test_inactiveConfigSkipsPayout() public {
        vm.prank(admin);
        manager.setReferralBonusConfig(tier1, 2_000, 1_000, false);

        vm.prank(admin);
        manager.buyPackagePass(tier1, address(0));

        vm.prank(bob);
        manager.buySubscription(admin);

        uint256 adminBefore = usdc.balanceOf(admin);
        vm.prank(bob);
        manager.buyPackagePass(tier1, admin);
        assertEq(usdc.balanceOf(admin) - adminBefore, 0, "inactive config must not pay");
    }
}
