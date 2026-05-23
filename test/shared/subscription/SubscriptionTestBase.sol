// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {Test} from "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import {MockUSDC} from "test/shared/mocks/MockUSDC.sol";
import {SubscriptionNFT} from "src/subscription/SubscriptionNFT.sol";
import {PackagePassNFT} from "src/subscription/PackagePassNFT.sol";
import {SubscriptionManager} from "src/subscription/SubscriptionManager.sol";

/// @notice Minimal stand-in for EarnCore exposing the surface SubscriptionManager integrates with.
/// @dev Exposes the treasury wallet used for subscription revenue routing.
contract MockEarnCoreStub {
    address internal _treasuryWallet;

    constructor(address treasuryWallet_) {
        _treasuryWallet = treasuryWallet_;
    }

    function treasuryWallet() external view returns (address) {
        return _treasuryWallet;
    }
}

/// @notice Shared fixture wiring USDC + mock EarnCore + subscription stack.
abstract contract SubscriptionTestBase is Test {
    uint64 internal constant SUBSCRIPTION_DURATION = 365 days;
    uint256 internal constant SUBSCRIPTION_PRICE = 100e6; // 100 USDC
    uint256 internal constant INITIAL_TIMESTAMP = 1_743_465_600;
    uint256 internal constant TEST_KYC_SIGNER_PK = 0xA11CE;
    uint8 internal constant TEST_KYC_SCOPE_PACKAGE_PASS = 2;
    bytes32 internal constant TEST_KYC_AUTHORIZATION_TYPEHASH =
        keccak256("KycAuthorization(address user,uint8 scope,uint64 expiresAt,uint256 nonce)");
    bytes32 internal constant TEST_EIP712_DOMAIN_TYPEHASH =
        keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)");

    address internal admin = makeAddr("admin");
    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");
    address internal carol = makeAddr("carol");
    address internal treasury = makeAddr("treasury");
    address internal testKycSigner;

    MockUSDC internal usdc;
    MockEarnCoreStub internal earnCoreStub;
    SubscriptionNFT internal subNft;
    PackagePassNFT internal passNft;
    SubscriptionManager internal manager;

    function setUp() public virtual {
        vm.warp(INITIAL_TIMESTAMP);
        usdc = new MockUSDC();
        earnCoreStub = new MockEarnCoreStub(treasury);

        SubscriptionNFT subImpl = new SubscriptionNFT();
        ERC1967Proxy subProxy = new ERC1967Proxy(address(subImpl), abi.encodeCall(SubscriptionNFT.initialize, (admin)));
        subNft = SubscriptionNFT(address(subProxy));

        PackagePassNFT passImpl = new PackagePassNFT();
        ERC1967Proxy passProxy = new ERC1967Proxy(address(passImpl), abi.encodeCall(PackagePassNFT.initialize, (admin)));
        passNft = PackagePassNFT(address(passProxy));

        SubscriptionManager mImpl = new SubscriptionManager();
        ERC1967Proxy mProxy = new ERC1967Proxy(
            address(mImpl),
            abi.encodeCall(
                SubscriptionManager.initialize,
                (admin, address(earnCoreStub), address(subNft), address(passNft), address(usdc), treasury, SUBSCRIPTION_PRICE)
            )
        );
        manager = SubscriptionManager(address(mProxy));

        vm.startPrank(admin);
        subNft.setManager(address(manager));
        passNft.setManager(address(manager));
        testKycSigner = vm.addr(TEST_KYC_SIGNER_PK);
        manager.setKycSigner(testKycSigner);
        vm.stopPrank();

        _fundAndApprove(alice, 1_000_000e6);
        _fundAndApprove(bob, 1_000_000e6);
        _fundAndApprove(carol, 1_000_000e6);
        _fundAndApprove(admin, 1_000_000e6);
    }

    function _fundAndApprove(address account, uint256 amount) internal {
        usdc.mint(account, amount);
        vm.prank(account);
        usdc.approve(address(manager), type(uint256).max);
    }

    function _grantGenesisSubscription(address user) internal {
        vm.prank(admin);
        manager.adminMintGenesisSubscription(user);
    }

    function _addTier(uint256 price, uint32 seats) internal returns (uint16 tierId) {
        vm.prank(admin);
        tierId = manager.addTier(price, seats, "ipfs://tier");
    }

    /// @notice Helper: grants `addr` a genesis subscription (if needed), creates a tier and
    ///         lets `addr` buy it so that `addr` carries `seats` on their `PackagePassNFT` and
    ///         can sponsor that many first-time `buySubscription` calls before the resolver
    ///         falls back to a null sponsor.
    /// @dev Uses a dedicated tier with `price = 1 USDC`. Returns the created tier id so callers
    ///      that need to inspect tier data can do so.
    function _bootstrapPartnerPass(address addr, uint32 seats) internal returns (uint16 tierId) {
        if (!manager.hasActiveSubscription(addr)) {
            _grantGenesisSubscription(addr);
        }
        tierId = _addTier(1e6, seats);
        _buyPackagePass(addr, tierId, address(0));
    }

    function _buyPackagePass(address buyer, uint16 tierId, address partner) internal {
        bytes memory authorization = _kycAuthorizationForManager(buyer);
        vm.prank(buyer);
        manager.buyPackagePass(tierId, partner, authorization);
    }

    function _kycAuthorizationForManager(address user) internal view returns (bytes memory) {
        uint64 expiresAt = uint64(block.timestamp + 1 hours);
        uint256 nonce = manager.kycNonce(user);
        bytes32 structHash =
            keccak256(abi.encode(TEST_KYC_AUTHORIZATION_TYPEHASH, user, TEST_KYC_SCOPE_PACKAGE_PASS, expiresAt, nonce));
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", _domainSeparator(address(manager)), structHash));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(TEST_KYC_SIGNER_PK, digest);

        return abi.encode(expiresAt, nonce, abi.encodePacked(r, s, v));
    }

    function _domainSeparator(address verifyingContract) internal view returns (bytes32) {
        return keccak256(
            abi.encode(
                TEST_EIP712_DOMAIN_TYPEHASH,
                keccak256(bytes("PAiT Subscription KYC")),
                keccak256(bytes("1")),
                block.chainid,
                verifyingContract
            )
        );
    }
}
