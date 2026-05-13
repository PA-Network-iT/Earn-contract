// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {EarnCore} from "src/EarnCore.sol";
import {
    KycAuthorizationRequired,
    InvalidKycAuthorization,
    KycAuthorizationExpired,
    InvalidKycSigner,
    KycCallerMismatch
} from "src/lib/KycAuthorization.sol";
import {EarnTestBase} from "test/shared/EarnTestBase.sol";

contract KycDepositGateTest is EarnTestBase {
    uint256 internal constant KYC_SIGNER_PK = 0xA11CE;
    uint8 internal constant KYC_SCOPE_DEPOSIT = 1;

    bytes32 internal constant KYC_AUTHORIZATION_TYPEHASH =
        keccak256("KycAuthorization(address user,uint8 scope,uint64 expiresAt,uint256 nonce)");
    bytes32 internal constant EIP712_DOMAIN_TYPEHASH =
        keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)");

    address internal kycSigner;

    function setUp() public override {
        super.setUp();
        kycSigner = vm.addr(KYC_SIGNER_PK);

        vm.prank(admin);
        EarnCore(address(core)).setKycSigner(kycSigner);
    }

    function test_depositAtCumulativeThresholdDoesNotRequireSignature() public {
        vm.prank(alice);
        uint256 lotId = core.deposit(1_000e6, alice);

        assertEq(lotId, 1);
        assertEq(EarnCore(address(core)).cumulativeDeposited(alice), 1_000e6);
    }

    function test_initializeKycSignerCanSetUpgradeSigner() public {
        address newSigner = vm.addr(0xC0FFEE);

        vm.prank(admin);
        EarnCore(address(core)).initializeKycSigner(newSigner);

        assertEq(EarnCore(address(core)).kycSigner(), newSigner);
    }

    function test_setKycSignerRejectsContractAddress() public {
        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(InvalidKycSigner.selector, address(this)));
        EarnCore(address(core)).setKycSigner(address(this));
    }

    function test_depositAboveThresholdWithoutSignatureReverts() public {
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(KycAuthorizationRequired.selector, alice));
        EarnCore(address(core)).deposit(1_000e6 + 1, alice, "");
    }

    function test_splitDepositsRequireSignatureWhenCrossingThreshold() public {
        vm.prank(alice);
        core.deposit(999e6, alice);

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(KycAuthorizationRequired.selector, alice));
        core.deposit(2e6, alice);

        bytes memory authorization = _authorization(address(core), alice, KYC_SCOPE_DEPOSIT, 1 hours);

        vm.prank(alice);
        uint256 lotId = EarnCore(address(core)).deposit(2e6, alice, authorization);

        assertEq(lotId, 2);
        assertEq(EarnCore(address(core)).cumulativeDeposited(alice), 1_000e6);
    }

    function test_depositRejectsReusedAuthorization() public {
        bytes memory authorization = _authorization(address(core), alice, KYC_SCOPE_DEPOSIT, 1 hours);

        vm.prank(alice);
        EarnCore(address(core)).deposit(1_000e6 + 1, alice, authorization);

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(InvalidKycAuthorization.selector, alice));
        EarnCore(address(core)).deposit(1e6, alice, authorization);
    }

    function test_depositRejectsExpiredAuthorization() public {
        bytes memory authorization = _authorization(address(core), alice, KYC_SCOPE_DEPOSIT, 0);

        vm.warp(block.timestamp + 1);

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(KycAuthorizationExpired.selector, alice));
        EarnCore(address(core)).deposit(1_000e6 + 1, alice, authorization);
    }

    function test_depositRejectsAuthorizationPastMaxTtl() public {
        bytes memory authorization = _authorization(address(core), alice, KYC_SCOPE_DEPOSIT, 1 days + 1);

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(InvalidKycAuthorization.selector, alice));
        EarnCore(address(core)).deposit(1_000e6 + 1, alice, authorization);
    }

    function test_depositRejectsWrongScopeAuthorization() public {
        bytes memory authorization = _authorization(address(core), alice, 2, 1 hours);

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(InvalidKycAuthorization.selector, alice));
        EarnCore(address(core)).deposit(1_000e6 + 1, alice, authorization);
    }

    function test_depositRejectsWrongSignerAuthorization() public {
        bytes memory authorization = _authorizationWithSigner(0xB0B, address(core), alice, KYC_SCOPE_DEPOSIT, 1 hours);

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(InvalidKycAuthorization.selector, alice));
        EarnCore(address(core)).deposit(1_000e6 + 1, alice, authorization);
    }

    function test_depositRejectsThirdPartyCallerWhenKycRequired() public {
        bytes memory authorization = _authorization(address(core), alice, KYC_SCOPE_DEPOSIT, 1 hours);

        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(KycCallerMismatch.selector, bob, alice));
        EarnCore(address(core)).deposit(1_000e6 + 1, alice, authorization);
    }

    function _authorization(address verifyingContract, address user, uint8 scope, uint64 ttl)
        internal
        view
        returns (bytes memory)
    {
        return _authorizationWithSigner(KYC_SIGNER_PK, verifyingContract, user, scope, ttl);
    }

    function _authorizationWithSigner(
        uint256 signerPk,
        address verifyingContract,
        address user,
        uint8 scope,
        uint64 ttl
    ) internal view returns (bytes memory) {
        uint64 expiresAt = uint64(block.timestamp) + ttl;
        uint256 nonce = EarnCore(address(core)).kycNonce(user);
        bytes32 structHash = keccak256(abi.encode(KYC_AUTHORIZATION_TYPEHASH, user, scope, expiresAt, nonce));
        bytes32 domainSeparator = keccak256(
            abi.encode(
                EIP712_DOMAIN_TYPEHASH,
                keccak256(bytes("PAiT Earn KYC")),
                keccak256(bytes("1")),
                block.chainid,
                verifyingContract
            )
        );
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", domainSeparator, structHash));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(signerPk, digest);

        return abi.encode(expiresAt, nonce, abi.encodePacked(r, s, v));
    }
}
