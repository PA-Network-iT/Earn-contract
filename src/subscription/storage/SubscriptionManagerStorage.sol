// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

/// @notice Sequential storage layout for `SubscriptionManager`.
/// @dev Append-only from here on: new variables go at the end and consume slots from `__gap`.
///
///      This layout is written for a FRESH deployment. The deprecated referral / bonus placeholder
///      slots carried by earlier implementations were dropped, so upgrading a pre-rewrite proxy
///      onto this layout would corrupt storage — deploy new proxies instead.
///
///      Timelocked security state (pending upgrade, pending treasury wallet) lives in namespaced
///      slots inside `DelayedUUPSUpgradeable` / `TreasuryWalletTimelock`, not in this layout.
abstract contract SubscriptionManagerStorage {
    // --- external contracts ---

    /// @dev EarnCore proxy this manager gates.
    address internal _earnCore;
    /// @dev Soulbound subscription NFT.
    address internal _subscriptionNFT;
    /// @dev Soulbound package pass NFT.
    address internal _packagePassNFT;
    /// @dev ERC-20 accepted for subscriptions and passes (USDC).
    address internal _paymentToken;

    // --- pricing ---

    /// @dev Price of one 365-day subscription, in payment token decimals.
    uint256 internal _subscriptionPrice;

    // --- subscriptions ---

    /// @notice Subscription record for a user.
    /// @param startedAt First-purchase timestamp; never changes on renewal.
    /// @param expiresAt Expiry timestamp; zero means the user never subscribed.
    /// @param sponsor Effective sponsor resolved at first purchase; zero on null fallback.
    struct Subscription {
        uint64 startedAt;
        uint64 expiresAt;
        address sponsor;
    }

    mapping(address user => Subscription subscription) internal _subscriptions;

    // --- package passes ---

    /// @notice Package pass tier definition.
    /// @dev `seats` is the ABSOLUTE number of seats this tier grants, NOT an incremental delta.
    ///      When a user upgrades onto this tier their remaining seats become
    ///      `seats - pass.consumedSeats`, which makes upgrade arithmetic immune to retroactive
    ///      admin edits of any previously-bought tier (old-tier storage is never read again).
    /// @param price Price in payment token decimals.
    /// @param seats Absolute seat allowance granted to a holder of this tier.
    /// @param deprecatedRateBpsSlot Retained placeholder from the removed bonus-rate feature.
    /// @param active Whether the tier can currently be bought or upgraded into.
    /// @param metadataURI Off-chain metadata pointer.
    struct Tier {
        uint256 price;
        uint32 seats;
        uint256 deprecatedRateBpsSlot;
        bool active;
        string metadataURI;
    }

    uint16 internal _nextTierId;
    mapping(uint16 tierId => Tier tier) internal _tiers;

    /// @notice Package pass held by an owner.
    /// @dev Invariant: `seats + consumedSeats` equals the absolute seat count that the tier at
    ///      `tierId` granted this owner at their most recent buy/upgrade. `consumedSeats` is a
    ///      lifetime monotonic counter (it is NOT reset on upgrade), which is what makes the
    ///      invariant hold across multiple upgrades without a historical snapshot field.
    /// @param tierId Current tier; zero means no pass.
    /// @param seats Seats still available for sponsoring new subscribers.
    /// @param consumedSeats Lifetime number of seats already spent.
    /// @param purchasedAt First pass purchase timestamp.
    struct Pass {
        uint16 tierId;
        uint32 seats;
        uint32 consumedSeats;
        uint64 purchasedAt;
    }

    mapping(address owner => Pass pass) internal _passes;

    // --- revenue accounting (for audit) ---

    /// @dev Cumulative amount of `_paymentToken` that left this contract via `sweep`. Does not
    ///      count direct sponsor payouts from `buySubscription` (those bypass the contract
    ///      balance). Read alongside `IERC20(_paymentToken).balanceOf(this)` to monitor
    ///      collected-but-not-yet-swept revenue.
    uint256 internal _totalRevenueSwept;

    // --- KYC authorization ---

    /// @dev Backend signer trusted for EIP-712 KYC authorizations.
    address internal _kycSigner;
    /// @dev Per-user nonce consumed when a KYC authorization is accepted.
    mapping(address user => uint256 nonce) internal _kycNonces;

    // --- treasury ---

    /// @dev Wallet receiving subscription and pass revenue. Rotated exclusively through the
    ///      two-step flow in `TreasuryWalletTimelock`.
    address internal _treasuryWallet;

    // --- reserved ---

    uint256[42] private __gap;
}
