// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {SubscriptionTestBase} from "test/shared/subscription/SubscriptionTestBase.sol";
import {SubscriptionManager} from "src/subscription/SubscriptionManager.sol";

/// @notice Unit tests for partner-inventory seat consumption in `buySubscription`.
contract SeatConsumptionTest is SubscriptionTestBase {
    uint256 internal constant TIER_PRICE = 1_000e6;
    uint32 internal constant TIER_SEATS = 5;
    uint256 internal constant TIER_RATE_BPS = 500; // 5%

    event SponsorResolved(
        address indexed user,
        address indexed requestedPartner,
        address indexed effectiveSponsor,
        uint32 partnerSeatsRemaining
    );
    event SeatsDecremented(address indexed owner, uint32 newSeats);

    function setUp() public override {
        super.setUp();

        _grantGenesisSubscription(admin);
        _addTier(TIER_PRICE, TIER_SEATS, TIER_RATE_BPS);

        // Admin is the bootstrap partner: buys tier-1 so their pass carries TIER_SEATS seats.
        // Genesis subscription has no sponsor; buyPackagePass requires only an active sub.
        vm.prank(admin);
        manager.buyPackagePass(1, address(0));
    }

    function test_firstSubscriptionConsumesOneSeatFromPartner() public {
        uint32 before = passNft.seatsOf(admin);
        assertEq(before, TIER_SEATS);

        vm.expectEmit(true, false, false, true, address(passNft));
        emit SeatsDecremented(admin, TIER_SEATS - 1);

        vm.expectEmit(true, true, true, true, address(manager));
        emit SponsorResolved(alice, admin, admin, TIER_SEATS - 1);

        vm.prank(alice);
        manager.buySubscription(admin);

        assertEq(passNft.seatsOf(admin), TIER_SEATS - 1);
        SubscriptionManager.Pass memory p = manager.passOf(admin);
        assertEq(p.seats, TIER_SEATS - 1, "SM pass mirror decremented");

        SubscriptionManager.Subscription memory sub = manager.subscriptionOf(alice);
        assertEq(sub.sponsor, admin, "effective sponsor is the partner");
        assertEq(earnCoreStub.userSponsor(alice), admin);
    }

    function test_multipleSubscribersDecrementSequentially() public {
        vm.prank(alice);
        manager.buySubscription(admin);
        assertEq(passNft.seatsOf(admin), TIER_SEATS - 1);

        vm.prank(bob);
        manager.buySubscription(admin);
        assertEq(passNft.seatsOf(admin), TIER_SEATS - 2);

        vm.prank(carol);
        manager.buySubscription(admin);
        assertEq(passNft.seatsOf(admin), TIER_SEATS - 3);
    }

    function test_renewalDoesNotConsumeSeat() public {
        vm.prank(alice);
        manager.buySubscription(admin);
        assertEq(passNft.seatsOf(admin), TIER_SEATS - 1);

        skip(uint256(SUBSCRIPTION_DURATION) + 1);

        vm.prank(alice);
        manager.renewSubscription();

        assertEq(passNft.seatsOf(admin), TIER_SEATS - 1, "renewal must not consume a seat");
    }

    function test_quoteSponsorReflectsAvailableSeats() public view {
        (address effective, uint32 remaining) = manager.quoteSponsor(admin);
        assertEq(effective, admin);
        assertEq(remaining, TIER_SEATS);
    }
}
