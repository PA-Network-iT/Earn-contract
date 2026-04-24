// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";

import {SubscriptionTestBase} from "test/shared/subscription/SubscriptionTestBase.sol";
import {SubscriptionManager} from "src/subscription/SubscriptionManager.sol";
import {
    InvalidTier,
    InvalidPrice,
    InvalidRateBps,
    ZeroAddress
} from "test/shared/subscription/SubscriptionErrors.sol";

/// @notice Unit tests for tier CRUD in `SubscriptionManager`.
contract TierManagementTest is SubscriptionTestBase {
    event TierAdded(uint16 indexed tierId, uint256 price, uint32 seats, uint256 sponsorRateBps);
    event TierUpdated(uint16 indexed tierId, uint256 price, uint32 seats, uint256 sponsorRateBps, bool active);
    event TierRemoved(uint16 indexed tierId);
    event SubscriptionPriceUpdated(uint256 newPrice);

    function test_tierZeroIsInactiveByDefault() public view {
        SubscriptionManager.Tier memory t = manager.tier(0);
        assertFalse(t.active);
        assertEq(t.price, 0);
    }

    function test_addTierMonotonicallyIncrementsId() public {
        vm.expectEmit(true, false, false, true, address(manager));
        emit TierAdded(1, 200e6, 5, 1_000);

        vm.prank(admin);
        uint16 tier1 = manager.addTier(200e6, 5, 1_000, "ipfs://1");

        vm.prank(admin);
        uint16 tier2 = manager.addTier(500e6, 15, 1_500, "ipfs://2");

        assertEq(tier1, 1);
        assertEq(tier2, 2);

        SubscriptionManager.Tier memory t1 = manager.tier(1);
        assertEq(t1.price, 200e6);
        assertEq(t1.seats, 5);
        assertEq(t1.sponsorRateBps, 1_000);
        assertEq(t1.metadataURI, "ipfs://1");
        assertTrue(t1.active);
    }

    function test_addTierRevertsOnZeroPrice() public {
        vm.prank(admin);
        vm.expectRevert(InvalidPrice.selector);
        manager.addTier(0, 1, 1_000, "ipfs://x");
    }

    function test_addTierRevertsOnOversizedRate() public {
        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(InvalidRateBps.selector, 10_001));
        manager.addTier(100e6, 1, 10_001, "ipfs://x");
    }

    function test_setTierUpdatesFields() public {
        vm.prank(admin);
        uint16 tierId = manager.addTier(200e6, 5, 1_000, "ipfs://old");

        vm.expectEmit(true, false, false, true, address(manager));
        emit TierUpdated(tierId, 250e6, 7, 1_200, true);
        vm.prank(admin);
        manager.setTier(tierId, 250e6, 7, 1_200, true, "ipfs://new");

        SubscriptionManager.Tier memory t = manager.tier(tierId);
        assertEq(t.price, 250e6);
        assertEq(t.seats, 7);
        assertEq(t.sponsorRateBps, 1_200);
        assertTrue(t.active);
        assertEq(t.metadataURI, "ipfs://new");
    }

    function test_setTierRevertsOnUnknownId() public {
        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(InvalidTier.selector, uint16(42)));
        manager.setTier(42, 250e6, 7, 1_200, true, "ipfs://x");
    }

    function test_removeTierMarksInactiveButKeepsRecord() public {
        vm.prank(admin);
        uint16 tierId = manager.addTier(200e6, 5, 1_000, "ipfs://x");

        vm.expectEmit(true, false, false, true, address(manager));
        emit TierRemoved(tierId);

        vm.prank(admin);
        manager.removeTier(tierId);

        SubscriptionManager.Tier memory t = manager.tier(tierId);
        assertFalse(t.active);
        assertEq(t.price, 200e6);
    }

    function test_allActiveTierIdsReflectsLifecycle() public {
        vm.startPrank(admin);
        uint16 t1 = manager.addTier(100e6, 1, 500, "uri1");
        uint16 t2 = manager.addTier(200e6, 5, 1_000, "uri2");
        uint16 t3 = manager.addTier(500e6, 15, 1_500, "uri3");
        vm.stopPrank();

        uint16[] memory active = manager.allActiveTierIds();
        assertEq(active.length, 3);
        assertEq(active[0], t1);
        assertEq(active[1], t2);
        assertEq(active[2], t3);

        vm.prank(admin);
        manager.removeTier(t2);

        uint16[] memory active2 = manager.allActiveTierIds();
        assertEq(active2.length, 2);
        assertEq(active2[0], t1);
        assertEq(active2[1], t3);
    }

    function test_setSubscriptionPrice() public {
        vm.expectEmit(false, false, false, true, address(manager));
        emit SubscriptionPriceUpdated(300e6);

        vm.prank(admin);
        manager.setSubscriptionPrice(300e6);

        assertEq(manager.subscriptionPrice(), 300e6);
    }

    function test_setSubscriptionPriceCanBeZero() public {
        vm.prank(admin);
        manager.setSubscriptionPrice(0);
        assertEq(manager.subscriptionPrice(), 0);
    }

    function test_nonParameterManagerCannotAddTier() public {
        bytes32 role = manager.PARAMETER_MANAGER_ROLE();
        vm.prank(alice);
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, alice, role)
        );
        manager.addTier(200e6, 5, 1_000, "ipfs://x");
    }
}
