// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

/// @dev Storage layout for `SubscriptionManager`. Append-only for proxy safety.
abstract contract SubscriptionManagerStorage {
    // --- external contracts ---
    address internal _earnCore;
    address internal _subscriptionNFT;
    address internal _packagePassNFT;
    address internal _paymentToken;

    // --- pricing / duration ---
    uint256 internal _subscriptionPrice;

    // --- subscriptions ---
    struct Subscription {
        uint64 startedAt;
        uint64 expiresAt;
        address sponsor;
    }
    mapping(address user => Subscription subscription) internal _subscriptions;

    // --- package passes ---
    /// @dev `seats` is the ABSOLUTE number of seats this tier grants, NOT an incremental delta.
    ///      When a user upgrades onto this tier their remaining seats become
    ///      `seats - pass.consumedSeats`, which makes upgrade arithmetic immune to retroactive
    ///      admin edits of any previously-bought tier (old-tier storage is never read again).
    struct Tier {
        uint256 price;
        uint32 seats;
        uint256 sponsorRateBps;
        bool active;
        string metadataURI;
    }
    uint16 internal _nextTierId;
    mapping(uint16 tierId => Tier tier) internal _tiers;

    /// @dev Invariant: `seats + consumedSeats` equals the absolute seat count that the tier at
    ///      `tierId` granted this owner at their most recent buy/upgrade. `consumedSeats` is a
    ///      lifetime monotonic counter (it is NOT reset on upgrade), which is what makes the
    ///      invariant hold across multiple upgrades without a historical snapshot field.
    struct Pass {
        uint16 tierId;
        uint32 seats;
        uint32 consumedSeats;
        uint64 purchasedAt;
    }
    mapping(address owner => Pass pass) internal _passes;

    // --- revenue accounting (for audit) ---
    // Cumulative amount of `_paymentToken` that left this contract via `sweep`. Does not count
    // direct sponsor payouts from `buySubscription` (those bypass the contract balance — see spec
    // §7.1). Intended to be read alongside `IERC20(_paymentToken).balanceOf(this)` to monitor
    // collected-but-not-yet-swept revenue.
    uint256 internal _totalRevenueSwept;

    // --- subscription sales bonus (cumulative tier-based referral rewards) ---
    // See: docs/Subscription Sales Bonus.md. Each first-time successful subscription purchase
    // routed through `buySubscription(partner)` with a non-zero effective sponsor records one
    // lifetime qualified referral against that sponsor and evaluates active bonus tiers. Any tier
    // whose `minReferrals` threshold is satisfied and has not yet been awarded to the sponsor
    // triggers an immediate USDC payout from this contract's balance.
    struct BonusTier {
        uint32 minReferrals;     // qualified-referral threshold; strictly positive
        uint256 rewardAmount;    // cash reward in `_paymentToken` units; strictly positive
        bool active;             // only active tiers participate in evaluation
        uint16 sortOrder;        // informational display/order hint; evaluation is by tierId
    }

    uint16 internal _nextBonusTierId;
    mapping(uint16 bonusTierId => BonusTier bonusTier) internal _bonusTiers;

    // Lifetime count of qualified referrals credited to a beneficiary. Never decreases.
    mapping(address beneficiary => uint32 count) internal _qualifiedReferralCount;

    // `_bonusAwarded[beneficiary][bonusTierId]` — true once the tier has been awarded to that
    // beneficiary. Enforces "each tier awarded only once per beneficiary" (spec §5.2 / §12).
    mapping(address beneficiary => mapping(uint16 bonusTierId => bool awarded)) internal _bonusAwarded;

    // Per-beneficiary cumulative bonus payout total (for reporting / reconciliation).
    mapping(address beneficiary => uint256 total) internal _totalBonusAwardedTo;

    // Global cumulative bonus payout total across all beneficiaries.
    uint256 internal _totalBonusPaid;

    // --- referral bonus (Pass Sales) — docs/Referral Bonus.md ---
    // Package-based L1/L2 referral rates keyed by Pass tier. The percentage applied to a bonus
    // event is looked up on the BENEFICIARY's current Pass tier, not the buyer's (spec §5.2 /
    // §7 "Package matching rule"). Default-zero entry means no rule configured → inactive, no
    // payout. Changes take effect on future eligible events only (spec §5.4).
    struct ReferralBonusConfig {
        uint16 firstLineBps;    // 1st-line (direct parent) rate in basis points
        uint16 secondLineBps;   // 2nd-line (grandparent) rate in basis points
        bool active;            // master switch for this Pass tier's rules
    }
    mapping(uint16 tierId => ReferralBonusConfig config) internal _referralBonusConfig;

    // Per-beneficiary cumulative referral-bonus totals split by referral depth (reporting §13).
    mapping(address beneficiary => uint256 total) internal _referralBonusFirstLinePaid;
    mapping(address beneficiary => uint256 total) internal _referralBonusSecondLinePaid;

    // Global cumulative referral-bonus payout across all beneficiaries (reporting §13).
    uint256 internal _totalReferralBonusPaid;

    // --- referral chain (Pass Sales) ---
    // Per-user requested referrer, captured on the FIRST sponsor-bearing entrypoint
    // (`buySubscription(partner)` or `buyPackagePass(tierId, partner)` when `partner != 0x0`).
    // Immutable once set (same write-once semantics as `subscription.sponsor` — see I-2). Drives
    // referral-bonus chain resolution in `_payReferralBonuses` (L1 = `_referrers[buyer]`,
    // L2 = `_referrers[L1]`). DECOUPLED from `subscription.sponsor`: the latter may be `0x0` due
    // to null-fallback (partner had no seats), yet the referrer chain still records the requested
    // partner so that their future pass / upgrade events still credit L1 / L2 referral bonuses.
    mapping(address user => address referrer) internal _referrers;

    // --- reserved ---
    uint256[34] private __gap;
}
