// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {EarnTestBase} from "test/shared/EarnTestBase.sol";
import {
    DepositBelowMinimum,
    InvalidInitialization,
    UnauthorizedUpgrade
} from "test/shared/interfaces/EarnSpecInterfaces.sol";
import {EarnCoreV2Mock} from "test/unit/upgrade/mocks/EarnCoreV2Mock.sol";

/// @notice Minimal upgraded-core interface used to assert proxy behavior after a UUPS upgrade.
interface IEarnCoreV2 {
    function version() external view returns (string memory);
    function minDeposit() external view returns (uint256);
    function forceMinDeposit(uint256 newMinimumAssets) external;
    function deposit(uint256 assets, address receiver) external returns (uint256 lotId);
}

/// @notice Unit tests for UUPS initialization protection, upgrade authorization, and storage continuity.
contract UUPSLifecycleTest is EarnTestBase {
    function test_implementationContractDisablesInitializers() public {
        vm.prank(admin);
        vm.expectRevert(InvalidInitialization.selector);
        core.initialize(admin, asset, treasury, block.timestamp, 0);
    }

    function test_onlyUpgraderCanAuthorizeUpgrade() public {
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(UnauthorizedUpgrade.selector, alice));
        core.upgradeToAndCall(address(0xBEEF), "");
    }

    function test_upgraderCanExecuteRealUpgrade() public {
        EarnCoreV2Mock newImplementation = new EarnCoreV2Mock();

        vm.prank(admin);
        core.upgradeToAndCall(address(newImplementation), "");

        assertEq(IEarnCoreV2(address(core)).version(), "v2");
    }

    function test_upgradeRetainsLegacyMinimumDepositBehaviorWhenStorageSlotIsZero() public {
        EarnCoreV2Mock newImplementation = new EarnCoreV2Mock();

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
