// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {SubscriptionTestBase} from "test/shared/subscription/SubscriptionTestBase.sol";
import {SubscriptionManager} from "src/subscription/SubscriptionManager.sol";
import {
    PassDoesNotExist,
    SamePassTier,
    DowngradeNotAllowed,
    TierInactive,
    InvalidTier
} from "test/shared/subscription/SubscriptionErrors.sol";

/// @notice Unit tests for `SubscriptionManager.upgradePackagePass`.
contract UpgradePackagePassTest is SubscriptionTestBase {
    event PackagePassUpgraded(
        address indexed user,
        uint16 indexed oldTierId,
        uint16 indexed newTierId,
        uint32 newSeats,
        uint256 deltaPricePaid,
        uint256 newSponsorRateBps
    );

    uint16 internal tier1;
    uint16 internal tier2;
    uint16 internal tier3;

    function setUp() public override {
        super.setUp();
        tier1 = _addTier(200e6, 5, 1_000);
        tier2 = _addTier(500e6, 15, 1_500);
        tier3 = _addTier(1_000e6, 25, 2_000);
        _grantGenesisSubscription(admin);

        vm.prank(alice);
        manager.buySubscription(admin);

        vm.prank(alice);
        // alice already has sub with admin as referrer (from buySubscription above); pass
        // partner must match or be 0x0 per `ReferrerMismatch` guard.
        manager.buyPackagePass(tier1, address(0));
    }

    function test_upgradeHappyPath() public {
        uint256 treasuryBefore = usdc.balanceOf(treasury);
        uint256 aliceBefore = usdc.balanceOf(alice);

        vm.expectEmit(true, true, true, true, address(manager));
        emit PackagePassUpgraded(alice, tier1, tier2, 15, 300e6, 1_500);

        vm.prank(alice);
        manager.upgradePackagePass(tier2);

        SubscriptionManager.Pass memory p = manager.passOf(alice);
        assertEq(p.tierId, tier2);
        assertEq(p.seats, 15);

        // Treasury receives nothing — upgrade delta stays on the manager awaiting sweep.
        assertEq(usdc.balanceOf(treasury) - treasuryBefore, 0);
        assertEq(aliceBefore - usdc.balanceOf(alice), 300e6);
        // 100e6 (null-sub) + 200e6 (tier1 pass) + 300e6 (upgrade delta) = 600e6 retained.
        assertEq(usdc.balanceOf(address(manager)), 600e6);

        assertEq(passNft.tierOf(alice), tier2);
        assertEq(passNft.seatsOf(alice), 15);
        // Token not re-minted.
        assertEq(passNft.balanceOf(alice), 1);

        assertEq(earnCoreStub.sponsorRateBps(alice), 1_500);
        // alice buyPackagePass tier1 (1) + upgrade to tier2 (2).
        assertEq(earnCoreStub.setSponsorRateCalls(), 2);
    }

    function test_upgradeTier1ToTier3AccumulatesSeats() public {
        vm.prank(alice);
        manager.upgradePackagePass(tier3);

        SubscriptionManager.Pass memory p = manager.passOf(alice);
        assertEq(p.tierId, tier3);
        assertEq(p.seats, 25);
    }

    function test_upgradeRevertsOnSameTier() public {
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(SamePassTier.selector, tier1));
        manager.upgradePackagePass(tier1);
    }

    function test_upgradeRevertsOnDowngrade() public {
        // Move alice to tier2 first.
        vm.prank(alice);
        manager.upgradePackagePass(tier2);

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(DowngradeNotAllowed.selector, uint256(500e6), uint256(200e6)));
        manager.upgradePackagePass(tier1);
    }

    function test_upgradeRevertsWithoutPass() public {
        // bob has subscription but no pass yet.
        vm.prank(bob);
        manager.buySubscription(admin);

        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(PassDoesNotExist.selector, bob));
        manager.upgradePackagePass(tier2);
    }

    function test_upgradeRevertsOnUnknownTier() public {
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(InvalidTier.selector, uint16(99)));
        manager.upgradePackagePass(99);
    }

    function test_upgradeRevertsOnInactiveNewTier() public {
        vm.prank(admin);
        manager.removeTier(tier2);

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(TierInactive.selector, tier2));
        manager.upgradePackagePass(tier2);
    }
}
