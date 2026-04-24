// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {SubscriptionTestBase} from "test/shared/subscription/SubscriptionTestBase.sol";
import {SubscriptionManager} from "src/subscription/SubscriptionManager.sol";
import {InvalidSponsor} from "test/shared/subscription/SubscriptionErrors.sol";

/// @notice Unit tests for the sponsor resolver's null-fallback path.
/// @dev When a partner has no available seats the effective sponsor resolves to `address(0)`,
///      the subscription still proceeds, and no sponsor rewards accrue to anyone.
contract NullFallbackTest is SubscriptionTestBase {
    uint256 internal constant TIER_PRICE = 1_000e6;
    uint256 internal constant TIER_RATE_BPS = 500;

    event SponsorResolved(
        address indexed user,
        address indexed requestedPartner,
        address indexed effectiveSponsor,
        uint32 partnerSeatsRemaining
    );

    function setUp() public override {
        super.setUp();
        _grantGenesisSubscription(admin);
        _addTier(TIER_PRICE, 1, TIER_RATE_BPS); // tier-1: 1 seat
    }

    function test_partnerWithoutPassResolvesToNull() public {
        // admin has a genesis subscription but no Pass → seats = 0 → null fallback.
        vm.expectEmit(true, true, true, true, address(manager));
        emit SponsorResolved(alice, admin, address(0), 0);

        vm.prank(alice);
        manager.buySubscription(admin);

        SubscriptionManager.Subscription memory sub = manager.subscriptionOf(alice);
        assertEq(sub.sponsor, address(0));
        assertEq(earnCoreStub.userSponsor(alice), address(0));
    }

    function test_partnerWithZeroSeatsResolvesToNull() public {
        vm.prank(admin);
        manager.buyPackagePass(1, address(0)); // admin now has 1 seat

        // alice consumes the single seat.
        vm.prank(alice);
        manager.buySubscription(admin);
        assertEq(passNft.seatsOf(admin), 0);

        // bob must resolve to the null sponsor.
        vm.expectEmit(true, true, true, true, address(manager));
        emit SponsorResolved(bob, admin, address(0), 0);

        vm.prank(bob);
        manager.buySubscription(admin);

        assertEq(manager.subscriptionOf(bob).sponsor, address(0));
        assertEq(earnCoreStub.userSponsor(bob), address(0));
    }

    function test_zeroPartnerReverts() public {
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(InvalidSponsor.selector, address(0)));
        manager.buySubscription(address(0));
    }

    function test_quoteSponsorReturnsNullWhenPartnerEmpty() public view {
        (address effective, uint32 remaining) = manager.quoteSponsor(admin);
        assertEq(effective, address(0));
        assertEq(remaining, 0);
    }

    function test_quoteSponsorReturnsPartnerWhenSeatsAvailable() public {
        vm.prank(admin);
        manager.buyPackagePass(1, address(0));

        (address effective, uint32 remaining) = manager.quoteSponsor(admin);
        assertEq(effective, admin);
        assertEq(remaining, 1);
    }
}
