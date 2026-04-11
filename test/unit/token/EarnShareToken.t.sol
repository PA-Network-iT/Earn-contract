// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {Test} from "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {
    TransfersDisabled,
    InsufficientUnlockedBalance,
    InsufficientLockedBalance,
    UnauthorizedCore,
    InvalidInitialization
} from "test/shared/interfaces/EarnSpecInterfaces.sol";
import {EarnShareToken} from "src/EarnShareToken.sol";

/// @notice EN: Unit tests for share-token metadata, transfer blocking, locks, unlocks, and core-only mint/burn access.
/// @custom:fa تست‌های واحد برای متادیتای share token، مسدود بودن transfer، lock/unlock و دسترسی mint/burn فقط توسط core.
contract EarnShareTokenTest is Test {
    address internal coreController = makeAddr("coreController");
    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");
    address internal spender = makeAddr("spender");

    EarnShareToken internal implementation;
    EarnShareToken internal token;

    function setUp() public {
        implementation = new EarnShareToken();
    }

    function _deployInitializedToken() internal {
        ERC1967Proxy proxy = new ERC1967Proxy(
            address(implementation), abi.encodeCall(EarnShareToken.initialize, ("EARN LP", "eLP", coreController))
        );
        token = EarnShareToken(address(proxy));
    }

    function test_initializeSetsCanonicalErc20Metadata() public {
        _deployInitializedToken();

        assertEq(token.name(), "EARN LP");
        assertEq(token.symbol(), "eLP");
        assertEq(token.decimals(), 6);
        assertEq(token.totalSupply(), 0);
    }

    function test_coreCanMintAndBalanceTracksSupply() public {
        _deployInitializedToken();

        vm.prank(coreController);
        token.mint(alice, 1_000e6);

        assertEq(token.balanceOf(alice), 1_000e6);
        assertEq(token.totalSupply(), 1_000e6);
        assertEq(token.availableBalanceOf(alice), 1_000e6);
    }

    function test_onlyCoreCanMint() public {
        _deployInitializedToken();

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(UnauthorizedCore.selector, alice));
        token.mint(alice, 1e6);
    }

    function test_approveAndAllowanceFollowCanonicalErc20Surface() public {
        _deployInitializedToken();

        vm.prank(alice);
        bool approved = token.approve(spender, 500e6);

        assertTrue(approved);
        assertEq(token.allowance(alice, spender), 500e6);
    }

    function test_transferRevertsBecauseTokenIsNonTransferable() public {
        _deployInitializedToken();

        vm.prank(coreController);
        token.mint(alice, 1_000e6);

        vm.prank(alice);
        vm.expectRevert(TransfersDisabled.selector);
        token.transfer(bob, 100e6);
    }

    function test_transferFromRevertsEvenWithAllowanceBecauseTokenIsNonTransferable() public {
        _deployInitializedToken();

        vm.prank(coreController);
        token.mint(alice, 1_000e6);

        vm.prank(alice);
        token.approve(spender, 250e6);

        vm.prank(spender);
        vm.expectRevert(TransfersDisabled.selector);
        token.transferFrom(alice, bob, 100e6);

        assertEq(token.allowance(alice, spender), 250e6);
    }

    function test_coreCanLockAndUnlockWithoutChangingTotalSupply() public {
        _deployInitializedToken();

        vm.startPrank(coreController);
        token.mint(alice, 1_000e6);
        token.lock(alice, 400e6);
        vm.stopPrank();

        assertEq(token.totalSupply(), 1_000e6);
        assertEq(token.balanceOf(alice), 1_000e6);
        assertEq(token.lockedBalanceOf(alice), 400e6);
        assertEq(token.availableBalanceOf(alice), 600e6);

        vm.prank(coreController);
        token.unlock(alice, 150e6);

        assertEq(token.lockedBalanceOf(alice), 250e6);
        assertEq(token.availableBalanceOf(alice), 750e6);
    }

    function test_lockRevertsWhenUnlockedBalanceIsInsufficient() public {
        _deployInitializedToken();

        vm.prank(coreController);
        token.mint(alice, 100e6);

        vm.prank(coreController);
        vm.expectRevert(abi.encodeWithSelector(InsufficientUnlockedBalance.selector, alice, 150e6, 100e6));
        token.lock(alice, 150e6);
    }

    function test_unlockRevertsWhenLockedBalanceIsInsufficient() public {
        _deployInitializedToken();

        vm.prank(coreController);
        token.mint(alice, 100e6);

        vm.prank(coreController);
        vm.expectRevert(abi.encodeWithSelector(InsufficientLockedBalance.selector, alice, 1e6, 0));
        token.unlock(alice, 1e6);
    }

    function test_burnUnlockedSharesPreservesLockedReservation() public {
        _deployInitializedToken();

        vm.startPrank(coreController);
        token.mint(alice, 1_000e6);
        token.lock(alice, 300e6);
        token.burn(alice, 200e6);
        vm.stopPrank();

        assertEq(token.totalSupply(), 800e6);
        assertEq(token.balanceOf(alice), 800e6);
        assertEq(token.lockedBalanceOf(alice), 300e6);
        assertEq(token.availableBalanceOf(alice), 500e6);
    }

    function test_burnLockedConsumesReservedSharesForSettlement() public {
        _deployInitializedToken();

        vm.startPrank(coreController);
        token.mint(alice, 1_000e6);
        token.lock(alice, 300e6);
        token.burnLocked(alice, 200e6);
        vm.stopPrank();

        assertEq(token.totalSupply(), 800e6);
        assertEq(token.balanceOf(alice), 800e6);
        assertEq(token.lockedBalanceOf(alice), 100e6);
        assertEq(token.availableBalanceOf(alice), 700e6);
    }

    function test_burnRevertsWhenUnlockedBalanceIsInsufficient() public {
        _deployInitializedToken();

        vm.startPrank(coreController);
        token.mint(alice, 100e6);
        token.lock(alice, 80e6);
        vm.expectRevert(abi.encodeWithSelector(InsufficientUnlockedBalance.selector, alice, 30e6, 20e6));
        token.burn(alice, 30e6);
        vm.stopPrank();
    }

    function test_onlyCoreCanBurnLockAndUnlock() public {
        _deployInitializedToken();

        vm.startPrank(coreController);
        token.mint(alice, 500e6);
        vm.stopPrank();

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(UnauthorizedCore.selector, alice));
        token.burn(alice, 1e6);

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(UnauthorizedCore.selector, alice));
        token.burnLocked(alice, 1e6);

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(UnauthorizedCore.selector, alice));
        token.lock(alice, 1e6);

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(UnauthorizedCore.selector, alice));
        token.unlock(alice, 1e6);
    }

    function test_initializeAssignsCoreAsOwner() public {
        _deployInitializedToken();

        assertEq(token.owner(), coreController);
    }

    function test_implementationContractDisablesInitializers() public {
        vm.expectRevert(InvalidInitialization.selector);
        implementation.initialize("EARN LP", "eLP", coreController);
    }
}
