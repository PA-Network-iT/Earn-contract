// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {EarnTestBase} from "test/shared/EarnTestBase.sol";
import {
    DepositBelowMinimum,
    InvalidInitialization,
    NoScheduledUpgrade,
    UnauthorizedUpgrade,
    UpgradeDelayNotElapsed,
    UpgradeImplementationInvalid,
    UpgradeNotScheduled
} from "test/shared/interfaces/EarnSpecInterfaces.sol";
import {EarnCoreV2Mock} from "test/unit/upgrade/mocks/EarnCoreV2Mock.sol";

/// @notice Minimal upgraded-core interface used to assert proxy behavior after a UUPS upgrade.
interface IEarnCoreV2 {
    function version() external view returns (string memory);
    function minDeposit() external view returns (uint256);
    function forceMinDeposit(uint256 newMinimumAssets) external;
    function deposit(uint256 assets, address receiver) external returns (uint256 lotId);
}

/// @notice Unit tests for UUPS initialization protection, the upgrade timelock, and storage continuity.
contract UUPSLifecycleTest is EarnTestBase {
    event UpgradeScheduled(address indexed implementation, uint256 scheduledAt, uint256 executableAt);
    event UpgradeCancelled(address indexed implementation);
    event UpgradeExecuted(address indexed implementation);

    function test_implementationContractDisablesInitializers() public {
        vm.prank(admin);
        vm.expectRevert(InvalidInitialization.selector);
        core.initialize(admin, asset, treasury, block.timestamp, 0);
    }

    function test_onlyUpgraderCanScheduleUpgrade() public {
        EarnCoreV2Mock newImplementation = new EarnCoreV2Mock();

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(UnauthorizedUpgrade.selector, alice));
        core.scheduleUpgrade(address(newImplementation));
    }

    function test_onlyUpgraderCanAuthorizeUpgrade() public {
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(UnauthorizedUpgrade.selector, alice));
        core.upgradeToAndCall(address(0xBEEF), "");
    }

    function test_scheduleRejectsImplementationWithoutCode() public {
        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(UpgradeImplementationInvalid.selector, address(0xBEEF)));
        core.scheduleUpgrade(address(0xBEEF));
    }

    function test_scheduleRecordsPendingUpgradeAndDelay() public {
        EarnCoreV2Mock newImplementation = new EarnCoreV2Mock();

        vm.expectEmit(true, false, false, true, address(core));
        emit UpgradeScheduled(address(newImplementation), block.timestamp, block.timestamp + 24 hours);

        vm.prank(admin);
        core.scheduleUpgrade(address(newImplementation));

        (address implementation, uint64 scheduledAt, uint64 executableAt) = core.scheduledUpgrade();
        assertEq(implementation, address(newImplementation));
        assertEq(scheduledAt, uint64(block.timestamp));
        assertEq(executableAt, uint64(block.timestamp + core.UPGRADE_DELAY()));
    }

    function test_upgradeRevertsWhenNothingScheduled() public {
        EarnCoreV2Mock newImplementation = new EarnCoreV2Mock();

        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(UpgradeNotScheduled.selector, address(newImplementation)));
        core.upgradeToAndCall(address(newImplementation), "");
    }

    function test_upgradeRevertsBeforeDelayElapsed() public {
        EarnCoreV2Mock newImplementation = new EarnCoreV2Mock();

        vm.prank(admin);
        core.scheduleUpgrade(address(newImplementation));

        (,, uint64 executableAt) = core.scheduledUpgrade();
        vm.warp(executableAt - 1);

        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(UpgradeDelayNotElapsed.selector, executableAt, block.timestamp));
        core.upgradeToAndCall(address(newImplementation), "");
    }

    function test_upgradeRevertsWhenImplementationDiffersFromSchedule() public {
        EarnCoreV2Mock scheduledImplementation = new EarnCoreV2Mock();
        EarnCoreV2Mock swappedImplementation = new EarnCoreV2Mock();

        _scheduleAndWarpCoreUpgrade(address(scheduledImplementation));

        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(UpgradeNotScheduled.selector, address(swappedImplementation)));
        core.upgradeToAndCall(address(swappedImplementation), "");
    }

    function test_cancelDropsScheduledUpgrade() public {
        EarnCoreV2Mock newImplementation = new EarnCoreV2Mock();

        vm.prank(admin);
        core.scheduleUpgrade(address(newImplementation));

        vm.expectEmit(true, false, false, false, address(core));
        emit UpgradeCancelled(address(newImplementation));

        vm.prank(admin);
        core.cancelScheduledUpgrade();

        (address implementation,, uint64 executableAt) = core.scheduledUpgrade();
        assertEq(implementation, address(0));
        assertEq(executableAt, 0);

        vm.warp(block.timestamp + 30 days);
        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(UpgradeNotScheduled.selector, address(newImplementation)));
        core.upgradeToAndCall(address(newImplementation), "");
    }

    function test_cancelRevertsWhenNothingScheduled() public {
        vm.prank(admin);
        vm.expectRevert(NoScheduledUpgrade.selector);
        core.cancelScheduledUpgrade();
    }

    function test_upgraderCanExecuteScheduledUpgradeAfterDelay() public {
        EarnCoreV2Mock newImplementation = new EarnCoreV2Mock();

        _scheduleAndWarpCoreUpgrade(address(newImplementation));

        vm.expectEmit(true, false, false, false, address(core));
        emit UpgradeExecuted(address(newImplementation));

        vm.prank(admin);
        core.upgradeToAndCall(address(newImplementation), "");

        assertEq(IEarnCoreV2(address(core)).version(), "v2");
    }

    function test_executedScheduleCannotBeReplayed() public {
        EarnCoreV2Mock newImplementation = new EarnCoreV2Mock();

        _scheduleAndWarpCoreUpgrade(address(newImplementation));

        vm.prank(admin);
        core.upgradeToAndCall(address(newImplementation), "");

        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(UpgradeNotScheduled.selector, address(newImplementation)));
        core.upgradeToAndCall(address(newImplementation), "");
    }

    function test_upgradeRetainsLegacyMinimumDepositBehaviorWhenStorageSlotIsZero() public {
        EarnCoreV2Mock newImplementation = new EarnCoreV2Mock();

        _scheduleAndWarpCoreUpgrade(address(newImplementation));

        vm.prank(admin);
        core.upgradeToAndCall(address(newImplementation), "");

        IEarnCoreV2 upgradedCore = IEarnCoreV2(address(core));

        vm.prank(admin);
        upgradedCore.forceMinDeposit(0);

        assertEq(upgradedCore.minDeposit(), 1_000_000);

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(DepositBelowMinimum.selector, 999_999, 1_000_000));
        upgradedCore.deposit(999_999, alice);
    }
}
