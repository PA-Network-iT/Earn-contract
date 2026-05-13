// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {AccessControlUpgradeable} from "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import {PausableUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";
import {EIP712Upgradeable} from "@openzeppelin/contracts-upgradeable/utils/cryptography/EIP712Upgradeable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {ReentrancyGuardTransient} from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";

import {
    KycAuthorization,
    InvalidKycAuthorization,
    KycAuthorizationExpired,
    InvalidKycSigner
} from "src/lib/KycAuthorization.sol";
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
error InvalidTier(uint16 tierId);
error TierInactive(uint16 tierId);
error PassAlreadyExists(address user);
error PassDoesNotExist(address user);
error SamePassTier(uint16 tierId);
error DowngradeNotAllowed(uint256 oldPrice, uint256 newPrice);
error ZeroAddress();
error InvalidAmount();
error InvalidPrice();
error SubscriptionPriceNotSet();
error EarnCoreNotSet();
error InvalidAdmin(address admin);
error UnauthorizedUpgrade(address caller);

/// @notice On-chain subscription and package-pass registry for the PAiT EARN product.
/// @dev Gates user entry points of EarnCore via `hasActiveSubscription`. Mints soulbound NFTs
///      representing the subscription and the package pass; forwards revenue to the treasury
///      configured on EarnCore.
contract SubscriptionManager is
    Initializable,
    AccessControlUpgradeable,
    ReentrancyGuardTransient,
    PausableUpgradeable,
    UUPSUpgradeable,
    EIP712Upgradeable,
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
    event SubscriptionPurchased(
        address indexed user,
        address indexed sponsor,
        uint64 startedAt,
        uint64 expiresAt,
        uint256 pricePaid,
        bool isRenewal
    );
    event PackagePassPurchased(address indexed user, uint16 indexed tierId, uint32 seats, uint256 pricePaid);
    event PackagePassGranted(address indexed user, uint16 indexed tierId, uint32 seats);
    event PackagePassUpgraded(
        address indexed user,
        uint16 indexed oldTierId,
        uint16 indexed newTierId,
        uint32 newSeats,
        uint256 deltaPricePaid
    );
    event TierAdded(uint16 indexed tierId, uint256 price, uint32 seats);
    event TierUpdated(uint16 indexed tierId, uint256 price, uint32 seats, bool active);
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
    event KycSignerUpdated(address indexed signer);
    event KycAuthorizationConsumed(address indexed user, uint8 indexed scope, uint256 nonce, uint64 expiresAt);
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
        __EIP712_init("PAiT Subscription KYC", "1");

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

    function kycSigner() external view returns (address signer) {
        return _kycSigner;
    }

    function kycNonce(address user) external view returns (uint256 nonce) {
        return _kycNonces[user];
    }

    /// @notice Off-chain preview of the sponsor that `buySubscription(partner)` would record
    ///         for a first-time buyer at the current block.
    /// @dev Does not check whether `partner` has an active subscription; callers should gate on
    ///      `hasActiveSubscription(partner)` if needed. Returns `(partner, seats)` when the
    ///      partner still has inventory; `(address(0), 0)` when they don't (null fallback —
    ///      the subscription proceeds, but no sponsor rewards accrue to anyone).
    function quoteSponsor(address partner) external view returns (address effective, uint32 partnerSeatsRemaining) {
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
    ///      written once in SubscriptionManager. A single soulbound `SubscriptionNFT` is minted.
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

        uint64 nowTs = uint64(block.timestamp);
        uint64 newExpiresAt = nowTs + SUBSCRIPTION_DURATION;
        existing.startedAt = nowTs;
        existing.expiresAt = newExpiresAt;
        existing.sponsor = effectiveSponsor;

        _collectRevenue(msg.sender, _subscriptionPrice);

        ISubscriptionNFT(_subscriptionNFT).mint(msg.sender);
        if (effectiveSponsor != address(0)) {
            // Direct-to-sponsor payout: full subscription price bypasses the contract balance.
            IERC20(_paymentToken).safeTransfer(effectiveSponsor, _subscriptionPrice);
        }
        // Else (null fallback): USDC remains on this contract as collected revenue, swept later
        // by `TREASURY_MANAGER_ROLE` via `sweep`.
        emit SubscriptionRevenueToSponsor(msg.sender, effectiveSponsor, _subscriptionPrice);

        emit SubscriptionPurchased(msg.sender, effectiveSponsor, nowTs, newExpiresAt, _subscriptionPrice, false);
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
    ///      - First-time subscriber (`expiresAt == 0`): optional non-zero `partner` is validated
    ///        and fed through `_resolveSponsor`; `subscription.sponsor` becomes the result.
    ///      - Existing subscriber (active or expired): `startedAt` and `sponsor` are preserved.
    ///        Only `expiresAt` may extend. If the existing record already points further into the
    ///        future (e.g. admin genesis at `uint64.max`) nothing changes and no
    ///        `SubscriptionPurchased` event is emitted.
    /// @param tierId Tier to purchase.
    /// @param partner Optional sponsor candidate for first-time buyers.
    /// @param kycAuthorization ABI-encoded `(uint64 expiresAt, uint256 nonce, bytes signature)`.
    function buyPackagePass(uint16 tierId, address partner, bytes calldata kycAuthorization)
        external
        nonReentrant
        whenNotPaused
    {
        _buyPackagePass(tierId, partner, kycAuthorization);
    }

    function _buyPackagePass(uint16 tierId, address partner, bytes memory kycAuthorization) internal {
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

        _consumeKycAuthorization(msg.sender, KycAuthorization.SCOPE_PACKAGE_PASS, kycAuthorization);

        uint256 price = t.price;
        uint32 seats = t.seats;

        _passes[msg.sender] =
            Pass({tierId: tierId, seats: seats, consumedSeats: 0, purchasedAt: uint64(block.timestamp)});

        _bindSponsorForPass(msg.sender, partner);
        _grantPassSubscription(msg.sender);

        // Pass revenue stays on the contract as collected balance awaiting `sweep`.
        _collectRevenue(msg.sender, price);

        IPackagePassNFT(_packagePassNFT).mint(msg.sender, tierId, seats);

        emit PackagePassPurchased(msg.sender, tierId, seats, price);
    }

    /// @dev Pass-bound sponsor binding. Called BEFORE `_grantPassSubscription` so
    ///      that the subscription's `sponsor` field is populated before the
    ///      `SubscriptionPurchased` event is emitted on first-time mint.
    function _bindSponsorForPass(address user, address partner) internal {
        Subscription storage existing = _subscriptions[user];
        bool firstTime = existing.expiresAt == 0;

        if (!firstTime) {
            return;
        }

        if (partner == address(0)) {
            return;
        }
        if (partner == user) {
            revert SelfSponsorNotAllowed();
        }
        if (!hasActiveSubscription(partner)) {
            revert SponsorNotSubscribed(partner);
        }

        address effectiveSponsor = _resolveSponsor(user, partner);

        existing.sponsor = effectiveSponsor;
    }

    /// @dev Grants or extends the caller's subscription as part of a pass purchase. Only bumps
    ///      `expiresAt` forward — genesis / long-lived subscriptions are never shortened. First-
    ///      time subscribers additionally get `startedAt` stamped and the soulbound NFT minted.
    ///      Assumes `_bindSponsorForPass` has already written `sponsor` (via resolver) — this
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

        emit PackagePassUpgraded(msg.sender, oldTierId, newTierId, newSeats, delta);
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
    function addTier(uint256 price, uint32 seats, string calldata metadataURI)
        external
        onlyRole(PARAMETER_MANAGER_ROLE)
        returns (uint16 tierId)
    {
        if (price == 0) revert InvalidPrice();

        _nextTierId += 1;
        tierId = _nextTierId;
        _tiers[tierId] =
            Tier({price: price, seats: seats, deprecatedRateBpsSlot: 0, active: true, metadataURI: metadataURI});
        emit TierAdded(tierId, price, seats);
    }

    /// @dev Editing `seats` here affects NEW buyers of this tier only. Holders already on this
    ///      tier keep the `seats + consumedSeats` they were granted at purchase/upgrade time; the
    ///      upgrade path reads that snapshot off the Pass, never off this storage row.
    function setTier(uint16 tierId, uint256 price, uint32 seats, bool active, string calldata metadataURI)
        external
        onlyRole(PARAMETER_MANAGER_ROLE)
    {
        if (tierId == 0 || tierId > _nextTierId || _tiers[tierId].price == 0) {
            revert InvalidTier(tierId);
        }
        if (price == 0) revert InvalidPrice();

        Tier storage t = _tiers[tierId];
        t.price = price;
        t.seats = seats;
        t.active = active;
        t.metadataURI = metadataURI;
        emit TierUpdated(tierId, price, seats, active);
    }

    function removeTier(uint16 tierId) external onlyRole(PARAMETER_MANAGER_ROLE) {
        if (tierId == 0 || tierId > _nextTierId || _tiers[tierId].price == 0) {
            revert InvalidTier(tierId);
        }
        _tiers[tierId].active = false;
        emit TierRemoved(tierId);
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

    function setKycSigner(address signer) external onlyRole(DEFAULT_ADMIN_ROLE) {
        _setKycSigner(signer);
    }

    function initializeKycSigner(address signer) external onlyRole(DEFAULT_ADMIN_ROLE) reinitializer(3) {
        __EIP712_init("PAiT Subscription KYC", "1");
        _setKycSigner(signer);
    }

    function _setKycSigner(address signer) internal {
        if (signer == address(0) || signer.code.length != 0) revert InvalidKycSigner(signer);
        _kycSigner = signer;
        emit KycSignerUpdated(signer);
    }

    function pause() external onlyRole(PAUSER_ROLE) {
        _pause();
    }

    function unpause() external onlyRole(PAUSER_ROLE) {
        _unpause();
    }

    function _consumeKycAuthorization(address user, uint8 scope, bytes memory authorization) internal {
        address signer = _kycSigner;
        if (signer == address(0)) {
            revert InvalidKycSigner(signer);
        }

        (uint64 expiresAt, uint256 nonce, bytes memory signature) = KycAuthorization.decode(user, authorization);
        if (expiresAt < block.timestamp) {
            revert KycAuthorizationExpired(user);
        }
        if (expiresAt > block.timestamp + KycAuthorization.MAX_TTL) {
            revert InvalidKycAuthorization(user);
        }
        if (nonce != _kycNonces[user]) {
            revert InvalidKycAuthorization(user);
        }

        bytes32 structHash = keccak256(abi.encode(KycAuthorization.TYPEHASH, user, scope, expiresAt, nonce));
        address recovered = ECDSA.recover(_hashTypedDataV4(structHash), signature);
        if (recovered != signer) {
            revert InvalidKycAuthorization(user);
        }

        _kycNonces[user] = nonce + 1;
        emit KycAuthorizationConsumed(user, scope, nonce, expiresAt);
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

    /// @notice Admin grants a package pass without collecting payment.
    /// @dev Uses the same pass storage and 20-year bundled subscription semantics as
    ///      `buyPackagePass`, but intentionally skips sponsor binding and revenue collection.
    function adminGrantPackagePass(address user, uint16 tierId) external nonReentrant onlyRole(DEFAULT_ADMIN_ROLE) {
        if (user == address(0)) revert ZeroAddress();

        Tier storage t = _tiers[tierId];
        if (tierId == 0 || tierId > _nextTierId || t.price == 0) {
            revert InvalidTier(tierId);
        }
        if (!t.active) {
            revert TierInactive(tierId);
        }
        if (_passes[user].tierId != 0) {
            revert PassAlreadyExists(user);
        }

        uint32 seats = t.seats;
        _passes[user] = Pass({tierId: tierId, seats: seats, consumedSeats: 0, purchasedAt: uint64(block.timestamp)});

        _grantPassSubscription(user);
        IPackagePassNFT(_packagePassNFT).mint(user, tierId, seats);

        emit PackagePassGranted(user, tierId, seats);
    }

    // ==============================================================
    // Internals
    // ==============================================================

    function _collectRevenue(address payer, uint256 amount) internal {
        if (amount == 0) return;
        IERC20(_paymentToken).safeTransferFrom(payer, address(this), amount);
    }

    function _authorizeUpgrade(address) internal view override {
        if (!hasRole(UPGRADER_ROLE, msg.sender)) {
            revert UnauthorizedUpgrade(msg.sender);
        }
    }
}
