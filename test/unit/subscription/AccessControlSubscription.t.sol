// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";

import {SubscriptionTestBase} from "test/shared/subscription/SubscriptionTestBase.sol";
import {ZeroAddress} from "test/shared/subscription/SubscriptionErrors.sol";

/// @notice Unit tests for role gating on `SubscriptionManager` admin surface.
contract AccessControlSubscriptionTest is SubscriptionTestBase {
    function test_adminHasAllRoles() public view {
        assertTrue(manager.hasRole(manager.DEFAULT_ADMIN_ROLE(), admin));
        assertTrue(manager.hasRole(manager.PARAMETER_MANAGER_ROLE(), admin));
        assertTrue(manager.hasRole(manager.PAUSER_ROLE(), admin));
        assertTrue(manager.hasRole(manager.UPGRADER_ROLE(), admin));
    }

    function test_onlyParameterManagerCanSetSubscriptionPrice() public {
        bytes32 role = manager.PARAMETER_MANAGER_ROLE();
        vm.prank(alice);
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, alice, role)
        );
        manager.setSubscriptionPrice(300e6);
    }

    function test_onlyParameterManagerCanAddTier() public {
        bytes32 role = manager.PARAMETER_MANAGER_ROLE();
        vm.prank(alice);
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, alice, role)
        );
        manager.addTier(100e6, 1, 500, "uri");
    }

    function test_onlyParameterManagerCanRemoveTier() public {
        vm.prank(admin);
        uint16 id = manager.addTier(100e6, 1, 500, "uri");

        bytes32 role = manager.PARAMETER_MANAGER_ROLE();
        vm.prank(alice);
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, alice, role)
        );
        manager.removeTier(id);
    }

    function test_onlyPauserCanPause() public {
        bytes32 role = manager.PAUSER_ROLE();
        vm.prank(alice);
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, alice, role)
        );
        manager.pause();
    }

    function test_onlyAdminCanAdminMintGenesis() public {
        bytes32 role = manager.DEFAULT_ADMIN_ROLE();
        vm.prank(alice);
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, alice, role)
        );
        manager.adminMintGenesisSubscription(alice);
    }

    function test_adminMintGenesisRejectsZero() public {
        vm.prank(admin);
        vm.expectRevert(ZeroAddress.selector);
        manager.adminMintGenesisSubscription(address(0));
    }

    function test_onlyAdminCanSetSubscriptionNFT() public {
        bytes32 role = manager.DEFAULT_ADMIN_ROLE();
        vm.prank(alice);
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, alice, role)
        );
        manager.setSubscriptionNFT(address(0xBEEF));
    }

    function test_onlyAdminCanSetEarnCore() public {
        bytes32 role = manager.DEFAULT_ADMIN_ROLE();
        vm.prank(alice);
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, alice, role)
        );
        manager.setEarnCore(address(0xBEEF));
    }
}
