// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {AccessControlUpgradeable} from "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import {PausableUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";
import {EIP712Upgradeable} from "@openzeppelin/contracts-upgradeable/utils/cryptography/EIP712Upgradeable.sol";
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
import {DelayedUUPSUpgradeable} from "src/upgrade/DelayedUUPSUpgradeable.sol";
import {
    TreasuryWalletTimelock,
    InvalidTreasuryWallet,
    TreasuryWalletChangeIsTwoStep
} from "src/treasury/TreasuryWalletTimelock.sol";
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

/// @title SubscriptionManager
/// @notice On-chain subscription and package-pass registry for the PAiT EARN product.
/// @dev Gates the user entry points of EarnCore through `hasActiveSubscription`, mints the
///      soulbound subscription / package-pass NFTs, and routes collected revenue.
///
///      Security model of this rewrite:
///      - UUPS upgrades run through `DelayedUUPSUpgradeable` (schedule, wait 24h, execute).
///      - The treasury wallet rotates through `TreasuryWalletTimelock` (propose, wait 24h, accept),
///        which matters because it is the destination of all subscription and pass revenue.
///      - Role split (`PARAMETER_MANAGER_ROLE`, `PAUSER_ROLE`, `UPGRADER_ROLE`,
///        `TREASURY_MANAGER_ROLE`) is unchanged.
contract SubscriptionManager is
    Initializable,
    AccessControlUpgradeable,
    ReentrancyGuardTransient,
    PausableUpgradeable,
    DelayedUUPSUpgradeable,
    EIP712Upgradeable,
    TreasuryWalletTimelock,
    SubscriptionManagerStorage,
    ISubscriptionManager
{
    using SafeERC20 for IERC20;

    // ===== Roles =====

    /// @notice Manages pricing and tier definitions.
    bytes32 public constant PARAMETER_MANAGER_ROLE = keccak256("PARAMETER_MANAGER_ROLE");
    /// @notice Pauses user entry points.
    bytes32 public constant PAUSER_ROLE = keccak256("PAUSER_ROLE");
    /// @notice Schedules and executes UUPS upgrades (always behind the 24h upgrade timelock).
    bytes32 public constant UPGRADER_ROLE = keccak256("UPGRADER_ROLE");
    /// @notice Role authorised to move collected revenue (the payment token and any other ERC-20
    ///         residing on this contract) off the contract. Expected to be a multisig / ops wallet.
    ///         Does not grant control over protocol parameters or upgrades.
    bytes32 public constant TREASURY_MANAGER_ROLE = keccak256("TREASURY_MANAGER_ROLE");

    // ===== Business constants =====

    /// @notice Length of a paid subscription period.
    uint64 public constant SUBSCRIPTION_DURATION = 365 days;
    /// @notice Duration of the subscription implicitly granted when a user buys a package pass.
    /// @dev Buying a pass is the only path (outside the admin genesis mint) that can create a
    ///      subscription without calling `buySubscription`, and it deliberately grants a very long
    ///      window so pass holders never need to re-subscribe during the pass lifetime.
    uint64 public constant PASS_SUBSCRIPTION_DURATION = 20 * 365 days;

    // ===== Events =====

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
    /// @notice Emitted on first-time `buySubscription` once the subscription price has been routed.
    ///         Fires unconditionally — `sponsor == address(0)` means the null-fallback path was hit
    ///         and the revenue landed in the treasury instead.
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
    /// @notice Emitted on first-time subscription creation once the effective sponsor is resolved.
    /// @param user The buyer.
    /// @param requestedPartner The partner address passed in by the buyer.
    /// @param effectiveSponsor The address actually recorded. Equals `requestedPartner` when a seat
    ///        was consumed; `address(0)` when the partner had no seats (null fallback).
    /// @param partnerSeatsRemaining Seats left on the partner's pass after resolution (0 on fallback).
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

    // ==============================================================
    // Initialization
    // ==============================================================

    /// @notice Initializes the manager proxy.
    /// @param admin Address that receives every role.
    /// @param earnCore_ EarnCore proxy gated by this manager.
    /// @param subscriptionNFT_ Soulbound subscription NFT proxy.
    /// @param packagePassNFT_ Soulbound package pass NFT proxy.
    /// @param paymentToken_ ERC-20 accepted for payments (USDC).
    /// @param treasuryWallet_ Wallet receiving subscription and pass revenue.
    /// @param initialPrice Initial subscription price in payment token decimals.
    function initialize(
        address admin,
        address earnCore_,
        address subscriptionNFT_,
        address packagePassNFT_,
        address paymentToken_,
        address treasuryWallet_,
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
        if (treasuryWallet_ == address(0)) {
            revert InvalidTreasuryWallet(treasuryWallet_);
        }

        __AccessControl_init();
        __Pausable_init();
        __EIP712_init("PAiT Subscription KYC", "1");
        __DelayedUUPS_init();

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
        _initializeTreasuryWallet(treasuryWallet_);
    }

    // ==============================================================
    // Views
    // ==============================================================

    /// @inheritdoc ISubscriptionManager
    function hasActiveSubscription(address user) public view returns (bool active) {
        return _subscriptions[user].expiresAt > block.timestamp;
    }

    /// @notice Returns the subscription record for `user`.
    function subscriptionOf(address user) external view returns (Subscription memory) {
        return _subscriptions[user];
    }

    /// @notice Returns the package pass held by `user`.
    function passOf(address user) external view returns (Pass memory) {
        return _passes[user];
    }

    /// @notice Returns the tier definition for `tierId`.
    function tier(uint16 tierId) external view returns (Tier memory) {
        return _tiers[tierId];
    }

    /// @notice Returns every currently active tier id.
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

    /// @notice Returns the current subscription price.
    function subscriptionPrice() external view returns (uint256) {
        return _subscriptionPrice;
    }

    /// @notice Cumulative amount of the payment token moved off the contract via `sweep`.
    /// @dev Does NOT count direct sponsor payouts from `buySubscription` — those never touch the
    ///      contract balance.
    function totalRevenueSwept() external view returns (uint256) {
        return _totalRevenueSwept;
    }

    /// @notice Amount of the payment token currently sitting on the contract awaiting sweep.
    function pendingRevenue() external view returns (uint256) {
        return IERC20(_paymentToken).balanceOf(address(this));
    }

    /// @notice Returns the wired EarnCore proxy.
    function earnCore() external view returns (address) {
        return _earnCore;
    }

    /// @notice Returns the accepted payment token.
    function paymentToken() external view returns (address) {
        return _paymentToken;
    }

    /// @inheritdoc TreasuryWalletTimelock
    function treasuryWallet() public view override returns (address) {
        return _treasuryWallet;
    }

    /// @notice Returns the soulbound subscription NFT.
    function subscriptionNFT() external view returns (address) {
        return _subscriptionNFT;
    }

    /// @notice Returns the soulbound package pass NFT.
    function packagePassNFT() external view returns (address) {
        return _packagePassNFT;
    }

    /// @notice Returns the backend signer trusted for KYC authorizations.
    function kycSigner() external view returns (address signer) {
        return _kycSigner;
    }

    /// @notice Returns the next KYC authorization nonce expected for `user`.
    function kycNonce(address user) external view returns (uint256 nonce) {
        return _kycNonces[user];
    }

    /// @notice Off-chain preview of the sponsor that `buySubscription(partner)` would record for a
    ///         first-time buyer at the current block.
    /// @dev Does not check whether `partner` has an active subscription; callers should gate on
    ///      `hasActiveSubscription(partner)` if needed. Returns `(partner, seats)` when the partner
    ///      still has inventory; `(address(0), 0)` when they don't (null fallback — the
    ///      subscription proceeds, but no sponsor rewards accrue to anyone).
    function quoteSponsor(address partner) external view returns (address effective, uint32 partnerSeatsRemaining) {
        Pass storage partnerPass = _passes[partner];
        if (partnerPass.tierId != 0 && partnerPass.seats > 0) {
            return (partner, partnerPass.seats);
        }
        return (address(0), 0);
    }

    // ==============================================================
    // User actions
    // ==============================================================

    /// @notice First-time purchase of a 365-day subscription. Reverts if the caller has ever held a
    ///         subscription before (use `renewSubscription` instead).
    /// @dev Resolves the effective sponsor via `_resolveSponsor`: when `partner` has available seats
    ///      on their package pass a seat is consumed and `partner` is recorded as sponsor; otherwise
    ///      the effective sponsor is `address(0)` (null fallback). A single soulbound
    ///      `SubscriptionNFT` is minted.
    ///
    ///      Revenue routing: when a sponsor was resolved the full price is transferred directly from
    ///      the buyer to that sponsor; otherwise it is routed to the treasury wallet.
    /// @param partner Sponsor address to bind to. MUST hold an active subscription (genesis or
    ///        regular), and be neither `msg.sender` nor `address(0)`.
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

        ISubscriptionNFT(_subscriptionNFT).mint(msg.sender);
        if (effectiveSponsor != address(0)) {
            // Direct-to-sponsor payout: full subscription price bypasses the contract balance.
            IERC20(_paymentToken).safeTransferFrom(msg.sender, effectiveSponsor, _subscriptionPrice);
        } else {
            _collectRevenue(msg.sender, _subscriptionPrice);
        }

        emit SubscriptionRevenueToSponsor(msg.sender, effectiveSponsor, _subscriptionPrice);
        emit SubscriptionPurchased(msg.sender, effectiveSponsor, nowTs, newExpiresAt, _subscriptionPrice, false);
    }

    /// @notice Renews the caller's existing subscription for another 365 days.
    /// @dev Only bumps `expiresAt`; `startedAt`, `sponsor`, and the soulbound NFT are untouched.
    ///      Reverts if the caller never bought a subscription (`NotSubscribed`) or if their
    ///      subscription is still active (`SubscriptionAlreadyActive` — early renewal is not
    ///      permitted). The sponsor resolver is NOT re-run: whatever was written at first purchase
    ///      (including the `address(0)` null fallback) is preserved.
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

        _collectRevenue(msg.sender, _subscriptionPrice);

        emit SubscriptionPurchased(
            msg.sender, existing.sponsor, existing.startedAt, newExpiresAt, _subscriptionPrice, true
        );
    }

    /// @notice Buys a package pass at the given tier.
    /// @dev Does NOT require an active subscription — the pass itself implicitly grants one. Reverts
    ///      if the buyer already owns a pass.
    ///
    ///      Subscription bundling: every successful pass purchase grants the buyer a subscription
    ///      valid until `max(existing.expiresAt, block.timestamp + PASS_SUBSCRIPTION_DURATION)`.
    ///      - First-time subscriber (`expiresAt == 0`): a non-zero `partner` is validated and fed
    ///        through `_resolveSponsor`; `subscription.sponsor` becomes the result.
    ///      - Existing subscriber (active or expired): `startedAt` and `sponsor` are preserved and
    ///        only `expiresAt` may extend. If the existing record already points further into the
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

    /// @notice Upgrades the caller's package pass to a more expensive tier, paying the delta price.
    /// @param newTierId Target tier.
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

        // The absolute seat allowance granted at the owner's current tier is reconstructed from the
        // Pass itself, NOT from current tier storage (spec §7.3 + audit finding M-1): the Tier row
        // may have been edited by the admin after purchase, so reading `oldTier.seats` would leak
        // retroactive state into the owner's upgrade math. The invariant
        // `seats + consumedSeats == absolute granted at last buy/upgrade` makes this reconstruction
        // exact and immune to admin-side mutation.
        uint32 consumed = existing.consumedSeats;
        uint32 oldAbsoluteSeats = existing.seats + consumed;
        uint32 newAbsoluteSeats = newTier.seats;
        if (newAbsoluteSeats < oldAbsoluteSeats) {
            revert DowngradeNotAllowed(oldPrice, newPrice);
        }

        uint256 delta = newPrice - oldPrice;
        // Remaining seats after upgrade = new tier's absolute minus what was already consumed.
        // `newAbsoluteSeats >= oldAbsoluteSeats >= consumed` ⇒ the subtraction cannot underflow.
        uint32 newSeats;
        unchecked {
            newSeats = newAbsoluteSeats - consumed;
        }
        uint16 oldTierId = existing.tierId;
        existing.tierId = newTierId;
        existing.seats = newSeats;

        _collectRevenue(msg.sender, delta);

        IPackagePassNFT(_packagePassNFT).setTier(msg.sender, newTierId, newSeats);

        emit PackagePassUpgraded(msg.sender, oldTierId, newTierId, newSeats, delta);
    }

    // ==============================================================
    // Admin: tiers and pricing
    // ==============================================================

    /// @notice Sets the subscription price.
    function setSubscriptionPrice(uint256 newPrice) external onlyRole(PARAMETER_MANAGER_ROLE) {
        _subscriptionPrice = newPrice;
        emit SubscriptionPriceUpdated(newPrice);
    }

    /// @notice Creates a new package pass tier.
    /// @param price Tier price in payment token decimals.
    /// @param seats Absolute number of seats granted to a buyer of this tier. For upgrades the
    ///        owner's remaining seat count is recomputed as `seats - pass.consumedSeats`, so admins
    ///        must treat this field as "total seats a freshly-minted holder of this tier has", not
    ///        an incremental delta over some other tier.
    /// @param metadataURI Off-chain metadata pointer.
    /// @return tierId Newly created tier id.
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

    /// @notice Updates an existing tier.
    /// @dev Editing `seats` here affects NEW buyers of this tier only. Holders already on this tier
    ///      keep the `seats + consumedSeats` they were granted at purchase/upgrade time; the upgrade
    ///      path reads that snapshot off the Pass, never off this storage row.
    function setTier(uint16 tierId, uint256 price, uint32 seats, bool active, string calldata metadataURI)
        external
        onlyRole(PARAMETER_MANAGER_ROLE)
    {
        if (tierId == 0 || tierId > _nextTierId || _tiers[tierId].price == 0) {
            revert InvalidTier(tierId);
        }
        if (price == 0) revert InvalidPrice();

        Tier storage existingTier = _tiers[tierId];
        existingTier.price = price;
        existingTier.seats = seats;
        existingTier.active = active;
        existingTier.metadataURI = metadataURI;
        emit TierUpdated(tierId, price, seats, active);
    }

    /// @notice Deactivates a tier. Existing holders are unaffected.
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

    /// @notice Rebinds the soulbound subscription NFT.
    function setSubscriptionNFT(address nft) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (nft == address(0)) revert ZeroAddress();
        _subscriptionNFT = nft;
        emit SubscriptionNFTUpdated(nft);
    }

    /// @notice Rebinds the soulbound package pass NFT.
    function setPassNFT(address nft) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (nft == address(0)) revert ZeroAddress();
        _packagePassNFT = nft;
        emit PackagePassNFTUpdated(nft);
    }

    /// @notice Rebinds the EarnCore proxy.
    function setEarnCore(address earn) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (earn == address(0)) revert ZeroAddress();
        _earnCore = earn;
        emit EarnCoreUpdated(earn);
    }

    /// @notice Sets the backend signer trusted for EIP-712 KYC authorizations.
    function setKycSigner(address signer) external onlyRole(DEFAULT_ADMIN_ROLE) {
        _setKycSigner(signer);
    }

    /// @notice Initializes KYC EIP-712 state after upgrading an already-initialized proxy.
    /// @dev Legacy migration hook kept for proxies deployed before the KYC gate existed.
    function initializeKycSigner(address signer) external onlyRole(DEFAULT_ADMIN_ROLE) reinitializer(3) {
        __EIP712_init("PAiT Subscription KYC", "1");
        _setKycSigner(signer);
    }

    // ==============================================================
    // Admin: treasury wallet (two-step, timelocked)
    // ==============================================================

    /// @notice Starts a treasury wallet rotation. Effective after `TREASURY_WALLET_CHANGE_DELAY`.
    /// @param newTreasuryWallet Candidate wallet.
    function proposeTreasuryWallet(address newTreasuryWallet) external onlyRole(DEFAULT_ADMIN_ROLE) {
        _proposeTreasuryWallet(newTreasuryWallet);
    }

    /// @notice Installs a previously proposed treasury wallet once the delay has elapsed.
    /// @param expectedTreasuryWallet Address the caller expects to be pending.
    function acceptTreasuryWallet(address expectedTreasuryWallet) external onlyRole(DEFAULT_ADMIN_ROLE) {
        _acceptTreasuryWallet(expectedTreasuryWallet);
    }

    /// @notice Drops the pending treasury wallet rotation.
    function cancelTreasuryWalletProposal() external onlyRole(DEFAULT_ADMIN_ROLE) {
        _cancelTreasuryWalletProposal();
    }

    /// @notice Deprecated single-step setter, permanently disabled.
    /// @dev Kept so stale ops tooling fails loudly. Use `proposeTreasuryWallet` +
    ///      `acceptTreasuryWallet`.
    function setTreasuryWallet(address) external pure {
        revert TreasuryWalletChangeIsTwoStep();
    }

    /// @dev Persists the accepted treasury wallet into `SubscriptionManagerStorage`.
    function _writeTreasuryWallet(address newTreasuryWallet) internal override {
        _treasuryWallet = newTreasuryWallet;
    }

    // ==============================================================
    // Admin: pausing
    // ==============================================================

    /// @notice Pauses `buySubscription`, `renewSubscription`, `buyPackagePass`, `upgradePackagePass`.
    function pause() external onlyRole(PAUSER_ROLE) {
        _pause();
    }

    /// @notice Lifts the pause.
    function unpause() external onlyRole(PAUSER_ROLE) {
        _unpause();
    }

    // ==============================================================
    // Admin: bootstrap grants
    // ==============================================================

    /// @notice Admin mints a genesis subscription (no sponsor) for bootstrap purposes.
    /// @dev Used for the very first user of the system (typically the admin) so subsequent users can
    ///      reference them as sponsor. Per spec §9.8 the genesis subscription is granted with
    ///      `expiresAt = type(uint64).max` so the sponsor graph always has a reachable root.
    function adminMintGenesisSubscription(address user) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (user == address(0)) revert ZeroAddress();
        if (hasActiveSubscription(user)) revert SubscriptionAlreadyActive(user);

        uint64 startedAt = uint64(block.timestamp);
        uint64 expiresAt = type(uint64).max;
        Subscription storage subscription = _subscriptions[user];
        bool firstTime = subscription.expiresAt == 0;
        subscription.startedAt = startedAt;
        subscription.expiresAt = expiresAt;

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

        Tier storage grantedTier = _tiers[tierId];
        if (tierId == 0 || tierId > _nextTierId || grantedTier.price == 0) {
            revert InvalidTier(tierId);
        }
        if (!grantedTier.active) {
            revert TierInactive(tierId);
        }
        if (_passes[user].tierId != 0) {
            revert PassAlreadyExists(user);
        }

        uint32 seats = grantedTier.seats;
        _passes[user] = Pass({tierId: tierId, seats: seats, consumedSeats: 0, purchasedAt: uint64(block.timestamp)});

        _grantPassSubscription(user);
        IPackagePassNFT(_packagePassNFT).mint(user, tierId, seats);

        emit PackagePassGranted(user, tierId, seats);
    }

    // ==============================================================
    // Treasury: sweep
    // ==============================================================

    /// @notice Moves `amount` of `token` from this contract to `to`.
    /// @dev Primary revenue flows go straight to the treasury wallet; `sweep` handles accidental or
    ///      residual balances. Works for any ERC-20, so it doubles as a rescue path. Only payment
    ///      token sweeps are reflected in the `totalRevenueSwept` audit counter because other tokens
    ///      were never protocol revenue.
    ///
    ///      CEI: the counter bump happens before the external call; the `nonReentrant` guard covers
    ///      the rescue case where `token` is untrusted.
    function sweep(address token, address to, uint256 amount) external nonReentrant onlyRole(TREASURY_MANAGER_ROLE) {
        if (token == address(0) || to == address(0)) revert ZeroAddress();
        if (amount == 0) revert InvalidAmount();

        if (token == _paymentToken) {
            _totalRevenueSwept += amount;
        }

        IERC20(token).safeTransfer(to, amount);
        emit RevenueSwept(msg.sender, token, to, amount);
    }

    // ==============================================================
    // Internals
    // ==============================================================

    function _buyPackagePass(uint16 tierId, address partner, bytes memory kycAuthorization) internal {
        Tier storage purchasedTier = _tiers[tierId];
        if (tierId == 0 || tierId > _nextTierId || purchasedTier.price == 0) {
            revert InvalidTier(tierId);
        }
        if (!purchasedTier.active) {
            revert TierInactive(tierId);
        }
        if (_passes[msg.sender].tierId != 0) {
            revert PassAlreadyExists(msg.sender);
        }

        _consumeKycAuthorization(msg.sender, KycAuthorization.SCOPE_PACKAGE_PASS, kycAuthorization);

        uint256 price = purchasedTier.price;
        uint32 seats = purchasedTier.seats;

        _passes[msg.sender] =
            Pass({tierId: tierId, seats: seats, consumedSeats: 0, purchasedAt: uint64(block.timestamp)});

        _bindSponsorForPass(msg.sender, partner);
        _grantPassSubscription(msg.sender);

        _collectRevenue(msg.sender, price);

        IPackagePassNFT(_packagePassNFT).mint(msg.sender, tierId, seats);

        emit PackagePassPurchased(msg.sender, tierId, seats, price);
    }

    /// @dev Partner-inventory resolver. Called only on first-time subscription creation. Decrements
    ///      both the `_passes` mirror and the live `PackagePassNFT.seats` when the partner still has
    ///      inventory; otherwise returns `address(0)` (null fallback — the subscription still
    ///      proceeds and no sponsor rewards accrue to anyone for such users).
    function _resolveSponsor(address user, address partner) internal returns (address effective) {
        Pass storage partnerPass = _passes[partner];
        if (partnerPass.tierId != 0 && partnerPass.seats > 0) {
            unchecked {
                // `seats` is bounded by the max tier absolute (uint32) at time of purchase/upgrade,
                // `consumedSeats` is bounded by the same absolute → neither can overflow here.
                partnerPass.seats = partnerPass.seats - 1;
                partnerPass.consumedSeats = partnerPass.consumedSeats + 1;
            }
            uint32 remaining = IPackagePassNFT(_packagePassNFT).decrementSeats(partner);
            emit SponsorResolved(user, partner, partner, remaining);
            return partner;
        }

        emit SponsorResolved(user, partner, address(0), 0);
        return address(0);
    }

    /// @dev Pass-bound sponsor binding. Called BEFORE `_grantPassSubscription` so the subscription's
    ///      `sponsor` field is populated before the `SubscriptionPurchased` event is emitted on
    ///      first-time mint.
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

        existing.sponsor = _resolveSponsor(user, partner);
    }

    /// @dev Grants or extends the caller's subscription as part of a pass purchase. Only bumps
    ///      `expiresAt` forward — genesis / long-lived subscriptions are never shortened. First-time
    ///      subscribers additionally get `startedAt` stamped and the soulbound NFT minted. Assumes
    ///      `_bindSponsorForPass` has already written `sponsor`.
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

    function _collectRevenue(address payer, uint256 amount) internal {
        if (amount == 0) return;
        address recipient = _treasuryWallet;
        if (recipient == address(0)) revert InvalidTreasuryWallet(recipient);
        IERC20(_paymentToken).safeTransferFrom(payer, recipient, amount);
    }

    function _setKycSigner(address signer) internal {
        if (signer == address(0) || signer.code.length != 0) revert InvalidKycSigner(signer);
        _kycSigner = signer;
        emit KycSignerUpdated(signer);
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

    /// @dev Only `UPGRADER_ROLE` may schedule, cancel, or execute an implementation change.
    function _checkUpgradeAuthority(address account) internal view override {
        if (!hasRole(UPGRADER_ROLE, account)) {
            revert UnauthorizedUpgrade(account);
        }
    }
}
