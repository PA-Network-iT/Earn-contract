// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

// === SubscriptionManager errors ===
error NotSubscribed(address user);
error SubscriptionAlreadyActive(address user);
error SubscriptionAlreadyExists(address user);
error InvalidSponsor(address sponsor);
error SponsorNotSubscribed(address sponsor);
error SelfSponsorNotAllowed();
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

// === SubscriptionNFT / PackagePassNFT errors ===
error SoulboundTransferDisabled();
error UnauthorizedManager(address caller);
error TokenNotMinted(address owner);
error TokenAlreadyMinted(address owner);
error InvalidManager(address manager);
error NoSeatsAvailable(address owner);

// === EarnCore v2 subscription-gate errors ===
error SubscriptionRequired(address user);
error InvalidSubscriptionManager(address manager);
