// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {KycAuthorizationRequired, InvalidKycAuthorization, InvalidKycSigner} from "src/lib/KycAuthorization.sol";
import {SubscriptionManager} from "src/subscription/SubscriptionManager.sol";
import {SubscriptionTestBase} from "test/shared/subscription/SubscriptionTestBase.sol";

contract KycPackagePassGateTest is SubscriptionTestBase {
    uint256 internal constant KYC_SIGNER_PK = 0xA11CE;
    uint8 internal constant KYC_SCOPE_PACKAGE_PASS = 2;

    bytes32 internal constant KYC_AUTHORIZATION_TYPEHASH =
        keccak256("KycAuthorization(address user,uint8 scope,uint64 expiresAt,uint256 nonce)");
    bytes32 internal constant EIP712_DOMAIN_TYPEHASH =
        keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)");

    address internal kycSigner;
    uint16 internal tierId;

    function setUp() public override {
        super.setUp();
        kycSigner = vm.addr(KYC_SIGNER_PK);

        vm.prank(admin);
        manager.setKycSigner(kycSigner);

        tierId = _addTier(200e6, 5);
    }

    function test_buyPackagePassRequiresKycAuthorization() public {
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(KycAuthorizationRequired.selector, alice));
        manager.buyPackagePass(tierId, address(0), "");
    }

    function test_initializeKycSignerCanSetUpgradeSigner() public {
        address newSigner = vm.addr(0xC0FFEE);

        vm.prank(admin);
        manager.initializeKycSigner(newSigner);

        assertEq(manager.kycSigner(), newSigner);
    }

    function test_setKycSignerRejectsContractAddress() public {
        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(InvalidKycSigner.selector, address(this)));
        manager.setKycSigner(address(this));
    }

    function test_buyPackagePassAcceptsValidKycAuthorization() public {
        bytes memory authorization = _authorization(alice, KYC_SCOPE_PACKAGE_PASS, 1 hours);

        vm.prank(alice);
        manager.buyPackagePass(tierId, address(0), authorization);

        SubscriptionManager.Pass memory pass = manager.passOf(alice);
        assertEq(pass.tierId, tierId);
        assertEq(manager.kycNonce(alice), 1);
    }

    function test_buyPackagePassRejectsWrongScopeAuthorization() public {
        bytes memory authorization = _authorization(alice, 1, 1 hours);

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(InvalidKycAuthorization.selector, alice));
        manager.buyPackagePass(tierId, address(0), authorization);
    }

    function test_buyPackagePassRejectsAuthorizationPastMaxTtl() public {
        bytes memory authorization = _authorization(alice, KYC_SCOPE_PACKAGE_PASS, 1 days + 1);

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(InvalidKycAuthorization.selector, alice));
        manager.buyPackagePass(tierId, address(0), authorization);
    }

    function test_buyPackagePassRejectsWrongUserAuthorization() public {
        bytes memory authorization = _authorization(alice, KYC_SCOPE_PACKAGE_PASS, 1 hours);

        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(InvalidKycAuthorization.selector, bob));
        manager.buyPackagePass(tierId, address(0), authorization);
    }

    function _authorization(address user, uint8 scope, uint64 ttl) internal view returns (bytes memory) {
        uint64 expiresAt = uint64(block.timestamp) + ttl;
        uint256 nonce = manager.kycNonce(user);
        bytes32 structHash = keccak256(abi.encode(KYC_AUTHORIZATION_TYPEHASH, user, scope, expiresAt, nonce));
        bytes32 domainSeparator = keccak256(
            abi.encode(
                EIP712_DOMAIN_TYPEHASH,
                keccak256(bytes("PAiT Subscription KYC")),
                keccak256(bytes("1")),
                block.chainid,
                address(manager)
            )
        );
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", domainSeparator, structHash));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(KYC_SIGNER_PK, digest);

        return abi.encode(expiresAt, nonce, abi.encodePacked(r, s, v));
    }
}
