// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {AccessControlUpgradeable} from "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import {PausableUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {ReentrancyGuardTransient} from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {ISubscriptionManager} from "./ISubscriptionManager.sol";
import {ISubscriptionNFT} from "./ISubscriptionNFT.sol";
import {IPackagePassNFT} from "./IPackagePassNFT.sol";
import {SubscriptionManagerStorage} from "./storage/SubscriptionManagerStorage.sol";

error NotSubscribed(address user);
error SubscriptionAlreadyActive(address user);
error SubscriptionAlreadyExists(address user);
error InvalidSponsor(address sponsor);
error SponsorNotSubscribed(address sponsor);
error SelfSponsorNotAllowed();
/// @dev Raised when `buyPackagePass(tierId, partner)` is called for a user who already has a
///      subscription and `partner` neither equals the user's existing `_referrers[user]` nor is
///      `address(0)`. Prevents accidental UI overwrites of an immutable referrer binding.
error ReferrerMismatch(address user, address expected, address provided);
error InvalidTier(uint16 tierId);
error TierInactive(uint16 tierId);
error PassAlreadyExists(address user);
error PassDoesNotExist(address user);
error SamePassTier(uint16 tierId);
error DowngradeNotAllowed(uint256 oldPrice, uint256 newPrice);
error ZeroAddress();
error InvalidAmount();
error InvalidPrice();
error InvalidRateBps(uint256 rateBps);
error SubscriptionPriceNotSet();
error EarnCoreNotSet();
error InvalidAdmin(address admin);
error UnauthorizedUpgrade(address caller);
error InvalidBonusTier(uint16 bonusTierId);
error InvalidBonusThreshold();
error InvalidBonusReward();
error InvalidReferralBonusBps(uint256 bps);

/// @dev Minimal view + write surface of EarnCore used by SubscriptionManager.
interface IEarnCoreLike {
    function treasuryWallet() external view returns (address);
    function setSponsor(address user, address sponsor) external;
    function setSponsorRate(address sponsor, uint256 newRateBps) external;
}

