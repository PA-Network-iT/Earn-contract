// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import {EarnTestBase} from "test/shared/EarnTestBase.sol";
import {EarnCore} from "src/EarnCore.sol";
import {SubscriptionManager} from "src/subscription/SubscriptionManager.sol";
import {SubscriptionNFT} from "src/subscription/SubscriptionNFT.sol";
import {PackagePassNFT} from "src/subscription/PackagePassNFT.sol";
import {SubscriptionRequired, InvalidSubscriptionManager} from "test/shared/subscription/SubscriptionErrors.sol";

/// @notice Integration tests for the EarnCore v2 subscription gate.
contract EarnCoreGateTest is EarnTestBase {
    SubscriptionManager internal subscriptionManager;
    SubscriptionNFT internal subNft;
    PackagePassNFT internal passNft;

    uint256 internal constant SUB_PRICE = 100e6;

    function setUp() public override {
        super.setUp();

        SubscriptionNFT subImpl = new SubscriptionNFT();
        ERC1967Proxy subProxy = new ERC1967Proxy(
            address(subImpl), abi.encodeCall(SubscriptionNFT.initialize, (admin))
        );
        subNft = SubscriptionNFT(address(subProxy));

        PackagePassNFT passImpl = new PackagePassNFT();
        ERC1967Proxy passProxy = new ERC1967Proxy(
            address(passImpl), abi.encodeCall(PackagePassNFT.initialize, (admin))
        );
        passNft = PackagePassNFT(address(passProxy));

        SubscriptionManager mImpl = new SubscriptionManager();
        ERC1967Proxy mProxy = new ERC1967Proxy(
            address(mImpl),
            abi.encodeCall(
                SubscriptionManager.initialize,
                (admin, address(core), address(subNft), address(passNft), asset, SUB_PRICE)
            )
        );
        subscriptionManager = SubscriptionManager(address(mProxy));

        vm.startPrank(admin);
        subNft.setManager(address(subscriptionManager));
        passNft.setManager(address(subscriptionManager));
        vm.stopPrank();

        // Approve SM to pull USDC from alice/bob for subscription.
        vm.prank(alice);
        assetToken.approve(address(subscriptionManager), type(uint256).max);
        vm.prank(bob);
        assetToken.approve(address(subscriptionManager), type(uint256).max);

        // Grant the SM the SUBSCRIPTION_MANAGER_ROLE so it can call setSponsor / setSponsorRate.
        bytes32 smRole = EarnCore(address(core)).SUBSCRIPTION_MANAGER_ROLE();
        vm.prank(admin);
        core.grantRole(smRole, address(subscriptionManager));
    }

    function test_gateIsOpenWhenSubscriptionManagerUnset() public {
        // By default `_subscriptionManager` is zero: user actions must succeed.
        vm.prank(alice);
        core.deposit(1_000e6, alice);
        assertEq(shareToken.balanceOf(alice), 10_000e6);
    }

    function test_setSubscriptionManagerRequiresAdmin() public {
        bytes32 role = core.DEFAULT_ADMIN_ROLE();
        vm.prank(alice);
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, alice, role)
        );
        EarnCore(address(core)).setSubscriptionManager(address(subscriptionManager));
    }

    function test_setSubscriptionManagerRejectsZero() public {
        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(InvalidSubscriptionManager.selector, address(0)));
        EarnCore(address(core)).setSubscriptionManager(address(0));
    }

    function test_gateBlocksDepositWhenUserNotSubscribed() public {
        vm.prank(admin);
        EarnCore(address(core)).setSubscriptionManager(address(subscriptionManager));

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(SubscriptionRequired.selector, alice));
        core.deposit(1_000e6, alice);
    }

    function test_gateAllowsDepositWhenUserSubscribed() public {
        vm.prank(admin);
        EarnCore(address(core)).setSubscriptionManager(address(subscriptionManager));

        // Seed a genesis + alice subscription.
        vm.prank(admin);
        subscriptionManager.adminMintGenesisSubscription(admin);
        vm.prank(alice);
        subscriptionManager.buySubscription(admin);

        vm.prank(alice);
        uint256 lotId = core.deposit(1_000e6, alice);
        assertGt(lotId, 0);
    }

    function test_gateChecksReceiverNotCaller() public {
        vm.prank(admin);
        EarnCore(address(core)).setSubscriptionManager(address(subscriptionManager));

        // Alice is subscribed, Bob is not. Alice depositing to Bob must revert.
        vm.prank(admin);
        subscriptionManager.adminMintGenesisSubscription(admin);
        vm.prank(alice);
        subscriptionManager.buySubscription(admin);

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(SubscriptionRequired.selector, bob));
        core.deposit(1_000e6, bob);
    }

    function test_gateBlocksRequestWithdrawalWhenUnsubscribed() public {
        // Deposit while gate is off, then enable gate and verify withdrawal is blocked.
        vm.prank(alice);
        uint256 lotId = core.deposit(1_000e6, alice);

        vm.prank(admin);
        EarnCore(address(core)).setSubscriptionManager(address(subscriptionManager));

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(SubscriptionRequired.selector, alice));
        core.requestWithdrawal(lotId, 10_000e6);
    }

    function test_gateAllowsSubscribedUserFullLifecycle() public {
        vm.prank(admin);
        subscriptionManager.adminMintGenesisSubscription(admin);
        vm.prank(alice);
        subscriptionManager.buySubscription(admin);

        vm.prank(admin);
        EarnCore(address(core)).setSubscriptionManager(address(subscriptionManager));

        vm.prank(alice);
        uint256 lotId = core.deposit(1_000e6, alice);

        vm.prank(alice);
        core.requestWithdrawal(lotId, 10_000e6);
    }

    function test_subscriptionManagerCanSetSponsorViaRoleExtension() public {
        vm.prank(admin);
        EarnCore(address(core)).setSubscriptionManager(address(subscriptionManager));
        vm.prank(admin);
        subscriptionManager.adminMintGenesisSubscription(admin);

        // Calling buySubscription internally exercises setSponsor via SUBSCRIPTION_MANAGER_ROLE.
        vm.prank(alice);
        subscriptionManager.buySubscription(admin);
    }

    function test_subscriptionManagerAddressExposedByGetter() public {
        assertEq(EarnCore(address(core)).subscriptionManager(), address(0));
        vm.prank(admin);
        EarnCore(address(core)).setSubscriptionManager(address(subscriptionManager));
        assertEq(EarnCore(address(core)).subscriptionManager(), address(subscriptionManager));
    }
}
