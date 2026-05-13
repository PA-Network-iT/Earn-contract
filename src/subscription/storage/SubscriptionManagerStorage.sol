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
        uint256 deprecatedRateBpsSlot;
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

    uint16 internal _deprecatedNextBonusTierId;
    mapping(uint16 id => uint256 value) internal _deprecatedSubscriptionSalesSlot1;
    mapping(address beneficiary => uint32 count) internal _deprecatedSubscriptionSalesSlot2;
    mapping(address beneficiary => mapping(uint16 id => bool awarded)) internal _deprecatedSubscriptionSalesSlot3;
    mapping(address beneficiary => uint256 total) internal _deprecatedSubscriptionSalesSlot4;
    uint256 internal _deprecatedSubscriptionSalesSlot5;

    mapping(uint16 tierId => uint256 value) internal _deprecatedReferralBonusSlot0;
    mapping(address beneficiary => uint256 total) internal _deprecatedReferralBonusSlot1;
    mapping(address beneficiary => uint256 total) internal _deprecatedReferralBonusSlot2;
    uint256 internal _deprecatedReferralBonusSlot3;
    mapping(address user => address referrer) internal _deprecatedReferralBonusSlot4;

    // --- KYC authorization ---
    address internal _kycSigner;
    mapping(address user => uint256 nonce) internal _kycNonces;

    // --- reserved ---
    uint256[32] private __gap;
}