/// @notice On-chain subscription and package-pass registry for the PAiT EARN product.
/// @dev Gates user entry points of EarnCore via `hasActiveSubscription`. Mints soulbound NFTs
///      representing the subscription and the package pass; forwards revenue to the treasury
///      configured on EarnCore; and records sponsor assignment / sponsor rate on EarnCore.
contract SubscriptionManager is
    Initializable,
    AccessControlUpgradeable,
    ReentrancyGuardTransient,
    PausableUpgradeable,
    UUPSUpgradeable,
    SubscriptionManagerStorage,
    ISubscriptionManager
{
    using SafeERC20 for IERC20;

    bytes32 public constant PARAMETER_MANAGER_ROLE = keccak256("PARAMETER_MANAGER_ROLE");
    bytes32 public constant PAUSER_ROLE = keccak256("PAUSER_ROLE");
    bytes32 public constant UPGRADER_ROLE = keccak256("UPGRADER_ROLE");
    /// @notice Role authorised to move collected revenue (USDC and any other ERC-20 residing on
    ///         this contract) off the contract. Expected to be a multisig / ops wallet. Does not
    ///         grant control over protocol parameters or upgrades.
    bytes32 public constant TREASURY_MANAGER_ROLE = keccak256("TREASURY_MANAGER_ROLE");

    uint64 public constant SUBSCRIPTION_DURATION = 365 days;
    /// @notice Duration of the subscription implicitly granted when a user buys a package pass.
    ///         Buying a pass is the only path (outside the admin genesis mint) that can create a
    ///         subscription without calling `buySubscription`, and it deliberately grants a very
    ///         long window so pass holders never need to re-subscribe during the pass lifetime.
    uint64 public constant PASS_SUBSCRIPTION_DURATION = 20 * 365 days;
    uint256 private constant MAX_SPONSOR_RATE_BPS = 10_000;

    event SubscriptionPurchased(
        address indexed user,
        address indexed sponsor,
        uint64 startedAt,
        uint64 expiresAt,
        uint256 pricePaid,
        bool isRenewal
    );
    /// @notice Emitted the first (and only) time a user's referrer is recorded in `_referrers`.
    /// @dev `referrer` is the requested partner regardless of whether they had a Pass seat —
    ///      the sub-sponsor (EarnCore rewards target) may still be `address(0)` if null-fallback
    ///      fired, but the referral-bonus chain still credits this referrer for future pass
    ///      / upgrade events. Emitted at most once per user (I-R1).
    event ReferrerRegistered(address indexed user, address indexed referrer);
    event PackagePassPurchased(
        address indexed user,
        uint16 indexed tierId,
        uint32 seats,
        uint256 pricePaid,
        uint256 sponsorRateBps
    );
    event PackagePassUpgraded(
        address indexed user,
        uint16 indexed oldTierId,
        uint16 indexed newTierId,
        uint32 newSeats,
        uint256 deltaPricePaid,
        uint256 newSponsorRateBps
    );
    event TierAdded(uint16 indexed tierId, uint256 price, uint32 seats, uint256 sponsorRateBps);
    event TierUpdated(uint16 indexed tierId, uint256 price, uint32 seats, uint256 sponsorRateBps, bool active);
    event TierRemoved(uint16 indexed tierId);
    event SubscriptionPriceUpdated(uint256 newPrice);
    /// @notice Emitted on first-time `buySubscription` once the subscription price has been
    ///         routed to the effective sponsor. Fires unconditionally — `sponsor == address(0)`
    ///         means the null-fallback path was hit and the USDC stays on this contract as
    ///         collected revenue awaiting `sweep` (see §7.1 / §8 I-9).
    event SubscriptionRevenueToSponsor(address indexed payer, address indexed sponsor, uint256 amount);
    /// @notice Emitted when collected revenue (the payment token or any other ERC-20 accidentally
    ///         residing on the contract) is moved off-contract via `sweep`.
    event RevenueSwept(address indexed caller, address indexed token, address indexed to, uint256 amount);
    event EarnCoreUpdated(address indexed newEarnCore);
    event SubscriptionNFTUpdated(address indexed newNFT);
    event PackagePassNFTUpdated(address indexed newNFT);
    event GenesisSubscriptionMinted(address indexed user, uint64 expiresAt);
    /// @notice Emitted on first-time `buySubscription` once the effective sponsor is resolved.
    /// @param user The buyer.
    /// @param requestedPartner The partner address passed into `buySubscription`.
    /// @param effectiveSponsor The address actually recorded in EarnCore. Equals `requestedPartner`
    ///        when a seat was consumed; `address(0)` when the partner had no seats (null fallback).
    /// @param partnerSeatsRemaining Seats left on the partner's pass after resolution (0 when fallback triggered).
    event SponsorResolved(
        address indexed user,
        address indexed requestedPartner,
        address indexed effectiveSponsor,
        uint32 partnerSeatsRemaining
    );

    // --- Subscription Sales Bonus events (see docs/Subscription Sales Bonus.md) ---

    /// @notice Emitted when an admin adds a new bonus tier.
    event BonusTierAdded(
        uint16 indexed bonusTierId, uint32 minReferrals, uint256 rewardAmount, uint16 sortOrder
    );
    /// @notice Emitted when an admin updates an existing bonus tier (threshold, reward, active
    ///         flag, or sort order). Per spec §5.4 updates apply to future evaluations only and
    ///         never mutate previously-awarded bonus records.
    event BonusTierUpdated(
        uint16 indexed bonusTierId,
        uint32 minReferrals,
        uint256 rewardAmount,
        bool active,
        uint16 sortOrder
    );
    /// @notice Emitted when an admin soft-removes (deactivates) a bonus tier.
    event BonusTierRemoved(uint16 indexed bonusTierId);
    /// @notice Emitted once per successful first-time subscription purchase that resolves to a
    ///         non-null effective sponsor. Each referred user can contribute only one qualified
    ///         referral to their referrer (spec §6 / §12).
    /// @param beneficiary    The Pass-holding sponsor receiving the referral credit.
    /// @param referredUser   The subscriber whose first qualifying purchase triggered this record.
    /// @param newCount       Beneficiary's updated lifetime qualified-referral count.
    event QualifiedReferralRecorded(
        address indexed beneficiary, address indexed referredUser, uint32 newCount
    );
    /// @notice Emitted when a bonus tier is awarded to a beneficiary and paid out in
    ///         `_paymentToken`. Fires once per (beneficiary, bonusTierId) pair for life. Multiple
    ///         awards can fire in a single transaction when several thresholds are crossed
    ///         simultaneously (cumulative-tier model — spec §7 / §12 / Scenario 7).
    /// @param beneficiary         The Pass-holding sponsor that received the payout.
    /// @param bonusTierId         Tier identifier that was awarded.
    /// @param amount              Cash reward paid in `_paymentToken` base units.
    /// @param triggeringReferralCount The beneficiary's referral count at the moment of award.
    event BonusAwarded(
        address indexed beneficiary,
        uint16 indexed bonusTierId,
        uint256 amount,
        uint32 triggeringReferralCount
    );

    // --- Referral Bonus (Pass Sales) events (see docs/Referral Bonus.md) ---

    /// @notice Emitted whenever an admin writes L1/L2 referral rates for a given Pass tier.
    ///         Per spec §5.4, updates apply to future eligible events only — historical bonus
    ///         awards remain untouched.
    event ReferralBonusConfigUpdated(
        uint16 indexed tierId, uint16 firstLineBps, uint16 secondLineBps, bool active
    );
    /// @notice Emitted once per (beneficiary, buyer, depth) payout on an eligible Pass purchase
    ///         or Pass upgrade. Depth is either 1 (direct parent) or 2 (grandparent). The
    ///         percentage applied is taken from the beneficiary's current Pass tier (spec §7
    ///         "Package matching rule"). `bonusBase` is the gross price for a purchase or the
    ///         positive delta for an upgrade (spec §6 "Upgrade calculation basis" / §7).
    /// @param beneficiary        Upstream user receiving the bonus payout.
    /// @param buyer              Address whose Pass purchase / upgrade triggered the event.
    /// @param beneficiaryTierId  Pass tier of the beneficiary at payout time (drives the rate).
    /// @param referralDepth      1 for L1 (direct parent), 2 for L2 (grandparent).
    /// @param percentageBps      Rate in basis points actually applied.
    /// @param bonusBase          Base amount the rate was applied to (gross or delta).
    /// @param amount             Payout amount in `_paymentToken` base units.
    /// @param isUpgrade          True when triggered by `upgradePackagePass`, false for fresh buy.
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

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    function initialize(
        address admin,
        address earnCore_,
        address subscriptionNFT_,
        address packagePassNFT_,
        address paymentToken_,
        uint256 initialPrice
    ) external initializer {
        if (admin == address(0)) {
            revert InvalidAdmin(admin);
        }
        if (
            earnCore_ == address(0) || subscriptionNFT_ == address(0) || packagePassNFT_ == address(0)
                || paymentToken_ == address(0)
        ) {
            revert ZeroAddress();
        }

        __AccessControl_init();
        __Pausable_init();

        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        _grantRole(PARAMETER_MANAGER_ROLE, admin);
        _grantRole(PAUSER_ROLE, admin);
        _grantRole(UPGRADER_ROLE, admin);
        _grantRole(TREASURY_MANAGER_ROLE, admin);

        _earnCore = earnCore_;
        _subscriptionNFT = subscriptionNFT_;
        _packagePassNFT = packagePassNFT_;
        _paymentToken = paymentToken_;
        _subscriptionPrice = initialPrice;
        _nextTierId = 0;
    }

    // ==============================================================
    // Views
    // ==============================================================

    /// @inheritdoc ISubscriptionManager
    function hasActiveSubscription(address user) public view returns (bool active) {
        return _subscriptions[user].expiresAt > block.timestamp;
    }

    function subscriptionOf(address user) external view returns (Subscription memory) {
        return _subscriptions[user];
    }

    function passOf(address user) external view returns (Pass memory) {
        return _passes[user];
    }

    /// @notice Returns the referrer recorded for `user` — i.e. the partner passed at first entry
    ///         (`buySubscription(partner)` or `buyPackagePass(tierId, partner)` with non-zero
    ///         partner). `address(0)` means either (a) user has never onboarded, or (b) user
    ///         opened a pass-first subscription with `partner == 0x0` (no referrer at all).
    ///         Decoupled from `subscriptionOf(user).sponsor` which tracks EarnCore sponsor-reward
    ///         target (null-fallback on no seats).
    function referrerOf(address user) external view returns (address) {
        return _referrers[user];
    }

    function tier(uint16 tierId) external view returns (Tier memory) {
        return _tiers[tierId];
    }

    function allActiveTierIds() external view returns (uint16[] memory ids) {
        uint16 count;
        uint16 next = _nextTierId;
        for (uint16 i = 1; i <= next; i++) {
            if (_tiers[i].active) count++;
        }
        ids = new uint16[](count);
        uint16 j;
        for (uint16 i = 1; i <= next; i++) {
            if (_tiers[i].active) {
                ids[j++] = i;
            }
        }
    }

    function subscriptionPrice() external view returns (uint256) {
        return _subscriptionPrice;
    }

    /// @notice Cumulative amount of `_paymentToken` moved off the contract via `sweep`. Does NOT
    ///         count direct sponsor payouts from `buySubscription` — those never touch the
    ///         contract balance.
    function totalRevenueSwept() external view returns (uint256) {
        return _totalRevenueSwept;
    }

    /// @notice Amount of `_paymentToken` currently sitting on the contract awaiting sweep. Useful
    ///         for ops dashboards; identical to `IERC20(paymentToken).balanceOf(address(this))`
    ///         for the protocol token.
    function pendingRevenue() external view returns (uint256) {
        return IERC20(_paymentToken).balanceOf(address(this));
    }

    function earnCore() external view returns (address) {
        return _earnCore;
    }

    function paymentToken() external view returns (address) {
        return _paymentToken;
    }

    function subscriptionNFT() external view returns (address) {
        return _subscriptionNFT;
    }

    function packagePassNFT() external view returns (address) {
        return _packagePassNFT;
    }

    // --- Subscription Sales Bonus views ---

    /// @notice Returns the stored bonus-tier configuration for `bonusTierId`. Inactive tiers are
    ///         still returned; check the `active` flag before treating it as live.
    function bonusTier(uint16 bonusTierId) external view returns (BonusTier memory) {
        return _bonusTiers[bonusTierId];
    }

    /// @notice Returns every currently active bonus tier id in ascending tier-id order.
    function activeBonusTierIds() external view returns (uint16[] memory ids) {
        uint16 count;
        uint16 next = _nextBonusTierId;
        for (uint16 i = 1; i <= next; i++) {
            if (_bonusTiers[i].active) count++;
        }
        ids = new uint16[](count);
        uint16 j;
        for (uint16 i = 1; i <= next; i++) {
            if (_bonusTiers[i].active) {
                ids[j++] = i;
            }
        }
    }

    /// @notice Lifetime count of qualified referrals credited to `beneficiary`. Monotonic.
    function qualifiedReferralCount(address beneficiary) external view returns (uint32) {
        return _qualifiedReferralCount[beneficiary];
    }

    /// @notice Whether `beneficiary` has already received the bonus for `bonusTierId`. True means
    ///         the tier cannot be awarded again to the same beneficiary (spec §5.2 / §12).
    function isBonusAwarded(address beneficiary, uint16 bonusTierId) external view returns (bool) {
        return _bonusAwarded[beneficiary][bonusTierId];
    }

    /// @notice Cumulative bonus amount (in `_paymentToken` units) paid to `beneficiary` across
    ///         all awarded tiers.
    function totalBonusAwardedTo(address beneficiary) external view returns (uint256) {
        return _totalBonusAwardedTo[beneficiary];
    }

    /// @notice Global cumulative bonus amount paid out by this contract since deployment.
    function totalBonusPaid() external view returns (uint256) {
        return _totalBonusPaid;
    }

    // --- Referral Bonus (Pass Sales) views ---

    /// @notice Returns the stored L1/L2 referral rate configuration for `tierId`. An entry with
    ///         `active == false` is ignored by the payout engine even if rates are non-zero.
    function referralBonusConfig(uint16 tierId) external view returns (ReferralBonusConfig memory) {
        return _referralBonusConfig[tierId];
    }

    /// @notice Lifetime referral-bonus totals paid to `beneficiary`, split by referral depth.
    /// @return firstLineTotal  Cumulative L1 payouts in `_paymentToken` units.
    /// @return secondLineTotal Cumulative L2 payouts in `_paymentToken` units.
    function referralBonusPaidTo(address beneficiary)
        external
        view
        returns (uint256 firstLineTotal, uint256 secondLineTotal)
    {
        firstLineTotal = _referralBonusFirstLinePaid[beneficiary];
        secondLineTotal = _referralBonusSecondLinePaid[beneficiary];
    }

    /// @notice Global cumulative referral-bonus payout across all beneficiaries since deploy.
    function totalReferralBonusPaid() external view returns (uint256) {
        return _totalReferralBonusPaid;
    }

    /// @notice Off-chain preview of the sponsor that `buySubscription(partner)` would record
    ///         for a first-time buyer at the current block.
    /// @dev Does not check whether `partner` has an active subscription; callers should gate on
    ///      `hasActiveSubscription(partner)` if needed. Returns `(partner, seats)` when the
    ///      partner still has inventory; `(address(0), 0)` when they don't (null fallback —
    ///      the subscription proceeds, but no sponsor rewards accrue to anyone).
    function quoteSponsor(address partner)
        external
        view
        returns (address effective, uint32 partnerSeatsRemaining)
    {
        Pass storage p = _passes[partner];
        if (p.tierId != 0 && p.seats > 0) {
            return (partner, p.seats);
        }
        return (address(0), 0);
    }

    // ==============================================================
    // User actions
    // ==============================================================

    /// @notice First-time purchase of a 365-day subscription. Reverts if the caller has ever
    ///         held a subscription before (use `renewSubscription` instead).
    /// @dev Resolves the effective sponsor via `_resolveSponsor`: when `partner` has available
    ///      seats on their Package Pass a seat is consumed and `partner` is recorded as sponsor;
    ///      otherwise the effective sponsor is `address(0)` (null fallback). The sponsor is
    ///      written once and mirrored to EarnCore. A single soulbound `SubscriptionNFT` is minted.
    ///
    ///      Revenue routing (subscription-only): the full `_subscriptionPrice` is transferred
    ///      directly to `effectiveSponsor` when non-zero. On null fallback the USDC stays on this
    ///      contract as un-accounted idle balance — no accumulator is kept and no sweep function
    ///      exists (deliberate "black hole" — see spec §7.1 / §8 I-9). Renewal and package-pass
    ///      flows continue to forward to treasury unchanged.
    /// @param partner The sponsor address to bind to. MUST be an address with an active
    ///        subscription (genesis or regular), not `msg.sender`, and not `address(0)`.
    function buySubscription(address partner) external nonReentrant whenNotPaused {
        if (_subscriptionPrice == 0) {
            revert SubscriptionPriceNotSet();
        }
        if (partner == address(0)) {
            revert InvalidSponsor(partner);
        }
        if (partner == msg.sender) {
            revert SelfSponsorNotAllowed();
        }

        Subscription storage existing = _subscriptions[msg.sender];
        if (existing.expiresAt != 0) {
            // Covers both still-active subs and expired ones waiting for renewal.
            revert SubscriptionAlreadyExists(msg.sender);
        }
        if (!hasActiveSubscription(partner)) {
            revert SponsorNotSubscribed(partner);
        }

        address effectiveSponsor = _resolveSponsor(msg.sender, partner);

        // Referral chain is decoupled from the sub-sponsor (null-fallback or not). The requested
        // `partner` is always recorded so future pass / upgrade events by msg.sender still credit
        // L1 / L2 referral bonuses even if `partner` had no seats at this moment. Write-once.
        _referrers[msg.sender] = partner;
        emit ReferrerRegistered(msg.sender, partner);

        uint64 nowTs = uint64(block.timestamp);
        uint64 newExpiresAt = nowTs + SUBSCRIPTION_DURATION;
        existing.startedAt = nowTs;
        existing.expiresAt = newExpiresAt;
        existing.sponsor = effectiveSponsor;

        _collectRevenue(msg.sender, _subscriptionPrice);

        ISubscriptionNFT(_subscriptionNFT).mint(msg.sender);
        IEarnCoreLike(_earnCore).setSponsor(msg.sender, effectiveSponsor);

        if (effectiveSponsor != address(0)) {
            // Direct-to-sponsor payout: full subscription price bypasses the contract balance.
            IERC20(_paymentToken).safeTransfer(effectiveSponsor, _subscriptionPrice);
        }
        // Else (null fallback): USDC remains on this contract as collected revenue, swept later
        // by `TREASURY_MANAGER_ROLE` via `sweep`.
        emit SubscriptionRevenueToSponsor(msg.sender, effectiveSponsor, _subscriptionPrice);

        emit SubscriptionPurchased(msg.sender, effectiveSponsor, nowTs, newExpiresAt, _subscriptionPrice, false);

        // Subscription Sales Bonus (spec §7 / §10): the first-time qualifying purchase by the
        // referred user (`msg.sender`) generates one lifetime qualified referral for the
        // effective sponsor and triggers cumulative tier evaluation. Null-fallback sponsors are
        // skipped — no one holds a Pass seat in that case, so no beneficiary is eligible.
        // `buySubscription` itself is one-shot per `msg.sender` (guarded by the
        // `SubscriptionAlreadyExists` check above), which provides the "count each referred user
        // only once per referrer" invariant (spec §6 / §8 Scenario 4 / §12).
        if (effectiveSponsor != address(0)) {
            _recordQualifiedReferral(effectiveSponsor, msg.sender);
        }
    }

    /// @notice Renews the caller's existing subscription for another 365 days. Only bumps
    ///         `expiresAt`; `startedAt`, `sponsor`, and the soulbound NFT are untouched.
    /// @dev Reverts if the caller never bought a subscription (`NotSubscribed`) or if their
    ///      subscription is still active (`SubscriptionAlreadyActive` — early renewal is not
    ///      permitted; users must wait for expiry). The sponsor resolver is NOT re-run: whatever
    ///      was written at first purchase (including `address(0)` null fallback) is preserved.
    function renewSubscription() external nonReentrant whenNotPaused {
        if (_subscriptionPrice == 0) {
            revert SubscriptionPriceNotSet();
        }
        Subscription storage existing = _subscriptions[msg.sender];
        if (existing.expiresAt == 0) {
            revert NotSubscribed(msg.sender);
        }
        if (hasActiveSubscription(msg.sender)) {
            revert SubscriptionAlreadyActive(msg.sender);
        }

        uint64 newExpiresAt = uint64(block.timestamp) + SUBSCRIPTION_DURATION;
        existing.expiresAt = newExpiresAt;

        // Renewal revenue stays on the contract as collected balance awaiting `sweep`.
        _collectRevenue(msg.sender, _subscriptionPrice);

        emit SubscriptionPurchased(
            msg.sender, existing.sponsor, existing.startedAt, newExpiresAt, _subscriptionPrice, true
        );
    }

    /// @dev Partner-inventory resolver. Called only on first-time purchases. Decrements both the
    ///      `_passes` mirror and the live `PackagePassNFT.seats` when the partner still has
    ///      inventory; otherwise returns `address(0)` (null fallback — EarnCore accepts a null
    ///      sponsor and no sponsor rewards accrue to anyone for such users).
    function _resolveSponsor(address user, address partner) internal returns (address effective) {
        Pass storage p = _passes[partner];
        if (p.tierId != 0 && p.seats > 0) {
            unchecked {
                // `seats` is bounded by the max tier absolute (uint32) at time of purchase/upgrade,
                // `consumedSeats` is bounded by the same absolute → neither can overflow here.
                p.seats = p.seats - 1;
                p.consumedSeats = p.consumedSeats + 1;
            }
            uint32 remaining = IPackagePassNFT(_packagePassNFT).decrementSeats(partner);
            emit SponsorResolved(user, partner, partner, remaining);
            return partner;
        }

        emit SponsorResolved(user, partner, address(0), 0);
        return address(0);
    }

    /// @notice Buys a package pass at the given tier. Does NOT require an active subscription —
    ///         the pass itself implicitly grants one (see below). Reverts if the buyer already
    ///         owns a pass.
    /// @dev Subscription bundling: every successful pass purchase grants the buyer a subscription
    ///      valid until `max(existing.expiresAt, block.timestamp + PASS_SUBSCRIPTION_DURATION)`.
    ///      - First-time subscriber (`expiresAt == 0`):
    ///          * If `partner != 0x0` — validated (self, active-sub) and fed through `_resolveSponsor`:
    ///            `subscription.sponsor` is the result (partner if seats, else `0x0` null-fallback);
    ///            `_referrers[buyer] = partner` regardless of seats (decoupled referral chain).
    ///          * If `partner == 0x0` — pass-first without referrer; both `subscription.sponsor`
    ///            and `_referrers[buyer]` stay `0x0` (no future L1/L2 bonuses for this buyer).
    ///          * `startedAt = now`, SubscriptionNFT minted, `EarnCore.setSponsor` called.
    ///      - Existing subscriber (active or expired): `startedAt`, `sponsor`, and `_referrers`
    ///        are preserved per I-2 / I-2a / I-R1. `partner` MUST be either `address(0)` or equal
    ///        to the already-recorded `_referrers[buyer]`; otherwise revert `ReferrerMismatch` to
    ///        prevent accidental UI overwrites. Only `expiresAt` may extend. If the existing
    ///        record already points further into the future (e.g. admin genesis at `uint64.max`)
    ///        nothing changes and no `SubscriptionPurchased` event is emitted.
    /// @param tierId Tier to purchase.
    /// @param partner Requested referrer. For first-time buyers: binds both the sub-sponsor (via
    ///        resolver) and the referral-chain entry. For existing subscribers: must match the
    ///        stored `_referrers[buyer]` or be `address(0)` (acts as a no-op assertion).
    function buyPackagePass(uint16 tierId, address partner) external nonReentrant whenNotPaused {
        Tier storage t = _tiers[tierId];
        if (tierId == 0 || tierId > _nextTierId || t.price == 0) {
            revert InvalidTier(tierId);
        }
        if (!t.active) {
            revert TierInactive(tierId);
        }
        if (_passes[msg.sender].tierId != 0) {
            revert PassAlreadyExists(msg.sender);
        }

        uint256 price = t.price;
        uint32 seats = t.seats;
        uint256 rateBps = t.sponsorRateBps;

        _passes[msg.sender] = Pass({
            tierId: tierId,
            seats: seats,
            consumedSeats: 0,
            purchasedAt: uint64(block.timestamp)
        });

        _bindReferrerForPass(msg.sender, partner);
        _grantPassSubscription(msg.sender);

        // Pass revenue stays on the contract as collected balance awaiting `sweep`.
        _collectRevenue(msg.sender, price);

        IPackagePassNFT(_packagePassNFT).mint(msg.sender, tierId, seats);
        IEarnCoreLike(_earnCore).setSponsorRate(msg.sender, rateBps);

        emit PackagePassPurchased(msg.sender, tierId, seats, price, rateBps);

        // Referral Bonus (Pass Sales) — docs/Referral Bonus.md §7. For a fresh Pass purchase the
        // bonus base is the gross paid price. Upstream L1/L2 beneficiaries are resolved from the
        // buyer's subscription sponsor chain and paid according to THEIR current Pass tier's
        // active rates. Silently no-ops when no valid upstream exists or rules are inactive —
        // which includes the common case where the buyer is a first-time subscriber via this
        // very pass purchase (their own sponsor is `address(0)`).
        _payReferralBonuses(msg.sender, price, false);
    }

    /// @dev Pass-bound referrer / sub-sponsor binding. Called BEFORE `_grantPassSubscription` so
    ///      that the subscription's `sponsor` field and `_referrers` are populated before the
    ///      `SubscriptionPurchased` event is emitted on first-time mint.
    ///      Semantics:
    ///       - First-time buyer (`_subscriptions[user].expiresAt == 0`):
    ///           * `partner == 0x0` → pass-first without a referrer: `sponsor = 0x0`,
    ///             `_referrers[user] = 0x0` (no ReferrerRegistered event), no `setSponsor` call.
    ///           * `partner != 0x0` → runs full validation (self-ref / `hasActiveSubscription`)
    ///             and `_resolveSponsor`; `sponsor` gets the resolved value (partner or `0x0` on
    ///             null-fallback), `_referrers[user] = partner` regardless (decoupled chains),
    ///             `EarnCore.setSponsor` is mirrored.
    ///       - Existing buyer: `partner` MUST be `0x0` or equal to the stored `_referrers[user]`.
    ///         Otherwise revert `ReferrerMismatch` — prevents UI bugs from silently attempting to
    ///         rewrite an immutable referrer. No state changes on this path.
    function _bindReferrerForPass(address user, address partner) internal {
        Subscription storage existing = _subscriptions[user];
        bool firstTime = existing.expiresAt == 0;

        if (!firstTime) {
            address currentReferrer = _referrers[user];
            if (partner != address(0) && partner != currentReferrer) {
                revert ReferrerMismatch(user, currentReferrer, partner);
            }
            return;
        }

        if (partner == address(0)) {
            // Pass-first without referrer: sponsor / referrer both stay 0x0.
            return;
        }
        if (partner == user) {
            revert SelfSponsorNotAllowed();
        }
        if (!hasActiveSubscription(partner)) {
            revert SponsorNotSubscribed(partner);
        }

        address effectiveSponsor = _resolveSponsor(user, partner);

        _referrers[user] = partner;
        emit ReferrerRegistered(user, partner);

        existing.sponsor = effectiveSponsor;
        IEarnCoreLike(_earnCore).setSponsor(user, effectiveSponsor);
    }

    /// @dev Grants or extends the caller's subscription as part of a pass purchase. Only bumps
    ///      `expiresAt` forward — genesis / long-lived subscriptions are never shortened. First-
    ///      time subscribers additionally get `startedAt` stamped and the soulbound NFT minted.
    ///      Assumes `_bindReferrerForPass` has already written `sponsor` (via resolver) — this
    ///      helper only handles the temporal fields and the NFT mint.
    function _grantPassSubscription(address user) internal {
        Subscription storage existing = _subscriptions[user];
        uint64 nowTs = uint64(block.timestamp);
        uint64 target = nowTs + PASS_SUBSCRIPTION_DURATION;

        if (target <= existing.expiresAt) {
            // Existing subscription already extends past the target window (e.g. admin genesis at
            // type(uint64).max, or a prior pass within the last second). No-op — no event either.
            return;
        }

        bool firstTime = existing.expiresAt == 0;
        existing.expiresAt = target;
        if (firstTime) {
            existing.startedAt = nowTs;
            ISubscriptionNFT(_subscriptionNFT).mint(user);
        }

        emit SubscriptionPurchased(user, existing.sponsor, existing.startedAt, target, 0, !firstTime);
    }

    /// @notice Upgrades the caller's package pass to a more expensive tier. Pays delta-price.
    function upgradePackagePass(uint16 newTierId) external nonReentrant whenNotPaused {
        if (!hasActiveSubscription(msg.sender)) {
            revert NotSubscribed(msg.sender);
        }
        Pass storage existing = _passes[msg.sender];
        if (existing.tierId == 0) {
            revert PassDoesNotExist(msg.sender);
        }
        if (newTierId == existing.tierId) {
            revert SamePassTier(newTierId);
        }
        Tier storage newTier = _tiers[newTierId];
        if (newTierId == 0 || newTierId > _nextTierId || newTier.price == 0) {
            revert InvalidTier(newTierId);
        }
        if (!newTier.active) {
            revert TierInactive(newTierId);
        }

        Tier storage oldTier = _tiers[existing.tierId];
        uint256 oldPrice = oldTier.price;
        uint256 newPrice = newTier.price;
        if (newPrice <= oldPrice) {
            revert DowngradeNotAllowed(oldPrice, newPrice);
        }

        // Absolute seat allowance granted at the owner's current tier is reconstructed from the
        // Pass itself, NOT from current tier storage (spec §7.3 + audit finding M-1): the Tier
        // row may have been edited by the admin after purchase, so reading `oldTier.seats` would
        // leak retroactive state into the owner's upgrade math. The invariant
        // `seats + consumedSeats == absolute granted at last buy/upgrade` guarantees that this
        // reconstruction is exact and immune to admin-side mutation.
        uint32 consumed = existing.consumedSeats;
        uint32 oldAbsoluteSeats = existing.seats + consumed;
        uint32 newAbsoluteSeats = newTier.seats;
        if (newAbsoluteSeats < oldAbsoluteSeats) {
            revert DowngradeNotAllowed(oldPrice, newPrice);
        }

        uint256 delta = newPrice - oldPrice;
        // Remaining seats after upgrade = new tier's absolute minus what was already consumed.
        // `newAbsoluteSeats >= oldAbsoluteSeats >= consumed` ⇒ subtraction cannot underflow.
        uint32 newSeats;
        unchecked {
            newSeats = newAbsoluteSeats - consumed;
        }
        uint16 oldTierId = existing.tierId;
        existing.tierId = newTierId;
        existing.seats = newSeats;

        // Upgrade delta stays on the contract as collected balance awaiting `sweep`.
        _collectRevenue(msg.sender, delta);

        IPackagePassNFT(_packagePassNFT).setTier(msg.sender, newTierId, newSeats);
        IEarnCoreLike(_earnCore).setSponsorRate(msg.sender, newTier.sponsorRateBps);

        emit PackagePassUpgraded(msg.sender, oldTierId, newTierId, newSeats, delta, newTier.sponsorRateBps);

        // Referral Bonus (Pass Sales) — docs/Referral Bonus.md §6 "Upgrade calculation basis" /
        // §7 / Scenario 4. For an upgrade the bonus base is the positive price delta only, NOT
        // the new tier's full price. Each eligible upstream beneficiary is paid according to
        // their own active Pass-tier rate at the time of this upgrade event (spec §7
        // "Downstream upgrade effect"). Previous awards on the original purchase remain final
        // (spec §5.4).
        _payReferralBonuses(msg.sender, delta, true);
    }

    // ==============================================================
    // Admin: tiers and pricing
    // ==============================================================

    function setSubscriptionPrice(uint256 newPrice) external onlyRole(PARAMETER_MANAGER_ROLE) {
        _subscriptionPrice = newPrice;
        emit SubscriptionPriceUpdated(newPrice);
    }

    /// @param seats Absolute number of seats granted to a buyer of this tier. For upgrades the
    ///        owner's remaining seat count is recomputed as `seats - pass.consumedSeats`, so
    ///        admins must treat this field as "total seats a freshly-minted holder of this tier
    ///        has", not an incremental delta over some other tier.
    function addTier(uint256 price, uint32 seats, uint256 sponsorRateBps, string calldata metadataURI)
        external
        onlyRole(PARAMETER_MANAGER_ROLE)
        returns (uint16 tierId)
    {
        if (price == 0) revert InvalidPrice();
        if (sponsorRateBps > MAX_SPONSOR_RATE_BPS) revert InvalidRateBps(sponsorRateBps);

        _nextTierId += 1;
        tierId = _nextTierId;
        _tiers[tierId] = Tier({
            price: price,
            seats: seats,
            sponsorRateBps: sponsorRateBps,
            active: true,
            metadataURI: metadataURI
        });
        emit TierAdded(tierId, price, seats, sponsorRateBps);
    }

    /// @dev Editing `seats` here affects NEW buyers of this tier only. Holders already on this
    ///      tier keep the `seats + consumedSeats` they were granted at purchase/upgrade time; the
    ///      upgrade path reads that snapshot off the Pass, never off this storage row.
    function setTier(
        uint16 tierId,
        uint256 price,
        uint32 seats,
        uint256 sponsorRateBps,
        bool active,
        string calldata metadataURI
    ) external onlyRole(PARAMETER_MANAGER_ROLE) {
        if (tierId == 0 || tierId > _nextTierId || _tiers[tierId].price == 0) {
            revert InvalidTier(tierId);
        }
        if (price == 0) revert InvalidPrice();
        if (sponsorRateBps > MAX_SPONSOR_RATE_BPS) revert InvalidRateBps(sponsorRateBps);

        Tier storage t = _tiers[tierId];
        t.price = price;
        t.seats = seats;
        t.sponsorRateBps = sponsorRateBps;
        t.active = active;
        t.metadataURI = metadataURI;
        emit TierUpdated(tierId, price, seats, sponsorRateBps, active);
    }

    function removeTier(uint16 tierId) external onlyRole(PARAMETER_MANAGER_ROLE) {
        if (tierId == 0 || tierId > _nextTierId || _tiers[tierId].price == 0) {
            revert InvalidTier(tierId);
        }
        _tiers[tierId].active = false;
        emit TierRemoved(tierId);
    }

    // ==============================================================
    // Admin: subscription sales bonus tiers
    // ==============================================================

    /// @notice Creates a new bonus tier. Returns the assigned tier id.
    /// @dev Thresholds and reward amounts must be strictly positive (spec §5.5). Per spec §5.4
    ///      the new tier applies to future evaluations only. Historical awards are never rewritten.
    /// @param minReferrals Minimum qualified-referral count required to reach this tier.
    /// @param rewardAmount Cash reward in `_paymentToken` base units awarded once per beneficiary.
    /// @param sortOrder    Informational display/order hint (evaluation uses tier id order).
    function addBonusTier(uint32 minReferrals, uint256 rewardAmount, uint16 sortOrder)
        external
        onlyRole(PARAMETER_MANAGER_ROLE)
        returns (uint16 bonusTierId)
    {
        if (minReferrals == 0) revert InvalidBonusThreshold();
        if (rewardAmount == 0) revert InvalidBonusReward();

        _nextBonusTierId += 1;
        bonusTierId = _nextBonusTierId;
        _bonusTiers[bonusTierId] = BonusTier({
            minReferrals: minReferrals,
            rewardAmount: rewardAmount,
            active: true,
            sortOrder: sortOrder
        });
        emit BonusTierAdded(bonusTierId, minReferrals, rewardAmount, sortOrder);
    }

    /// @notice Updates threshold / reward / active flag / sort order of an existing bonus tier.
    /// @dev Applies to future bonus evaluations only (spec §5.4). Previously awarded bonus
    ///      records for this tier remain untouched and the `_bonusAwarded` one-shot flag is
    ///      preserved: a beneficiary who already received this tier will not receive it again
    ///      even if the threshold is later lowered or the tier is reactivated.
    function setBonusTier(
        uint16 bonusTierId,
        uint32 minReferrals,
        uint256 rewardAmount,
        uint16 sortOrder,
        bool active
    ) external onlyRole(PARAMETER_MANAGER_ROLE) {
        if (bonusTierId == 0 || bonusTierId > _nextBonusTierId || _bonusTiers[bonusTierId].minReferrals == 0) {
            revert InvalidBonusTier(bonusTierId);
        }
        if (minReferrals == 0) revert InvalidBonusThreshold();
        if (rewardAmount == 0) revert InvalidBonusReward();

        BonusTier storage t = _bonusTiers[bonusTierId];
        t.minReferrals = minReferrals;
        t.rewardAmount = rewardAmount;
        t.sortOrder = sortOrder;
        t.active = active;
        emit BonusTierUpdated(bonusTierId, minReferrals, rewardAmount, active, sortOrder);
    }

    /// @notice Soft-deactivates a bonus tier so it stops participating in future evaluations.
    /// @dev Does not wipe historical awards. The tier id remains reserved; reactivation is done
    ///      via `setBonusTier(..., active: true)`.
    function removeBonusTier(uint16 bonusTierId) external onlyRole(PARAMETER_MANAGER_ROLE) {
        if (bonusTierId == 0 || bonusTierId > _nextBonusTierId || _bonusTiers[bonusTierId].minReferrals == 0) {
            revert InvalidBonusTier(bonusTierId);
        }
        _bonusTiers[bonusTierId].active = false;
        emit BonusTierRemoved(bonusTierId);
    }

    // ==============================================================
    // Admin: referral bonus (Pass Sales) configuration
    // ==============================================================

    /// @notice Writes (or overwrites) the L1/L2 referral rates and active flag for a Pass tier.
    ///         See docs/Referral Bonus.md §5.3.
    /// @dev The tier must already exist in `_tiers`. Both rates are capped at 10_000 bps
    ///      (= 100%) individually (spec §5.5). Cross-tier sum validation is left to operators:
    ///      L1 and L2 rates resolve to different beneficiaries, each potentially on different
    ///      tiers, so the effective total payout per event depends on the upstream chain
    ///      composition at event time.
    /// @dev Per spec §5.4 this change applies to future bonus events only; previously-emitted
    ///      `ReferralBonusPaid` records and token movements are final.
    function setReferralBonusConfig(uint16 tierId, uint16 firstLineBps, uint16 secondLineBps, bool active)
        external
        onlyRole(PARAMETER_MANAGER_ROLE)
    {
        if (tierId == 0 || tierId > _nextTierId || _tiers[tierId].price == 0) {
            revert InvalidTier(tierId);
        }
        if (firstLineBps > MAX_SPONSOR_RATE_BPS) revert InvalidReferralBonusBps(firstLineBps);
        if (secondLineBps > MAX_SPONSOR_RATE_BPS) revert InvalidReferralBonusBps(secondLineBps);

        _referralBonusConfig[tierId] = ReferralBonusConfig({
            firstLineBps: firstLineBps,
            secondLineBps: secondLineBps,
            active: active
        });
        emit ReferralBonusConfigUpdated(tierId, firstLineBps, secondLineBps, active);
    }

    // ==============================================================
    // Admin: wiring
    // ==============================================================

    function setSubscriptionNFT(address nft) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (nft == address(0)) revert ZeroAddress();
        _subscriptionNFT = nft;
        emit SubscriptionNFTUpdated(nft);
    }

    function setPassNFT(address nft) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (nft == address(0)) revert ZeroAddress();
        _packagePassNFT = nft;
        emit PackagePassNFTUpdated(nft);
    }

    function setEarnCore(address earn) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (earn == address(0)) revert ZeroAddress();
        _earnCore = earn;
        emit EarnCoreUpdated(earn);
    }

    function pause() external onlyRole(PAUSER_ROLE) {
        _pause();
    }

    function unpause() external onlyRole(PAUSER_ROLE) {
        _unpause();
    }

    // ==============================================================
    // Treasury: sweep
    // ==============================================================

    /// @notice Moves `amount` of `token` from this contract to `to`. Used by the treasury role to
    ///         collect revenue accrued on the contract from `renewSubscription`, `buyPackagePass`,
    ///         `upgradePackagePass` and null-fallback `buySubscription` flows.
    /// @dev Works for any ERC-20: the contract is not supposed to hold non-payment tokens, so this
    ///      doubles as a rescue path for accidental transfers. Only `_paymentToken` sweeps are
    ///      reflected in the `totalRevenueSwept` audit counter; other tokens are not tracked
    ///      because they were never protocol revenue.
    /// @dev CEI: effects (counter bump) before the external call. The external call is a plain
    ///      ERC-20 transfer which is trusted for USDC; for rescued tokens the `nonReentrant` guard
    ///      plus transient storage reentrancy lock still holds the invariant.
    function sweep(address token, address to, uint256 amount) external nonReentrant onlyRole(TREASURY_MANAGER_ROLE) {
        if (token == address(0) || to == address(0)) revert ZeroAddress();
        if (amount == 0) revert InvalidAmount();

        if (token == _paymentToken) {
            _totalRevenueSwept += amount;
        }

        IERC20(token).safeTransfer(to, amount);
        emit RevenueSwept(msg.sender, token, to, amount);
    }

    /// @notice Admin mints a genesis subscription (no sponsor) for bootstrap purposes.
    /// @dev Used for the very first user of the system (typically the admin) so subsequent
    ///      users can reference them as sponsor. Reverts if already active.
    /// @dev Per spec §9.8 the genesis subscription is granted with `expiresAt = type(uint64).max`
    ///      so the sponsor graph always has a reachable root even years after deploy.
    function adminMintGenesisSubscription(address user) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (user == address(0)) revert ZeroAddress();
        if (hasActiveSubscription(user)) revert SubscriptionAlreadyActive(user);

        uint64 startedAt = uint64(block.timestamp);
        uint64 expiresAt = type(uint64).max;
        Subscription storage s = _subscriptions[user];
        bool firstTime = s.expiresAt == 0;
        s.startedAt = startedAt;
        s.expiresAt = expiresAt;

        if (firstTime) {
            ISubscriptionNFT(_subscriptionNFT).mint(user);
        }
        emit GenesisSubscriptionMinted(user, expiresAt);
    }

    // ==============================================================
    // Internals
    // ==============================================================

    function _collectRevenue(address payer, uint256 amount) internal {
        if (amount == 0) return;
        IERC20(_paymentToken).safeTransferFrom(payer, address(this), amount);
    }

    /// @dev Credits one qualified referral to `beneficiary` and evaluates cumulative bonus tiers.
    ///      Caller must have already verified `beneficiary != address(0)` and that the referred
    ///      user's qualifying purchase is final.
    function _recordQualifiedReferral(address beneficiary, address referredUser) internal {
        uint32 newCount;
        unchecked {
            // Bounded by block gas / real-world referral volume; uint32 is far beyond any
            // plausible lifetime count for a single beneficiary.
            newCount = _qualifiedReferralCount[beneficiary] + 1;
        }
        _qualifiedReferralCount[beneficiary] = newCount;
        emit QualifiedReferralRecorded(beneficiary, referredUser, newCount);

        _evaluateBonusTiers(beneficiary, newCount);
    }

    /// @dev Referral Bonus (Pass Sales) payout entry. Resolves the upstream chain at call time
    ///      and pays the direct parent (L1) and grandparent (L2) whatever their current tier's
    ///      active rate prescribes. Bonus payouts are sourced from this contract's balance:
    ///      `buyPackagePass` / `upgradePackagePass` have already collected the full sale amount
    ///      via `_collectRevenue` before invoking this helper, so in the common case the payout
    ///      comes straight out of the freshly-collected revenue.
    ///
    ///      Per spec §6 / §7:
    ///       - The rate is looked up on the BENEFICIARY's Pass tier, not the buyer's.
    ///       - Beneficiaries must own a Pass themselves (no Pass ⇒ skipped).
    ///       - Inactive rules, zero rates, and zero payouts are skipped silently.
    ///       - L2 == buyer guard prevents circular self-reward (defensive — the existing
    ///         `SelfSponsorNotAllowed` invariant on `buySubscription` already makes 2-cycles
    ///         impossible, but a defense-in-depth check is cheap).
    ///       - Duplicate prevention is structural: `buyPackagePass` is one-shot per user and
    ///         `upgradePackagePass` only pays the positive delta into a new tier, so the same
    ///         (beneficiary, buyer, depth) cannot be credited twice within the same business
    ///         event (spec §12 / Scenario 5).
    function _payReferralBonuses(address buyer, uint256 bonusBase, bool isUpgrade) internal {
        if (bonusBase == 0) return;

        // Referral chain reads from the dedicated `_referrers` mapping (decoupled from
        // `subscription.sponsor`): L1 remains credited for future pass / upgrade events even
        // when the sub-sponsor fell back to `0x0` because they had no seats at signup time
        // (spec §7.2 / §7.5 pass-first & null-fallback semantics).
        address l1 = _referrers[buyer];
        if (l1 == address(0) || l1 == buyer) return;

        _payReferralBonusTo(l1, buyer, bonusBase, 1, isUpgrade);

        address l2 = _referrers[l1];
        if (l2 == address(0) || l2 == buyer || l2 == l1) return;

        _payReferralBonusTo(l2, buyer, bonusBase, 2, isUpgrade);
    }

    /// @dev Pays a single L1 or L2 referral bonus slice for one upstream beneficiary.
    ///      Reads the rate off the beneficiary's current Pass tier (spec §7 "Package matching
    ///      rule"). Silently no-ops when any eligibility gate fails so that a misconfigured /
    ///      inactive tier on one leg does not block the buyer's Pass purchase.
    function _payReferralBonusTo(
        address beneficiary,
        address buyer,
        uint256 bonusBase,
        uint8 depth,
        bool isUpgrade
    ) internal {
        uint16 beneficiaryTierId = _passes[beneficiary].tierId;
        if (beneficiaryTierId == 0) return; // beneficiary must own a Pass (spec §6).

        ReferralBonusConfig storage cfg = _referralBonusConfig[beneficiaryTierId];
        if (!cfg.active) return; // spec §5.5 "Inactive package rules must not be used".

        uint16 bps = depth == 1 ? cfg.firstLineBps : cfg.secondLineBps;
        if (bps == 0) return;

        // bps <= 10_000 is enforced at write-time, so the multiplication is bounded by
        // `bonusBase * 10_000`; overflow would require bonusBase > 2^256 / 10_000, not feasible.
        uint256 amount = (bonusBase * bps) / 10_000;
        if (amount == 0) return;

        // Effects before the external transfer (CEI). If the transfer reverts (e.g. contract
        // balance insufficient) the whole Pass purchase / upgrade is rolled back, so bookkeeping
        // can never drift from actual token movement.
        if (depth == 1) {
            _referralBonusFirstLinePaid[beneficiary] += amount;
        } else {
            _referralBonusSecondLinePaid[beneficiary] += amount;
        }
        _totalReferralBonusPaid += amount;

        IERC20(_paymentToken).safeTransfer(beneficiary, amount);
        emit ReferralBonusPaid(
            beneficiary, buyer, beneficiaryTierId, depth, bps, bonusBase, amount, isUpgrade
        );
    }

    /// @dev Cumulative-tier evaluator (spec §7 / Scenario 6-7). Walks every configured bonus
    ///      tier in ascending tier-id order and awards any active tier whose threshold is met
    ///      and which has not yet been awarded to `beneficiary`. Multiple tiers may be awarded
    ///      in a single call when the count crosses several thresholds simultaneously (e.g.
    ///      retroactively added tiers, or concurrent counter evaluations). Each payout is
    ///      performed immediately from this contract's `_paymentToken` balance; the caller is
    ///      already protected by `nonReentrant` on the user entry point.
    function _evaluateBonusTiers(address beneficiary, uint32 count) internal {
        uint16 next = _nextBonusTierId;
        for (uint16 i = 1; i <= next; i++) {
            BonusTier storage t = _bonusTiers[i];
            if (!t.active) continue;
            if (t.minReferrals == 0) continue; // defensive — `addBonusTier` forbids zero.
            if (count < t.minReferrals) continue;
            if (_bonusAwarded[beneficiary][i]) continue;

            uint256 amount = t.rewardAmount;

            // Effects before the external transfer (CEI). The one-shot flag + totals mutation
            // happen regardless of whether the transfer succeeds; if it reverts, the whole
            // transaction (including the triggering subscription purchase) is rolled back, so
            // the flag is never flipped without a matching payout.
            _bonusAwarded[beneficiary][i] = true;
            _totalBonusAwardedTo[beneficiary] += amount;
            _totalBonusPaid += amount;

            IERC20(_paymentToken).safeTransfer(beneficiary, amount);
            emit BonusAwarded(beneficiary, i, amount, count);
        }
    }

    function _authorizeUpgrade(address) internal view override {
        if (!hasRole(UPGRADER_ROLE, msg.sender)) {
            revert UnauthorizedUpgrade(msg.sender);
        }
    }
}
